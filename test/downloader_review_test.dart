import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netdisk_direct/netdisk_direct.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../bin/netdisk.dart' as cli;

const link = NetdiskDownloadLink(
    platform: NetdiskPlatform.quark,
    url: 'https://example.test/file',
    fileName: 'file',
    size: 4);

class StreamClient extends http.BaseClient {
  StreamClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

http.StreamedResponse probe({String? etag = 'v1', int total = 4}) =>
    http.StreamedResponse(Stream.value([1]), 206, contentLength: 1, headers: {
      'content-range': 'bytes 0-0/$total',
      if (etag != null) 'etag': etag
    });

void main() {
  late Directory dir;
  late String target;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('netdisk_review_');
    target = p.join(dir.path, 'file');
  });
  tearDown(() => dir.delete(recursive: true));

  Downloader downloader(http.Client client,
      {int retries = 0, Duration? timeout}) {
    final result = Downloader(
        client: client,
        maxRetries: retries,
        probeTimeout: timeout ?? const Duration(seconds: 2),
        idleTimeout: timeout ?? const Duration(seconds: 2));
    addTearDown(result.close);
    return result;
  }

  Future<void> partial({String? validator = 'v1'}) async {
    await File('$target.part').writeAsBytes([9, 9]);
    if (validator != null) {
      await File('$target.part.meta').writeAsString(validator);
    }
  }

  test('缺少或弱 validator 的旧断点从头重下', () async {
    for (final validator in [null, 'W/"v1"']) {
      await partial(validator: validator);
      final seen = <http.BaseRequest>[];
      final dl = downloader(StreamClient((request) async {
        seen.add(request);
        if (request.headers['range'] == 'bytes=0-0') {
          return probe(etag: validator);
        }
        return http.StreamedResponse(Stream.value([1, 2, 3, 4]), 200,
            contentLength: 4);
      }));
      await dl.download(link, targetPath: target);
      expect(seen.last.headers['range'], isNull);
      expect(await File(target).readAsBytes(), [1, 2, 3, 4]);
      await File(target).delete();
    }
  });

  test('错误续传起点或已变 validator 在写盘前拒绝', () async {
    for (final headers in [
      {'content-range': 'bytes 1-3/4', 'etag': 'v1'},
      {'content-range': 'bytes 2-3/4', 'etag': 'v2'},
      {'content-range': 'bytes 2-3/5', 'etag': 'v1'},
    ]) {
      await partial();
      final dl = downloader(StreamClient((request) async {
        if (request.headers['range'] == 'bytes=0-0') return probe();
        expect(request.headers['if-range'], 'v1');
        return http.StreamedResponse(Stream.value([2, 3]), 206,
            headers: headers);
      }));
      await expectLater(dl.download(link, targetPath: target),
          throwsA(isA<NetdiskException>()));
      expect(await File('$target.part').readAsBytes(), [9, 9]);
      expect(await File(target).exists(), isFalse);
    }
  });

  test('服务端忽略 Range 返回完整响应时截断旧断点', () async {
    await partial();
    final dl = downloader(StreamClient((request) async {
      if (request.headers['range'] == 'bytes=0-0') return probe();
      return http.StreamedResponse(Stream.value([1, 2, 3, 4]), 200,
          contentLength: 4, headers: {'etag': 'v2'});
    }));
    final result = await dl.download(link, targetPath: target);
    expect(result.resumedFrom, 0);
    expect(await File(target).readAsBytes(), [1, 2, 3, 4]);
  });

  test('短流与超长流均不能被提交为最终文件', () async {
    for (final body in [
      [1, 2],
      [1, 2, 3, 4, 5]
    ]) {
      final dl = downloader(StreamClient((request) async {
        if (request.headers['range'] == 'bytes=0-0') return probe();
        return http.StreamedResponse(Stream.value(body), 200,
            contentLength: 4, headers: {'etag': 'v1'});
      }));
      await expectLater(dl.download(link, targetPath: target),
          throwsA(isA<NetdiskException>()));
      expect(await File(target).exists(), isFalse);
    }
  });

  test('拒绝未预期部分响应及压缩内容', () async {
    for (final headers in [
      {'content-range': 'bytes 1-3/4'},
      {'content-range': 'bytes 0-2/4'},
      {'content-encoding': 'gzip'},
    ]) {
      final dl = downloader(StreamClient((request) async {
        if (request.headers['range'] == 'bytes=0-0') return probe();
        return http.StreamedResponse(Stream.value([1, 2, 3]), 206,
            headers: headers);
      }));
      await expectLater(dl.download(link, targetPath: target),
          throwsA(isA<NetdiskException>()));
      expect(await File(target).exists(), isFalse);
    }
  });

  test('Range 探测被忽略时立即取消响应，绝不 drain 无限流', () async {
    var canceled = false;
    final controller = StreamController<List<int>>(onCancel: () {
      canceled = true;
    });
    addTearDown(controller.close);
    var calls = 0;
    final dl = downloader(StreamClient((request) async {
      if (++calls == 1) {
        return http.StreamedResponse(controller.stream, 200, contentLength: 4);
      }
      return http.StreamedResponse(Stream.value([1, 2, 3, 4]), 200,
          contentLength: 4);
    }));
    final result = await dl
        .download(link, targetPath: target)
        .timeout(const Duration(seconds: 1));
    expect(result.isCompleted, isTrue);
    expect(canceled, isTrue);
  });

  test('探测 HTTP 500 不被当作可下载文件', () async {
    final dl = downloader(MockClient((_) async => http.Response('error', 500)));
    await expectLater(dl.download(link, targetPath: target),
        throwsA(isA<NetdiskException>()));
    expect(await File('$target.part').exists(), isFalse);
  });

  test('等待响应头期间取消会触发请求 abort', () async {
    var cancel = false;
    var aborted = false;
    final entered = Completer<void>();
    final dl = downloader(StreamClient((request) async {
      entered.complete();
      await (request as http.Abortable).abortTrigger;
      aborted = true;
      throw http.RequestAbortedException();
    }));
    final future =
        dl.download(link, targetPath: target, shouldCancel: () => cancel);
    await entered.future;
    cancel = true;
    expect((await future.timeout(const Duration(seconds: 1))).state,
        DownloadState.canceled);
    await Future<void>.delayed(Duration.zero);
    expect(aborted, isTrue);
  });

  test('响应头超时触发 abort，并返回统一网络错误', () async {
    var aborted = false;
    final dl = downloader(StreamClient((request) async {
      await (request as http.Abortable).abortTrigger;
      aborted = true;
      throw http.RequestAbortedException();
    }), timeout: const Duration(milliseconds: 60));
    await expectLater(dl.download(link, targetPath: target),
        throwsA(isA<NetdiskException>()));
    await Future<void>.delayed(Duration.zero);
    expect(aborted, isTrue);
  });

  test('没有新数据时仍然能取消并保留部分文件', () async {
    var cancel = false;
    final entered = Completer<void>();
    final controller =
        StreamController<List<int>>(onListen: () => entered.complete());
    addTearDown(controller.close);
    final dl = downloader(StreamClient((request) async {
      if (request.headers['range'] == 'bytes=0-0') return probe();
      return http.StreamedResponse(controller.stream, 200,
          contentLength: 4, headers: {'etag': 'v1'});
    }));
    final future =
        dl.download(link, targetPath: target, shouldCancel: () => cancel);
    await entered.future;
    cancel = true;
    final result = await future.timeout(const Duration(seconds: 1));
    expect(result.state, DownloadState.canceled);
    expect(await File('$target.part').exists(), isTrue);
    expect(await File(target).exists(), isFalse);
  });

  test('无数据超时停止下载', () async {
    final controller = StreamController<List<int>>();
    addTearDown(controller.close);
    final dl = downloader(StreamClient((request) async {
      if (request.headers['range'] == 'bytes=0-0') return probe();
      return http.StreamedResponse(controller.stream, 200, contentLength: 4);
    }), timeout: const Duration(milliseconds: 70));
    await expectLater(
        dl
            .download(link, targetPath: target)
            .timeout(const Duration(seconds: 1)),
        throwsA(isA<NetdiskException>()));
    expect(await File(target).exists(), isFalse);
  });

  test('换链次数有上限且错误是公共异常类型', () async {
    var refreshes = 0;
    final dl =
        downloader(MockClient((_) async => http.Response('', 403)), retries: 2);
    await expectLater(
        dl.download(link, targetPath: target, onRefreshLink: () async {
          refreshes++;
          return link;
        }),
        throwsA(isA<NetdiskException>()));
    expect(refreshes, 2);
  });

  test('跨 Downloader 实例并发相同及临时文件路径被拒绝', () async {
    final gate = Completer<http.StreamedResponse>();
    final entered = Completer<void>();
    final first = downloader(StreamClient((_) {
      entered.complete();
      return gate.future;
    }));
    final second = downloader(StreamClient((_) async => probe()));
    var canceled = false;
    final future =
        first.download(link, targetPath: target, shouldCancel: () => canceled);
    await entered.future;
    await expectLater(second.download(link, targetPath: target),
        throwsA(isA<NetdiskException>()));
    await expectLater(second.download(link, targetPath: '$target.part'),
        throwsA(isA<NetdiskException>()));
    canceled = true;
    expect((await future).state, DownloadState.canceled);
    gate.complete(probe());
  });

  test('已存在目标文件及辅助目录不能被覆盖', () async {
    final dl =
        downloader(StreamClient((_) async => throw StateError('不应请求网络')));
    await File(target).writeAsString('keep');
    await expectLater(dl.download(link, targetPath: target),
        throwsA(isA<NetdiskException>()));
    expect(await File(target).readAsString(), 'keep');
    await File(target).delete();
    await Directory('$target.part.meta').create();
    await expectLater(dl.download(link, targetPath: target),
        throwsA(isA<NetdiskException>()));
  });

  test('空文件的 416 探测受支持', () async {
    var calls = 0;
    final dl = downloader(StreamClient((_) async {
      if (++calls == 1) {
        return http.StreamedResponse(const Stream.empty(), 416,
            headers: {'content-range': 'bytes */0'});
      }
      return http.StreamedResponse(const Stream.empty(), 200, contentLength: 0);
    }));
    final result = await dl.download(link, targetPath: target);
    expect(result.isCompleted, isTrue);
    expect(result.bytes, 0);
  });

  test('重定向凭据仅发送至原始 HTTPS origin，跨域丢弃自定义秘密头', () async {
    final requests = <http.BaseRequest>[];
    final dl = downloader(StreamClient((request) async {
      requests.add(request);
      if (request.url.host == 'example.test') {
        return http.StreamedResponse(const Stream.empty(), 302,
            headers: {'location': 'https://cdn.test/data'});
      }
      if (request.headers['range'] == 'bytes=0-0') return probe();
      return http.StreamedResponse(Stream.value([1, 2, 3, 4]), 200,
          contentLength: 4);
    }));
    await dl.download(
        const NetdiskDownloadLink(
            platform: NetdiskPlatform.quark,
            url: 'https://example.test/file',
            fileName: 'file',
            size: 4,
            headers: {
              'Cookie': 'secret',
              'Authorization': 'Bearer secret',
              'X-Secret': 'secret'
            }),
        targetPath: target);
    expect(requests.first.headers['cookie'], 'secret');
    for (final request
        in requests.where((request) => request.url.host == 'cdn.test')) {
      expect(request.headers['cookie'], isNull);
      expect(request.headers['authorization'], isNull);
      expect(request.headers['x-secret'], isNull);
      expect(request.followRedirects, isFalse);
    }
  });

  test('明文 HTTP 不发送 Cookie，HTTPS 降级重定向被拒绝', () async {
    final dl = downloader(StreamClient((request) async {
      expect(request.headers['cookie'], isNull);
      if (request.headers['range'] == 'bytes=0-0') return probe();
      return http.StreamedResponse(Stream.value([1, 2, 3, 4]), 200,
          contentLength: 4);
    }));
    await dl.download(
        const NetdiskDownloadLink(
            platform: NetdiskPlatform.quark,
            url: 'http://example.test/file',
            fileName: 'file',
            size: 4,
            headers: {'Cookie': 'secret'}),
        targetPath: target);
    await File(target).delete();
    final downgrade = downloader(StreamClient((_) async =>
        http.StreamedResponse(const Stream.empty(), 302,
            headers: {'location': 'http://example.test/file'})));
    await expectLater(downgrade.download(link, targetPath: target),
        throwsA(isA<NetdiskException>()));
  });

  test('真实 HTTP 下载的探测取消与字节写盘正常', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.headers.value('range') == 'bytes=0-0') {
        request.response.statusCode = 206;
        request.response.headers.set('content-range', 'bytes 0-0/4');
        request.response.headers.set('etag', '"v1"');
        request.response.contentLength = 1;
        request.response.add([1]);
      } else {
        request.response.contentLength = 4;
        request.response.add([1, 2, 3, 4]);
      }
      await request.response.close();
    });
    final dl = downloader(http.Client());
    final result = await dl.download(
        NetdiskDownloadLink(
            platform: NetdiskPlatform.quark,
            url: 'http://127.0.0.1:${server.port}/file',
            fileName: 'file',
            size: 4),
        targetPath: target);
    expect(result.bytes, 4);
    expect(await File(target).readAsBytes(), [1, 2, 3, 4]);
  });

  test('CLI 安全文件名处理目录穿越、设备名、ADS、尾点及控制符', () {
    for (final name in ['.', '..', '...', '  ']) {
      expect(cli.safeDownloadName(name), 'unnamed');
    }
    expect(cli.safeDownloadName('CON.txt'), '_CON.txt');
    expect(cli.safeDownloadName('lpt1'), '_lpt1');
    expect(cli.safeDownloadName('foo:bar. '), 'foo_bar');
    expect(cli.safeDownloadName('../outside\\file\u0000'), '.._outside_file_');
    expect(cli.safeDownloadName('😀' * 130).runes.length, 120);
  });

  test('CLI 对文件、目录、大小写及临时名冲突分配不同目标', () async {
    await File(p.join(dir.path, 'FILE.txt')).writeAsString('keep');
    await Directory(p.join(dir.path, 'folder')).create();
    final used = <String>{};
    final first = await cli.allocateDownloadPath(dir, 'file.txt', used);
    final second = await cli.allocateDownloadPath(dir, 'file.txt', used);
    final third =
        await cli.allocateDownloadPath(dir, 'file.txt (2).part', used);
    final fourth = await cli.allocateDownloadPath(dir, 'folder', used);
    expect(p.basename(first), 'file (2).txt');
    expect(p.basename(second), 'file (3).txt');
    expect(third, isNot(first));
    expect(p.basename(fourth), 'folder (2)');
    expect(await File(p.join(dir.path, 'FILE.txt')).readAsString(), 'keep');
  });
}
