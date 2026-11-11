import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netdisk_direct/netdisk_direct.dart';
import 'package:test/test.dart';

/// 记录请求并按顺序回话的假服务端。
class FakeServer {
  FakeServer(this.routes);

  /// key 是 `METHOD path`，value 是固定响应或按调用次数动态生成。
  final Map<String, Object> routes;
  final List<http.BaseRequest> requests = [];
  final List<http.Request> posts = [];
  final Map<String, int> _hits = {};

  http.Client get client => MockClient((request) async {
        requests.add(request);
        posts.add(request);
        final key = '${request.method} ${request.url.path}';
        final route = routes[key];
        if (route == null) {
          return http.Response(
            jsonEncode({'error': 'no route', 'key': key}),
            599,
            headers: {'content-type': 'application/json'},
          );
        }
        final hit = _hits[key] = (_hits[key] ?? 0) + 1;
        final FakeResponse resolved;
        if (route is FakeResponse) {
          resolved = route;
        } else if (route is FakeResponse Function(int)) {
          resolved = route(hit);
        } else {
          throw StateError('unexpected route type for $key');
        }
        return http.Response.bytes(
          utf8.encode(resolved.body),
          resolved.status,
          headers: {
            'content-type': 'application/json; charset=utf-8',
            ...resolved.headers,
          },
        );
      });
}

class FakeResponse {
  FakeResponse(this.status, this.body, {this.headers = const {}});
  final int status;
  final String body;
  final Map<String, String> headers;
}

NetdiskClient clientFor(FakeServer server) => NetdiskClient(
      http: HttpClient(client: server.client),
    );

void main() {
  group('链接识别', () {
    late NetdiskClient client;

    setUp(() => client = NetdiskClient());
    tearDown(() => client.close());

    test('夸克分享链接 + 提取码', () {
      final link = client.detect('https://pan.quark.cn/s/abc123def 提取码: 8x9k');
      expect(link.platform, NetdiskPlatform.quark);
      expect(link.shareId, 'abc123def');
      expect(link.password, '8x9k');
    });

    test('夸克链接自带 pwd 参数', () {
      final link = client.detect('https://pan.quark.cn/s/abc123?pwd=1234');
      expect(link.password, '1234');
    });

    test('百度短链', () {
      final link = client.detect('https://pan.baidu.com/s/1AbCdEfGh 密码：1a2b');
      expect(link.platform, NetdiskPlatform.baidu);
      expect(link.shareId, '1AbCdEfGh');
      expect(link.password, '1a2b');
    });

    test('百度 surl 形式', () {
      final link =
          client.detect('https://pan.baidu.com/share/init?surl=xYz789');
      expect(link.platform, NetdiskPlatform.baidu);
      expect(link.shareId, 'xYz789');
    });

    test('阿里云盘链接', () {
      final link = client.detect('https://www.alipan.com/s/Kq4p8VJ2mZx');
      expect(link.platform, NetdiskPlatform.aliyun);
      expect(link.shareId, 'Kq4p8VJ2mZx');
    });

    test('阿里云盘旧域名 + 子目录', () {
      final link = client.detect(
        'https://www.aliyundrive.com/s/Kq4p8VJ2mZx/folder/64f1a2b3c4d5e6f7',
      );
      expect(link.platform, NetdiskPlatform.aliyun);
      expect(link.shareId, 'Kq4p8VJ2mZx');
      expect(link.subPath, '64f1a2b3c4d5e6f7');
    });

    test('不支持的平台抛 unsupportedPlatform', () {
      expect(
        () => client.detect('https://www.123pan.com/s/abcd-1234'),
        throwsA(
          isA<NetdiskException>().having(
            (e) => e.code,
            'code',
            NetdiskErrorCode.unsupportedPlatform,
          ),
        ),
      );
    });

    test('空输入抛 badLink', () {
      expect(
        () => client.detect('   '),
        throwsA(
          isA<NetdiskException>()
              .having((e) => e.code, 'code', NetdiskErrorCode.badLink),
        ),
      );
    });
  });

  group('夸克完整链路', () {
    test('token -> detail -> download', () async {
      final server = FakeServer({
        'POST /1/clouddrive/share/sharepage/token': FakeResponse(
          200,
          jsonEncode({
            'code': 0,
            'data': {'stoken': 'STOKEN_ABC'},
          }),
        ),
        'GET /1/clouddrive/share/sharepage/detail': FakeResponse(
          200,
          jsonEncode({
            'code': 0,
            'data': {
              'list': [
                {
                  'fid': 'fid_1',
                  'file_name': '视频.mp4',
                  'size': 1048576,
                  'dir': false,
                  'share_fid_token': 'ft_1',
                },
              ],
            },
          }),
        ),
        'POST /1/clouddrive/file/download': FakeResponse(
          200,
          jsonEncode({
            'code': 0,
            'data': [
              {'download_url': 'https://cdn.quark.cn/file/视频.mp4?sign=xyz'},
            ],
          }),
        ),
      });

      final client = clientFor(server);
      final share = await client.parse('https://pan.quark.cn/s/pwd1 提取码: abcd');
      expect(share.platform, NetdiskPlatform.quark);
      expect(share.files, hasLength(1));
      expect(share.files.first.name, '视频.mp4');
      expect(share.files.first.size, 1048576);

      final link = await client.resolveDownload(share, share.files.first);
      expect(link.url, contains('cdn.quark.cn'));
      expect(link.fileName, '视频.mp4');
      expect(link.platform, NetdiskPlatform.quark);
      expect(link.headers['Referer'], 'https://pan.quark.cn/');

      // token 请求体必须带上提取码
      final tokenPost = server.posts.first;
      expect(jsonDecode(tokenPost.body)['passcode'], 'abcd');
      // download 请求体必须同时带 fids 与 fids_token
      final dlPost = server.posts.last;
      final dlBody = jsonDecode(dlPost.body) as Map<String, dynamic>;
      expect(dlBody['fids'], ['fid_1']);
      expect(dlBody['fids_token'], ['ft_1']);
      expect(dlBody['stoken'], 'STOKEN_ABC');
    });

    test('分享不存在映射成 shareNotFound', () async {
      final server = FakeServer({
        'POST /1/clouddrive/share/sharepage/token': FakeResponse(
          404,
          jsonEncode({'status': 404, 'code': 41006, 'message': '分享不存在'}),
        ),
      });
      final client = clientFor(server);
      await expectLater(
        client.parse('https://pan.quark.cn/s/gone'),
        throwsA(
          isA<NetdiskException>()
              .having((e) => e.code, 'code', NetdiskErrorCode.shareNotFound),
        ),
      );
    });

    test('23018 映射成 sizeLimitExceeded', () async {
      final server = FakeServer({
        'POST /1/clouddrive/share/sharepage/token': FakeResponse(
          200,
          jsonEncode({
            'code': 0,
            'data': {'stoken': 'S'},
          }),
        ),
        'GET /1/clouddrive/share/sharepage/detail': FakeResponse(
          200,
          jsonEncode({
            'code': 0,
            'data': {
              'list': [
                {
                  'fid': 'f1',
                  'file_name': 'big.zip',
                  'size': 99999999,
                  'dir': false
                },
              ],
            },
          }),
        ),
        'POST /1/clouddrive/file/download': FakeResponse(
          200,
          jsonEncode({'code': 23018, 'message': 'download file size limit'}),
        ),
      });
      final client = clientFor(server);
      final share = await client.parse('https://pan.quark.cn/s/x');
      await expectLater(
        client.resolveDownload(share, share.files.first),
        throwsA(
          isA<NetdiskException>().having(
            (e) => e.code,
            'code',
            NetdiskErrorCode.sizeLimitExceeded,
          ),
        ),
      );
    });

    test('根目录只有文件夹时自动往下钻', () async {
      final server = FakeServer({
        'POST /1/clouddrive/share/sharepage/token': FakeResponse(
          200,
          jsonEncode({
            'code': 0,
            'data': {'stoken': 'S'},
          }),
        ),
        'GET /1/clouddrive/share/sharepage/detail': (int hit) => FakeResponse(
              200,
              jsonEncode({
                'code': 0,
                'data': {
                  'list': hit == 1
                      ? [
                          {
                            'fid': 'dir1',
                            'file_name': '子目录',
                            'size': 0,
                            'dir': true,
                          },
                        ]
                      : [
                          {
                            'fid': 'file1',
                            'file_name': 'inner.mp4',
                            'size': 2048,
                            'dir': false,
                          },
                        ],
                },
              }),
            ),
      });
      final client = clientFor(server);
      final share = await client.parse('https://pan.quark.cn/s/nested');
      expect(share.files, hasLength(1));
      expect(share.files.first.name, 'inner.mp4');
      expect(share.files.first.extra['depth'], 1);
    });
  });

  group('阿里云盘完整链路', () {
    test('share_token -> list -> download_url', () async {
      final server = FakeServer({
        'POST /v2/share_link/get_share_token': FakeResponse(
          200,
          jsonEncode({
            'share_token': 'ST_123',
            'share_name': '我的分享',
            'creator_name': '张三',
          }),
        ),
        'POST /adrive/v3/file/list': FakeResponse(
          200,
          jsonEncode({
            'items': [
              {
                'file_id': 'file_a',
                'name': '照片.jpg',
                'size': 4096,
                'type': 'file',
                'content_hash': 'abc',
              },
            ],
          }),
        ),
        'POST /v2/file/get_share_link_download_url': FakeResponse(
          200,
          jsonEncode({
            'urls': ['https://cdn.alipan.com/photo.jpg?sig=1'],
          }),
        ),
      });

      final client = clientFor(server);
      final share =
          await client.parse('https://www.alipan.com/s/shareXYZ 提取码: 1234');
      expect(share.platform, NetdiskPlatform.aliyun);
      expect(share.files.single.name, '照片.jpg');
      expect(share.title, '我的分享');
      expect(share.ownerName, '张三');

      final link = await client.resolveDownload(share, share.files.single,
          credential: const NetdiskCredential(accessToken: 'fixture-access'));
      expect(link.url, contains('cdn.alipan.com'));
      expect(link.headers['Referer'], 'https://www.alipan.com/');

      // list 与 download_url 都必须带 x-share-token
      for (final post
          in server.posts.where((p) => !p.url.path.contains('share_token'))) {
        expect(post.headers['x-share-token'], 'ST_123');
      }
      // 分享 token 请求必须带提取码
      final tokenPost =
          server.posts.firstWhere((p) => p.url.path.contains('share_token'));
      expect(jsonDecode(tokenPost.body)['share_pwd'], '1234');
    });

    test('410 空响应映射成 credentialExpired', () async {
      final server = FakeServer({
        'POST /v2/share_link/get_share_token': FakeResponse(
          200,
          jsonEncode({'share_token': 'ST'}),
        ),
        'POST /adrive/v3/file/list': FakeResponse(
          200,
          jsonEncode({
            'items': [
              {'file_id': 'f', 'name': 'a.bin', 'size': 1, 'type': 'file'},
            ],
          }),
        ),
        'POST /v2/file/get_share_link_download_url': FakeResponse(410, ''),
      });
      final client = clientFor(server);
      final share = await client.parse('https://www.alipan.com/s/x');
      await expectLater(
        client.resolveDownload(share, share.files.single,
            credential: const NetdiskCredential(accessToken: 'fixture-access')),
        throwsA(
          isA<NetdiskException>().having(
            (e) => e.code,
            'code',
            NetdiskErrorCode.credentialExpired,
          ),
        ),
      );
    });

    test('ShareLinkTokenInvalid 映射成 credentialExpired', () async {
      final server = FakeServer({
        'POST /v2/share_link/get_share_token': FakeResponse(
          401,
          jsonEncode({
            'code': 'ShareLinkTokenInvalid',
            'message': 'ShareLinkToken is invalid. ',
          }),
        ),
      });
      final client = clientFor(server);
      await expectLater(
        client.parse('https://www.alipan.com/s/bad'),
        throwsA(
          isA<NetdiskException>().having(
            (e) => e.code,
            'code',
            NetdiskErrorCode.credentialExpired,
          ),
        ),
      );
    });
  });

  group('百度网盘', () {
    test('无 Cookie 仍可匿名列目录', () async {
      final server = FakeServer({
        'POST /share/wxlist': FakeResponse(
            200,
            jsonEncode({
              'errno': 0,
              'data': {
                'shareid': 1,
                'uk': 2,
                'has_more': false,
                'list': [
                  {
                    'fs_id': 1,
                    'server_filename': 'sample.bin',
                    'size': 8,
                    'isdir': 0
                  },
                ]
              },
            })),
      });
      final client = clientFor(server);
      final share = await client.parse('https://pan.baidu.com/s/1abc');
      expect(share.files.single.name, 'sample.bin');
      expect(server.requests, hasLength(1));
    });

    test('带 Cookie 时走 init -> page -> list', () async {
      const yunData = '{"shareid":123456,"share_uk":"9988",'
          '"sign":"SIGN1","timestamp":1700000000,"sekey":"SEK1"}';
      final server = FakeServer({
        'GET /share/init': FakeResponse(200, '{}'),
        'GET /s/1abc': FakeResponse(
          200,
          '<html><script>window.yunData.setData($yunData);</script></html>',
        ),
        'GET /share/list': FakeResponse(
          200,
          jsonEncode({
            'errno': 0,
            'list': [
              {
                'fs_id': 111,
                'server_filename': '文档.pdf',
                'size': 8192,
                'isdir': 0,
                'server_mtime': 1700000000,
              },
            ],
          }),
        ),
      });
      final client = clientFor(server);
      final share = await client.parse(
        'https://pan.baidu.com/s/1abc',
        credential: const NetdiskCredential(cookie: 'BDUSS=xxx; STOKEN=yyy'),
      );
      expect(share.files.single.name, '文档.pdf');
      expect(share.files.single.size, 8192);
      // cookie 必须进请求头
      final initReq =
          server.requests.firstWhere((r) => r.url.path == '/share/init');
      expect(initReq.headers['Cookie'], contains('BDUSS=xxx'));
    });

    test('无效 Cookie 的 errno -6 映射成 credentialExpired', () async {
      const yunData = '{"shareid":1,"share_uk":"2","sign":"s","timestamp":1}';
      final server = FakeServer({
        'GET /share/init': FakeResponse(200, '{}'),
        'GET /s/1abc': FakeResponse(
          200,
          '<script>yunData.setData($yunData);</script>',
        ),
        'GET /share/list': FakeResponse(
          400,
          jsonEncode({'errno': -6, 'errmsg': 'Invalid Bduss'}),
        ),
      });
      final client = clientFor(server);
      await expectLater(
        client.parse(
          'https://pan.baidu.com/s/1abc',
          credential: const NetdiskCredential(cookie: 'BDUSS=bad'),
        ),
        throwsA(
          isA<NetdiskException>().having(
              (e) => e.code, 'code', NetdiskErrorCode.credentialExpired),
        ),
      );
    });

    test('提取码正确时把 BDCLND 带进后续 Cookie', () async {
      const yunData = '{"shareid":1,"share_uk":"2","sign":"s","timestamp":1}';
      final server = FakeServer({
        'GET /share/init': FakeResponse(200, '{}'),
        'POST /share/verify': FakeResponse(
          200,
          jsonEncode({'errno': 0}),
          headers: {'set-cookie': 'BDCLND=RANDSK123; Path=/; HttpOnly'},
        ),
        'GET /s/1abc': FakeResponse(
          200,
          '<script>yunData.setData($yunData);</script>',
        ),
        'GET /share/list': FakeResponse(
          200,
          jsonEncode({
            'errno': 0,
            'list': [
              {'fs_id': 1, 'server_filename': 'x.txt', 'size': 10, 'isdir': 0},
            ],
          }),
        ),
      });
      final client = clientFor(server);
      await client.parse(
        'https://pan.baidu.com/s/1abc 提取码: 9z9z',
        credential: const NetdiskCredential(cookie: 'BDUSS=b'),
      );
      final verify =
          server.posts.firstWhere((p) => p.url.path == '/share/verify');
      expect(verify.body, contains('pwd=9z9z'));
      // 后续 list 请求必须带上服务端下发的 BDCLND
      final listReq =
          server.requests.firstWhere((r) => r.url.path == '/share/list');
      expect(listReq.headers['Cookie'], contains('BDCLND=RANDSK123'));
    });

    test('提取码错误映射成 passwordWrong', () async {
      final server = FakeServer({
        'GET /share/init': FakeResponse(200, '{}'),
        'POST /share/verify': FakeResponse(
          200,
          jsonEncode({'errno': -9}),
        ),
      });
      final client = clientFor(server);
      await expectLater(
        client.parse(
          'https://pan.baidu.com/s/1abc 提取码: 0000',
          credential: const NetdiskCredential(cookie: 'BDUSS=b'),
        ),
        throwsA(
          isA<NetdiskException>()
              .having((e) => e.code, 'code', NetdiskErrorCode.passwordWrong),
        ),
      );
    });
  });

  group('批量取直链', () {
    test('并发上限生效且顺序与输入一致', () async {
      final server = FakeServer({
        'POST /1/clouddrive/share/sharepage/token': FakeResponse(
          200,
          jsonEncode({
            'code': 0,
            'data': {'stoken': 'S'},
          }),
        ),
        'GET /1/clouddrive/share/sharepage/detail': FakeResponse(
          200,
          jsonEncode({
            'code': 0,
            'data': {
              'list': [
                {'fid': 'a', 'file_name': 'a.mp4', 'size': 1, 'dir': false},
                {'fid': 'b', 'file_name': 'b.mp4', 'size': 2, 'dir': false},
                {'fid': 'c', 'file_name': 'c.mp4', 'size': 3, 'dir': false},
              ],
            },
          }),
        ),
        'POST /1/clouddrive/file/download': FakeResponse(
          200,
          jsonEncode({
            'code': 0,
            'data': [
              {'download_url': 'https://cdn/x'},
            ],
          }),
        ),
      });
      final client = clientFor(server);
      final link = client.detect('https://pan.quark.cn/s/p');
      final share = await client.parseLink(link);
      final results =
          await client.resolveAll(link, share.files, concurrency: 2);
      expect(results, hasLength(3));
      expect(results.map((r) => r.file.name).toList(),
          ['a.mp4', 'b.mp4', 'c.mp4']);
      expect(results.every((r) => r.link != null), isTrue);
    });
  });
}
