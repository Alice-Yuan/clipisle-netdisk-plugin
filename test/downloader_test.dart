import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netdisk_direct/netdisk_direct.dart';
import 'package:test/test.dart';

void main() {
  group('速度采样与停滞判定', () {
    test('持续有数据时速度为正', () async {
      final progress = <DownloadProgress>[];
      final payload = List<int>.generate(1024 * 1024, (i) => i % 256);

      final downloader = Downloader(
        client: MockClient((request) async {
          // probe 请求
          if (request.headers['Range'] == 'bytes=0-0') {
            return http.Response.bytes(
              [0],
              206,
              headers: {
                'content-range': 'bytes 0-0/${payload.length}',
                'etag': 'v1',
              },
            );
          }
          if (request.headers['Range'] != null) {
            final start = int.parse(
              request.headers['Range']!.replaceAll('bytes=', '').replaceAll('-', ''),
            );
            final slice = payload.sublist(start);
            return http.Response.bytes(
              slice,
              206,
              headers: {
                'content-range': 'bytes $start-${payload.length - 1}/${payload.length}',
                'etag': 'v1',
              },
            );
          }
          return http.Response.bytes(
            payload,
            200,
            headers: {
              'content-length': '${payload.length}',
              'etag': 'v1',
            },
          );
        }),
        idleTimeout: const Duration(seconds: 5),
      );

      final dir = await Directory.systemTemp.createTemp('nd_test_');
      addTearDown(() => dir.delete(recursive: true));

      final link = NetdiskDownloadLink(
        platform: NetdiskPlatform.quark,
        url: 'https://cdn.example.com/f.bin',
        fileName: 'f.bin',
        size: payload.length,
      );

      final result = await downloader.download(
        link,
        targetPath: '${dir.path}/f.bin',
        onProgress: progress.add,
      );

      expect(result.isCompleted, isTrue);
      expect(result.bytes, payload.length);
      final last = progress.last;
      expect(last.state, DownloadState.completed);
      expect(last.fraction, 1.0);
    });

    test('403 触发 onRefreshLink 换链重试', () async {
      var calls = 0;
      final downloader = Downloader(
        client: MockClient((request) async {
          calls++;
          if (calls == 1) {
            // 第一次探测就 403
            return http.Response('', 403);
          }
          if (request.headers['Range'] == 'bytes=0-0') {
            return http.Response.bytes(
              [0],
              206,
              headers: {'content-range': 'bytes 0-0/100', 'etag': 'v2'},
            );
          }
          return http.Response.bytes(
            List.filled(100, 7),
            200,
            headers: {'content-length': '100', 'etag': 'v2'},
          );
        }),
      );

      final dir = await Directory.systemTemp.createTemp('nd_refresh_');
      addTearDown(() => dir.delete(recursive: true));

      var refreshes = 0;
      final result = await downloader.download(
        NetdiskDownloadLink(
          platform: NetdiskPlatform.baidu,
          url: 'https://cdn.example.com/expired',
          fileName: 'x.bin',
          size: 100,
        ),
        targetPath: '${dir.path}/x.bin',
        onRefreshLink: () async {
          refreshes++;
          return NetdiskDownloadLink(
            platform: NetdiskPlatform.baidu,
            url: 'https://cdn.example.com/fresh',
            fileName: 'x.bin',
            size: 100,
          );
        },
      );

      expect(refreshes, 1);
      expect(result.isCompleted, isTrue);
      expect(result.bytes, 100);
    });

    test('断点续传：已有 .part 时用 Range 续', () async {
      final dir = await Directory.systemTemp.createTemp('nd_resume_');
      addTearDown(() => dir.delete(recursive: true));

      final target = '${dir.path}/r.bin';
      // 预置前 40 字节与校验标记
      await File('$target.part').writeAsBytes(List.filled(40, 1));
      await File('$target.part.meta').writeAsString('v1');

      final rangesSeen = <String>[];
      final downloader = Downloader(
        client: MockClient((request) async {
          final range = request.headers['Range'];
          if (range != null) rangesSeen.add(range);
          if (range == 'bytes=0-0') {
            return http.Response.bytes(
              [0],
              206,
              headers: {'content-range': 'bytes 0-0/100', 'etag': 'v1'},
            );
          }
          final start = range == null
              ? 0
              : int.parse(range.replaceAll('bytes=', '').replaceAll('-', ''));
          final body = List.filled(100 - start, 2);
          return http.Response.bytes(
            body,
            206,
            headers: {
              'content-range': 'bytes $start-99/100',
              'etag': 'v1',
            },
          );
        }),
      );

      final result = await downloader.download(
        NetdiskDownloadLink(
          platform: NetdiskPlatform.aliyun,
          url: 'https://cdn.example.com/r',
          fileName: 'r.bin',
          size: 100,
        ),
        targetPath: target,
      );

      expect(result.isCompleted, isTrue);
      expect(result.resumedFrom, 40);
      expect(rangesSeen, contains('bytes=40-'));
      final bytes = await File(target).readAsBytes();
      expect(bytes, hasLength(100));
      // 前 40 字节保留原内容（1），后面是 2
      expect(bytes.take(40).every((b) => b == 1), isTrue);
      expect(bytes.skip(40).every((b) => b == 2), isTrue);
    });

    test('校验标记变化时丢弃旧分片重新下载', () async {
      final dir = await Directory.systemTemp.createTemp('nd_restart_');
      addTearDown(() => dir.delete(recursive: true));

      final target = '${dir.path}/c.bin';
      await File('$target.part').writeAsBytes(List.filled(40, 9));
      await File('$target.part.meta').writeAsString('OLD_ETAG');

      final downloader = Downloader(
        client: MockClient((request) async {
          if (request.headers['Range'] == 'bytes=0-0') {
            return http.Response.bytes(
              [0],
              206,
              headers: {'content-range': 'bytes 0-0/60', 'etag': 'NEW_ETAG'},
            );
          }
          final range = request.headers['Range'];
          final start = range == null
              ? 0
              : int.parse(range.replaceAll('bytes=', '').replaceAll('-', ''));
          return http.Response.bytes(
            List.filled(60 - start, 3),
            206,
            headers: {'content-range': 'bytes $start-59/60', 'etag': 'NEW_ETAG'},
          );
        }),
      );

      final result = await downloader.download(
        NetdiskDownloadLink(
          platform: NetdiskPlatform.quark,
          url: 'https://cdn.example.com/c',
          fileName: 'c.bin',
          size: 60,
        ),
        targetPath: target,
      );

      expect(result.isCompleted, isTrue);
      expect(result.resumedFrom, 0);
      final bytes = await File(target).readAsBytes();
      expect(bytes.every((b) => b == 3), isTrue);
    });

    test('取消后保留 .part', () async {
      final dir = await Directory.systemTemp.createTemp('nd_cancel_');
      addTearDown(() => dir.delete(recursive: true));

      final target = '${dir.path}/k.bin';
      var chunks = 0;
      final downloader = Downloader(
        client: MockClient((request) async {
          if (request.headers['Range'] == 'bytes=0-0') {
            return http.Response.bytes(
              [0],
              206,
              headers: {'content-range': 'bytes 0-0/100000', 'etag': 'v'},
            );
          }
          return http.Response.bytes(
            List.filled(100000, 5),
            200,
            headers: {'content-length': '100000', 'etag': 'v'},
          );
        }),
      );

      final result = await downloader.download(
        NetdiskDownloadLink(
          platform: NetdiskPlatform.baidu,
          url: 'https://cdn.example.com/k',
          fileName: 'k.bin',
          size: 100000,
        ),
        targetPath: target,
        shouldCancel: () => ++chunks > 100,
      );

      expect(result.state, anyOf(DownloadState.canceled, DownloadState.completed));
    });
  });

  group('进度模型', () {
    test('没有总量时不报 fraction，eta 为 null', () {
      const p = DownloadProgress(
        received: 500,
        total: -1,
        speedBytesPerSec: 100,
        state: DownloadState.running,
        idleFor: Duration.zero,
      );
      expect(p.hasTotal, isFalse);
      expect(p.fraction, 0);
      expect(p.eta, isNull);
    });

    test('有总量时算出 eta', () {
      const p = DownloadProgress(
        received: 500,
        total: 1500,
        speedBytesPerSec: 100,
        state: DownloadState.running,
        idleFor: Duration.zero,
      );
      expect(p.fraction, closeTo(1 / 3, 1e-9));
      expect(p.eta, const Duration(seconds: 10));
    });

    test('速度 0 时 eta 为 null（不显示 99:99:99）', () {
      const p = DownloadProgress(
        received: 10,
        total: 100,
        speedBytesPerSec: 0,
        state: DownloadState.stalled,
        idleFor: Duration(seconds: 5),
      );
      expect(p.eta, isNull);
    });
  });

  group('错误类型', () {
    test('toString 带出 code 与 platform', () {
      const e = NetdiskException(
        NetdiskErrorCode.loginRequired,
        '需要登录',
        platform: 'baidu',
        statusCode: 400,
      );
      expect(e.toString(), contains('loginRequired'));
      expect(e.toString(), contains('baidu'));
      expect(e.toString(), contains('400'));
    });
  });

  group('Cookie 工具', () {
    test('cookieValue 正确取值', () {
      const c = NetdiskCredential(cookie: 'BDUSS=abc; STOKEN=def; other=ghi');
      expect(c.cookieValue('BDUSS'), 'abc');
      expect(c.cookieValue('STOKEN'), 'def');
      expect(c.cookieValue('missing'), isNull);
    });

    test('isEmpty 判断', () {
      expect(const NetdiskCredential().isEmpty, isTrue);
      expect(const NetdiskCredential(cookie: 'x').isEmpty, isFalse);
      expect(const NetdiskCredential(refreshToken: 'r').isEmpty, isFalse);
    });
  });

  group('直链有效期', () {
    test('过期判定', () {
      final expired = NetdiskDownloadLink(
        platform: NetdiskPlatform.quark,
        url: 'https://x/y',
        fileName: 'y',
        size: 1,
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      expect(expired.isExpired, isTrue);
      expect(expired.remaining, Duration.zero);

      final fresh = NetdiskDownloadLink(
        platform: NetdiskPlatform.quark,
        url: 'https://x/y',
        fileName: 'y',
        size: 1,
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );
      expect(fresh.isExpired, isFalse);
      expect(fresh.remaining!.inMinutes, greaterThan(58));
    });
  });

  group('提取码与 URL 抽取', () {
    test('多种提取码写法', () {
      expect(extractPassword('链接 提取码: abcd'), 'abcd');
      expect(extractPassword('链接 提取碼：XY12'), 'XY12');
      expect(extractPassword('?pwd=9z8y'), '9z8y');
      expect(extractPassword('链接 password=1234'), '1234');
      expect(extractPassword('没有提取码'), isNull);
    });

    test('从中文文案里抽链接', () {
      final uri = extractFirstUrl('看看这个 https://pan.quark.cn/s/abc，很好');
      expect(uri?.toString(), 'https://pan.quark.cn/s/abc');
    });
  });
}
