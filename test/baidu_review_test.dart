import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netdisk_direct/netdisk_direct.dart';
import 'package:test/test.dart';

const shareUrl = 'https://pan.baidu.com/s/1fixture?pwd=abcd';
Map<String, Object?> item(int id,
        {String name = 'sample.bin', bool folder = false, String? path}) =>
    {
      'fs_id': id,
      'server_filename': name,
      'size': '8',
      'isdir': folder ? '1' : '0',
      'path': path ?? '/$name',
    };
http.Response response(Object body,
        {int status = 200, Map<String, String>? headers}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json', ...?headers});
http.Response listing(List<Object?> files, {bool more = false}) => response({
      'errno': 0,
      'data': {
        'shareid': 42,
        'uk': 17,
        'seckey': 'fixture-key',
        'list': files,
        'has_more': more
      },
    });
BaiduParser parserFor(Future<http.Response> Function(http.Request) handler) {
  final transport = HttpClient(client: MockClient(handler));
  addTearDown(transport.close);
  return BaiduParser(transport);
}

Matcher errorCode(NetdiskErrorCode code) =>
    isA<NetdiskException>().having((e) => e.code, 'code', code);

BaiduParser browserDownloadResponse(Map<String, Object?> payload) {
  var attempts = 0;
  return parserFor((request) async {
    switch (request.url.path) {
      case '/share/wxlist':
        return listing([item(1)]);
      case '/share/tplconfig':
        return response({
          'errno': 0,
          'data': {'sign': 'fixture-sign', 'timestamp': 1}
        });
      case '/share/init':
        return response({});
      case '/share/verify':
        return response({'errno': 0, 'randsk': 'fixture-key'});
      case '/s/1fixture':
        return http.Response(
            '<script>locals.mset({"shareid":42,"uk":17,"sign":"browser-sign","timestamp":2});</script>',
            200);
      case '/api/gettemplatevariable':
        return response({
          'errno': 0,
          'result': {'bdstoken': 'browser-csrf'}
        });
      case '/api/sharedownload':
        attempts++;
        if (attempts == 1) return response({'errno': 9019});
        expect(attempts, 2);
        return response(payload);
      default:
        fail('Unexpected endpoint');
    }
  });
}

void main() {
  for (final authenticated in [false, true]) {
    for (final outcome in [
      'success',
      'browserSignature9019',
      'browserDownload9019'
    ]) {
      test(
          'WX tplconfig 9019 gets one browser attempt: authenticated=$authenticated outcome=$outcome',
          () async {
        final requests = <http.Request>[];
        var signatures = 0;
        var downloads = 0;
        final parser = parserFor((request) async {
          requests.add(request);
          switch (request.url.path) {
            case '/share/wxlist':
              return listing([item(1)]);
            case '/share/tplconfig':
              signatures++;
              if (signatures == 1) {
                expect(request.headers['User-Agent'], 'netdisk');
                return response({'errno': 9019});
              }
              expect(signatures, 2,
                  reason: 'Only one browser signature attempt');
              expect(request.headers['User-Agent'], contains('Mozilla'));
              if (outcome == 'browserSignature9019') {
                return response({'errno': 9019});
              }
              return response({
                'errno': 0,
                'data': {'sign': 'browser-sign', 'timestamp': 2}
              });
            case '/share/init':
              return response({});
            case '/share/verify':
              return response({'errno': 0, 'randsk': 'browser-key'});
            case '/s/1fixture':
              return http.Response(
                  '<script>locals.mset({"shareid":42,"uk":17,"bdstoken":"browser-csrf"});</script>',
                  200);
            case '/api/sharedownload':
              downloads++;
              expect(downloads, 1,
                  reason: 'No WX download without its signature');
              expect(request.url.queryParameters['sign'], 'browser-sign');
              expect(request.url.queryParameters['timestamp'], '2');
              expect(request.url.queryParameters['clienttype'], '0');
              if (outcome == 'browserDownload9019') {
                return response({'errno': 9019});
              }
              return response({
                'errno': 0,
                'list': [
                  {'fs_id': 1, 'dlink': 'https://d.pcs.baidu.com/file'}
                ]
              });
            default:
              fail('Unexpected endpoint');
          }
        });
        final pending = parser.resolve(parser.match(shareUrl)!,
            const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8),
            credential: authenticated
                ? const NetdiskCredential(cookie: 'BDUSS=fixture-account')
                : const NetdiskCredential.none());
        if (outcome == 'success') {
          expect((await pending).url, 'https://d.pcs.baidu.com/file');
        } else {
          final stage = outcome == 'browserSignature9019'
              ? 'tplconfig'
              : 'websharedownload';
          await expectLater(
              pending,
              throwsA(isA<NetdiskException>()
                  .having((e) => e.code, 'code',
                      NetdiskErrorCode.verificationRequired)
                  .having(
                      (e) => e.detail, 'stage', 'stage=$stage errno=9019')));
        }
        expect(signatures, 2);
        expect(downloads, outcome == 'browserSignature9019' ? 0 : 1);
        expect(
            requests.where((r) => r.url.path == '/share/init'), hasLength(1));
        expect(
            requests.where((r) => r.url.path == '/share/verify'), hasLength(1));
        expect(
            requests.where((r) => r.url.path == '/s/1fixture'), hasLength(1));
      });
    }
  }
  test('share page HTTP failure is explicit and does not start JSON fallback',
      () async {
    final requests = <http.Request>[];
    final parser = parserFor((request) async {
      requests.add(request);
      switch (request.url.path) {
        case '/share/wxlist':
          return listing([item(1)]);
        case '/share/tplconfig':
          return response({
            'errno': 0,
            'data': {'sign': 'wx', 'timestamp': 1}
          });
        case '/api/sharedownload':
          return response({'errno': 9019});
        case '/share/init':
          return response({});
        case '/share/verify':
          return response({'errno': 0, 'randsk': 'key'});
        case '/s/1fixture':
          return http.Response('unavailable', 503);
        default:
          fail('Unexpected endpoint');
      }
    });
    await expectLater(
        parser.resolve(parser.match(shareUrl)!,
            const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8)),
        throwsA(isA<NetdiskException>()
            .having((e) => e.statusCode, 'http', 503)
            .having(
                (e) => e.detail, 'stage', 'stage=sharepage errno=unknown')));
    expect(
        requests.where((r) => r.url.path == '/rest/2.0/xpan/share'), isEmpty);
  });
  for (final authenticated in [false, true]) {
    test('unknown HTML uses bounded xpan context, authenticated=$authenticated',
        () async {
      final requests = <http.Request>[];
      var downloads = 0;
      var signatures = 0;
      final parser = parserFor((request) async {
        requests.add(request);
        expect(request.url.host, 'pan.baidu.com');
        expect(request.url.path, isNot(contains('transfer')));
        switch (request.url.path) {
          case '/share/wxlist':
            return listing([item(1)]);
          case '/share/tplconfig':
            signatures++;
            expect(request.headers['User-Agent'],
                signatures == 1 ? 'netdisk' : contains('Mozilla'));
            return response({
              'errno': 0,
              'data': {
                'sign': signatures == 1 ? 'wx-sign' : 'browser-sign',
                'timestamp': signatures
              }
            });
          case '/share/init':
            expect(request.headers['Cookie'] ?? '', isNot(contains('BDCLND')));
            return response({});
          case '/share/verify':
            expect(
                request.headers['Cookie'] ?? '', isNot(contains('old-share')));
            return response({'errno': 0, 'randsk': 'current/share+'});
          case '/s/1fixture':
            return http.Response('<html>new page layout</html>', 200);
          case '/rest/2.0/xpan/share':
            expect(request.url.queryParameters, {
              'method': 'list',
              'shorturl': 'fixture',
              'root': '1',
              'dir': '/',
              'page': '1',
              'num': '100',
              'sekey': 'current/share+'
            });
            expect(request.headers['Cookie'],
                contains('BDCLND=current%2Fshare%2B'));
            return response({
              'errno': 0,
              'share_id': '42',
              'uk': 17,
              'list': [item(1)],
              'sign': 'must-not-reuse'
            });
          case '/api/gettemplatevariable':
            expect(authenticated, true);
            expect(request.url.queryParameters['fields'], '["bdstoken"]');
            return response({
              'errno': 0,
              'result': {'bdstoken': 'fresh-token'}
            });
          case '/api/sharedownload':
            downloads++;
            if (downloads == 1) return response({'errno': 9019});
            expect(downloads, 2);
            expect(request.url.queryParameters['sign'], 'browser-sign');
            expect(request.url.queryParameters['clienttype'], '0');
            expect(request.url.queryParameters['bdstoken'],
                authenticated ? 'fresh-token' : isNull);
            expect(request.bodyFields['primaryid'], '42');
            expect(request.bodyFields['uk'], '17');
            return response({
              'errno': 0,
              'list': [
                {'fs_id': 1, 'dlink': 'https://d.pcs.baidu.com/file'}
              ]
            });
          default:
            fail('Unexpected endpoint');
        }
      });
      final credential = authenticated
          ? const NetdiskCredential(cookie: 'BDUSS=account; BDCLND=old-share')
          : const NetdiskCredential(cookie: 'BDCLND=old-share');
      final direct = await parser.resolve(parser.match(shareUrl)!,
          const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8),
          credential: credential);
      expect(direct.url, 'https://d.pcs.baidu.com/file');
      expect(downloads, 2);
      expect(signatures, 2);
      expect(requests.where((r) => r.url.path == '/rest/2.0/xpan/share'),
          hasLength(1));
      expect(requests.where((r) => r.url.path == '/api/gettemplatevariable'),
          hasLength(authenticated ? 1 : 0));
      expect(credential.cookie, contains('BDCLND=old-share'));
    });
  }

  for (final payload in <Map<String, Object?>>[
    {'errno': 0, 'uk': 17, 'list': []},
    {'errno': 0, 'share_id': 42, 'list': []},
    {'errno': 0, 'share_id': 42, 'uk': 17},
    {'errno': 0, 'share_id': 42, 'uk': 17, 'list': {}},
    {'errno': 0, 'share_id': 'private-id', 'uk': 17, 'list': []},
    {'errno': 0, 'share_id': 42, 'uk': 17.5, 'list': []},
  ]) {
    test('malformed xpan context stops without a second download: $payload',
        () async {
      var downloads = 0;
      final parser = parserFor((request) async {
        switch (request.url.path) {
          case '/share/wxlist':
            return listing([item(1)]);
          case '/share/tplconfig':
            return response({
              'errno': 0,
              'data': {'sign': 'wx', 'timestamp': 1}
            });
          case '/api/sharedownload':
            downloads++;
            return response({'errno': 9019});
          case '/share/init':
            return response({});
          case '/share/verify':
            return response({'errno': 0, 'randsk': 'key'});
          case '/s/1fixture':
            return http.Response('<html>unknown</html>', 200);
          case '/rest/2.0/xpan/share':
            return response(payload);
          default:
            fail('Unexpected endpoint');
        }
      });
      await expectLater(
          parser.resolve(parser.match(shareUrl)!,
              const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8)),
          throwsA(isA<NetdiskException>()
              .having((e) => e.code, 'code', NetdiskErrorCode.badResponse)
              .having((e) => e.detail, 'stage', 'stage=xpanshare errno=0')
              .having((e) => e.toString(), 'redacted',
                  isNot(contains('private-id')))));
      expect(downloads, 1);
    });
  }

  for (final errno in [-6, 112, 9019]) {
    test('account token errno=$errno retains precise meaning and stops',
        () async {
      var downloads = 0;
      var tokens = 0;
      final parser = parserFor((request) async {
        switch (request.url.path) {
          case '/share/wxlist':
            return listing([item(1)]);
          case '/share/tplconfig':
            return response({
              'errno': 0,
              'data': {'sign': 'wx', 'timestamp': 1}
            });
          case '/api/sharedownload':
            downloads++;
            return response({'errno': 9019});
          case '/share/init':
            return response({});
          case '/share/verify':
            return response({'errno': 0, 'randsk': 'key'});
          case '/s/1fixture':
            return http.Response(
                '<script>locals.mset({"shareid":42,"uk":17,"sign":"web","timestamp":2});</script>',
                200);
          case '/api/gettemplatevariable':
            tokens++;
            return response({'errno': errno});
          default:
            fail('Unexpected endpoint');
        }
      });
      await expectLater(
          parser.resolve(parser.match(shareUrl)!,
              const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8),
              credential: const NetdiskCredential(cookie: 'BDUSS=account')),
          throwsA(isA<NetdiskException>()
              .having(
                  (e) => e.code,
                  'code',
                  errno == 9019
                      ? NetdiskErrorCode.verificationRequired
                      : NetdiskErrorCode.credentialExpired)
              .having(
                  (e) => e.detail, 'stage', 'stage=bdstoken errno=$errno')));
      expect(downloads, 1);
      expect(tokens, 1);
    });
  }

  test('public xpan context never inherits another share key', () async {
    var downloads = 0;
    final parser = parserFor((request) async {
      switch (request.url.path) {
        case '/share/wxlist':
          return listing([item(1)]);
        case '/share/tplconfig':
          return response({
            'errno': 0,
            'data': {'sign': 'sign', 'timestamp': 1}
          });
        case '/api/sharedownload':
          downloads++;
          if (downloads == 1) return response({'errno': 9019});
          expect(request.bodyFields['extra'], isNull);
          return response({
            'errno': 0,
            'list': [
              {'dlink': 'https://d.pcs.baidu.com/public'}
            ]
          });
        case '/share/init':
          return response({});
        case '/s/1fixture':
          return http.Response('<html>unknown</html>', 200);
        case '/rest/2.0/xpan/share':
          expect(request.url.queryParameters['sekey'], isNull);
          expect(request.headers['Cookie'] ?? '', isNot(contains('BDCLND')));
          return response({'errno': 0, 'share_id': 42, 'uk': 17, 'list': []});
        default:
          fail('Unexpected endpoint');
      }
    });
    await parser.resolve(parser.match('https://pan.baidu.com/s/1fixture')!,
        const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8),
        credential: const NetdiskCredential(cookie: 'BDCLND=unrelated-share'));
    expect(downloads, 2);
  });
  test('matches only real supported hosts and personal share paths', () {
    final parser = parserFor((_) async => response({}));
    expect(parser.match('https://evilbaidu.com/s/1fixture'), isNull);
    expect(parser.match('https://pan.baidu.com.evil.test/s/1fixture'), isNull);
    expect(
        parser.match('https://pan.baidu.com/apaas/share?surl=fixture'), isNull);
    expect(parser.match('https://pan.baidu.com/s/1fixture/extra'), isNull);
    expect(
        parser.match('https://yun.baidu.com/s/1fixture')?.shareId, '1fixture');
  });

  test('anonymous listing succeeds without bootstrap or download requests',
      () async {
    final requests = <http.Request>[];
    final parser = parserFor((request) async {
      requests.add(request);
      expect(request.url.path, '/share/wxlist');
      expect(request.bodyFields['shorturl'], '1fixture');
      expect(request.bodyFields['pwd'], 'abcd');
      expect(request.headers['Cookie'], 'ndut_fmt=');
      expect(request.headers['Accept'], '*/*');
      return listing([item(1)]);
    });
    final share = await parser.parse(parser.match(shareUrl)!);
    expect(share.files.single.name, 'sample.bin');
    expect(share.files.single.size, 8);
    expect(share.files.single.extra['relativePath'], 'sample.bin');
    expect(requests, hasLength(1));
  });

  test('init surl is normalized even if its first character is 1', () async {
    final parser = parserFor((request) async {
      expect(request.bodyFields['shorturl'], '11fixture');
      return listing([item(1)]);
    });
    await parser
        .parse(parser.match('https://pan.baidu.com/share/init?surl=1fixture')!);
  });

  test('pagination and recursive directories preserve relative paths',
      () async {
    final requests = <http.Request>[];
    final parser = parserFor((request) async {
      requests.add(request);
      final fields = request.bodyFields;
      if (fields['root'] == '1') {
        if (fields['page'] == '1') {
          return listing([item(1, name: 'a', folder: true, path: '/owner/a')],
              more: true);
        }
        return listing([item(2, name: 'sample.bin')]);
      }
      expect(fields['dir'], '/owner/a');
      expect(fields['root'], '0');
      return listing([item(3, path: '/owner/a/sample.bin')]);
    });
    final share = await parser.parse(parser.match(shareUrl)!);
    expect(share.files.map((f) => f.extra['relativePath']),
        ['a/sample.bin', 'sample.bin']);
    expect(share.files.every((f) => f.isFile), isTrue);
    expect(requests, hasLength(3));
  });

  test('password failures keep their meaning and do not fall through',
      () async {
    var count = 0;
    final parser = parserFor((request) async {
      count++;
      return response({'errno': -130, 'errtype': 'mispwd-9'});
    });
    await expectLater(parser.parse(parser.match(shareUrl)!),
        throwsA(errorCode(NetdiskErrorCode.passwordWrong)));
    expect(count, 1);
  });

  test('protected share without a supplied password requests one', () async {
    final parser = parserFor(
        (_) async => response({'errno': -130, 'errtype': 'mispwd-9'}));
    await expectLater(
        parser.parse(parser.match('https://pan.baidu.com/s/1fixture')!),
        throwsA(errorCode(NetdiskErrorCode.passwordRequired)));
  });

  test('successful empty directory response maps to emptyShare', () async {
    final parser = parserFor((_) async => listing([]));
    await expectLater(parser.parse(parser.match(shareUrl)!),
        throwsA(errorCode(NetdiskErrorCode.emptyShare)));
  });

  test('recursive cycles terminate with a typed error', () async {
    var requests = 0;
    final parser = parserFor((_) async {
      requests++;
      return listing([item(1, folder: true, path: '/cycle')]);
    });
    await expectLater(parser.parse(parser.match(shareUrl)!),
        throwsA(errorCode(NetdiskErrorCode.badResponse)));
    expect(requests, 2);
  });

  test('wx invalid share maps to shareNotFound', () async {
    final parser = parserFor((_) async => response({'errno': 2}));
    await expectLater(parser.parse(parser.match(shareUrl)!),
        throwsA(errorCode(NetdiskErrorCode.shareNotFound)));
  });

  for (final authenticated in [false, true]) {
    test('download token failure, authenticated=$authenticated', () async {
      final parser = parserFor((request) async {
        switch (request.url.path) {
          case '/share/wxlist':
            return listing([item(1)]);
          case '/share/tplconfig':
            expect(request.url.queryParameters['surl'], '1fixture');
            return response({
              'errno': 0,
              'data': {'sign': 'fixture-sign', 'timestamp': 1}
            });
          case '/share/init':
            return response({});
          case '/share/verify':
            return response({'errno': 0, 'randsk': 'web-key'});
          case '/s/1fixture':
            return http.Response(
                '<script>yunData.setData({"shareid":42,"uk":17,"sign":"web-sign","timestamp":1});</script>',
                200);
          case '/api/gettemplatevariable':
            return response({
              'errno': 0,
              'result': {'bdstoken': 'browser-csrf'}
            });
          case '/api/sharedownload':
            expect(jsonDecode(request.bodyFields['extra']!), {
              'sekey': request.url.queryParameters['clienttype'] == '12'
                  ? 'fixture-key'
                  : 'web-key'
            });
            expect(request.bodyFields['fid_list'], '[1]');
            return response({'errno': 9019});
          default:
            fail('Unexpected endpoint');
        }
      });
      await expectLater(
          parser.resolve(parser.match(shareUrl)!,
              const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8),
              credential: authenticated
                  ? const NetdiskCredential(cookie: 'BDUSS=fixture')
                  : const NetdiskCredential.none()),
          throwsA(errorCode(NetdiskErrorCode.verificationRequired)));
    });
  }

  test(
      '113 reports signature/captcha failure without claiming login is mandatory',
      () async {
    final parser = parserFor((request) async {
      if (request.url.path == '/share/wxlist') return listing([item(1)]);
      if (request.url.path == '/share/tplconfig') {
        return response({
          'errno': 0,
          'data': {'sign': 's', 'timestamp': 1}
        });
      }
      return response({'errno': 113});
    });
    await expectLater(
        parser.resolve(parser.match(shareUrl)!,
            const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8)),
        throwsA(errorCode(NetdiskErrorCode.badResponse)));
  });

  test('successful download validates the file and does not leak login cookies',
      () async {
    final parser = parserFor((request) async {
      if (request.url.path == '/share/wxlist') return listing([item(1)]);
      if (request.url.path == '/share/tplconfig') {
        return response({
          'errno': 0,
          'data': {'sign': 's', 'timestamp': 1}
        });
      }
      return response({
        'errno': 0,
        'list': [
          {'fs_id': 99, 'dlink': 'https://cdn.example.test/wrong'},
          {'fs_id': 1, 'dlink': 'https://cdn.example.test/sample'},
        ]
      });
    });
    final result = await parser.resolve(parser.match(shareUrl)!,
        const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8),
        credential: const NetdiskCredential(cookie: 'BDUSS=fixture'));
    expect(result.url, 'https://cdn.example.test/sample');
    expect(result.headers['User-Agent'], BaiduParser.downloadUserAgent);
    expect(result.headers['Cookie'], isNull);
    expect(result.expiresAt, isNull);
  });

  test(
      'web fallback normalizes init/verify and accepts locals.mset with escaped JSON',
      () async {
    final parser = parserFor((request) async {
      switch (request.url.path) {
        case '/share/wxlist':
          return response({}, status: 404);
        case '/share/init':
          expect(request.url.queryParameters['surl'], 'fixture');
          return response({}, headers: {'set-cookie': 'BAIDUID=new; Path=/'});
        case '/share/verify':
          expect(request.url.queryParameters['surl'], 'fixture');
          return response({'errno': 0, 'randsk': 'key/value+'});
        case '/s/1fixture':
          final cookie = request.headers['Cookie']!;
          expect(cookie, contains('BDCLND=key%2Fvalue%2B'));
          expect(cookie, isNot(contains('null')));
          expect(RegExp('BAIDUID=').allMatches(cookie), hasLength(1));
          return http.Response(
              '<script>locals.mset(  ${jsonEncode({
                    'shareid': 42,
                    'share_uk': 17,
                    'sign': '',
                    'timestamp': '',
                    'title': 'quoted " and \\ bracket }',
                  })} );</script>',
              200);
        case '/share/list':
          expect(request.url.queryParameters['root'], '1');
          expect(request.url.queryParameters.containsKey('dir'), isFalse);
          return response({
            'errno': 0,
            'list': [item(1)]
          });
        case '/share/tplconfig':
          expect(request.url.queryParameters['surl'], '1fixture');
          return response({
            'errno': 0,
            'data': {'sign': 'new-sign', 'timestamp': 2}
          });
        case '/api/sharedownload':
          expect(request.url.queryParameters['sign'], 'new-sign');
          expect(jsonDecode(request.bodyFields['extra']!),
              {'sekey': 'key/value+'});
          return response({
            'errno': 0,
            'list': [
              {'dlink': 'https://cdn.example.test/file'}
            ]
          });
        default:
          fail('Unexpected endpoint');
      }
    });
    final result = await parser.resolve(parser.match(shareUrl)!,
        const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8),
        credential:
            const NetdiskCredential(cookie: 'BAIDUID=old; BDCLND=old-key'));
    expect(result.url, 'https://cdn.example.test/file');
  });

  test('download rejects non-HTTP links', () async {
    final parser = parserFor((request) async {
      if (request.url.path == '/share/wxlist') return listing([item(1)]);
      if (request.url.path == '/share/tplconfig') {
        return response({
          'errno': 0,
          'data': {'sign': 's', 'timestamp': 1}
        });
      }
      return response({
        'errno': 0,
        'list': [
          {'dlink': 'javascript:bad()'}
        ]
      });
    });
    await expectLater(
        parser.resolve(parser.match(shareUrl)!,
            const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8)),
        throwsA(errorCode(NetdiskErrorCode.badResponse)));
  });

  test('missing signature fails before issuing a malformed download request',
      () async {
    var downloaded = false;
    final parser = parserFor((request) async {
      if (request.url.path == '/share/wxlist') return listing([item(1)]);
      if (request.url.path == '/api/sharedownload') downloaded = true;
      return response({'errno': 0, 'data': {}});
    });
    await expectLater(
        parser.resolve(parser.match(shareUrl)!,
            const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8)),
        throwsA(errorCode(NetdiskErrorCode.badResponse)));
    expect(downloaded, isFalse);
  });
  test(
      'wxlist seckey is preserved as protocol data and is not decoded like BDCLND',
      () async {
    const wxKey = 'opaque%2Fvalue%2Bdata%3D';
    final parser = parserFor((request) async {
      expect(request.headers['User-Agent'], 'netdisk');
      expect(request.headers['Accept'], '*/*');
      switch (request.url.path) {
        case '/share/wxlist':
          expect(request.headers['User-Agent'], 'netdisk');
          expect(request.headers['Accept'], '*/*');
          return response({
            'errno': 0,
            'data': {
              'shareid': 42,
              'uk': 17,
              'seckey': wxKey,
              'list': [item(1)],
              'has_more': false,
            }
          });
        case '/share/tplconfig':
          expect(request.url.queryParameters['surl'], '1fixture');
          expect(request.url.queryParameters['clienttype'], '0');
          return response({
            'errno': 0,
            'data': {'sign': 'fixture-sign', 'timestamp': 123}
          });
        case '/api/sharedownload':
          expect(request.url.queryParameters['clienttype'], '12');
          expect(request.url.queryParameters['sign'], 'fixture-sign');
          expect(request.url.queryParameters['timestamp'], '123');
          expect(request.bodyFields['type'], 'nolimit');
          expect(request.bodyFields['fid_list'], '[1]');
          expect(request.bodyFields['primaryid'], '42');
          expect(request.bodyFields['uk'], '17');
          expect(jsonDecode(request.bodyFields['extra']!), {'sekey': wxKey});
          expect(request.headers['Cookie'], contains('BDUSS=fixture-account'));
          return response({
            'errno': 0,
            'list': [
              {'dlink': 'https://cdn.example.test/file'}
            ]
          });
        default:
          fail('Unexpected endpoint');
      }
    });
    final direct = await parser.resolve(parser.match(shareUrl)!,
        const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8),
        credential: const NetdiskCredential(
            cookie: 'BDUSS=fixture-account; BDCLND=older%2Fkey'));
    expect(direct.url, 'https://cdn.example.test/file');
  });
  for (final stage in ['wxlist']) {
    test('9019 identifies $stage without assuming a nonempty BDUSS expired',
        () async {
      final parser = parserFor((request) async {
        final current = request.url.path.split('/').last;
        if (current == stage) {
          return response({
            'errno': 9019,
            'errmsg': 'need verify',
            'private': 'hidden-provider-data'
          });
        }
        if (current == 'wxlist') return listing([item(1)]);
        if (current == 'tplconfig') {
          return response({
            'errno': 0,
            'data': {'sign': 'private-sign', 'timestamp': 1}
          });
        }
        fail('Unexpected endpoint');
      });
      await expectLater(
          parser.resolve(parser.match(shareUrl)!,
              const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8),
              credential: const NetdiskCredential(
                  cookie: 'BDUSS=private-account; STOKEN=private-token')),
          throwsA(isA<NetdiskException>()
              .having(
                  (e) => e.code, 'code', NetdiskErrorCode.verificationRequired)
              .having((e) => e.message, 'message', contains('验证'))
              .having((e) => e.detail, 'detail', 'stage=$stage errno=9019')
              .having((e) => e.toString(), 'redacted',
                  isNot(contains('private')))));
    });
  }
  for (final outcome in [
    'success',
    'web9019',
    'webCaptcha',
    'pageCaptcha',
    'pageUnknown',
    'verify9019'
  ]) {
    test('authenticated WX 9019 uses one official browser fallback: $outcome',
        () async {
      final requests = <http.Request>[];
      var downloads = 0;
      final parser = parserFor((request) async {
        requests.add(request);
        switch (request.url.path) {
          case '/share/wxlist':
            return listing([item(1)]);
          case '/share/tplconfig':
            expect(request.headers['User-Agent'], 'netdisk');
            return response({
              'errno': 0,
              'data': {'sign': 'wx-sign', 'timestamp': 1}
            });
          case '/share/init':
            expect(request.url.queryParameters['surl'], 'fixture');
            expect(request.headers['User-Agent'], contains('Mozilla'));
            return response({},
                headers: {'set-cookie': 'BAIDUID=browser-fixture; Path=/'});
          case '/share/verify':
            expect(request.bodyFields['pwd'], 'abcd');
            if (outcome == 'verify9019') return response({'errno': 9019});
            return response({'errno': 0, 'randsk': 'browser/key+'});
          case '/s/1fixture':
            expect(
                request.headers['Cookie'], contains('BDCLND=browser%2Fkey%2B'));
            if (outcome == 'pageUnknown') {
              return http.Response('<html>unknown provider page</html>', 200);
            }
            if (outcome == 'pageCaptcha') {
              return http.Response.bytes(
                  utf8.encode('<html>请完成安全验证</html>'), 200);
            }
            return http.Response(
                '<script>locals.mset(${jsonEncode({
                      'shareid': 42,
                      'uk': 17,
                      'sign': 'browser-sign',
                      'timestamp': 2,
                      'bdstoken': 'browser-csrf',
                      'sekey': 'older-page-key',
                    })});</script>',
                200);
          case '/rest/2.0/xpan/share':
            expect(outcome, 'pageUnknown');
            return response({'errno': 9019});
          case '/api/sharedownload':
            downloads++;
            if (downloads == 1) {
              expect(request.url.queryParameters['clienttype'], '12');
              expect(request.headers['User-Agent'], 'netdisk');
              return response({'errno': 9019});
            }
            expect(downloads, 2,
                reason: 'Only one browser download request is permitted');
            expect(request.url.queryParameters['clienttype'], '0');
            expect(request.url.queryParameters['sign'], 'browser-sign');
            expect(request.url.queryParameters['timestamp'], '2');
            expect(request.url.queryParameters['bdstoken'], 'browser-csrf');
            expect(request.bodyFields.containsKey('type'), false);
            expect(request.headers['User-Agent'], contains('Mozilla'));
            expect(request.headers['Origin'], 'https://pan.baidu.com');
            expect(
                request.headers['Referer'], 'https://pan.baidu.com/s/1fixture');
            expect(request.headers['X-Requested-With'], 'XMLHttpRequest');
            expect(jsonDecode(request.bodyFields['extra']!),
                {'sekey': 'browser/key+'});
            if (outcome == 'web9019') return response({'errno': 9019});
            if (outcome == 'webCaptcha') return response({'errno': -20});
            return response({
              'errno': 0,
              'list': [
                {'dlink': 'https://cdn.example.test/verified'}
              ]
            });
          default:
            fail('Unexpected endpoint');
        }
      });
      final pending = parser.resolve(parser.match(shareUrl)!,
          const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8),
          credential: const NetdiskCredential(cookie: 'BDUSS=fixture-account'));
      if (outcome == 'success') {
        final direct = await pending;
        expect(direct.url, 'https://cdn.example.test/verified');
        expect(direct.headers['Cookie'], isNull);
      } else {
        final stage = outcome == 'pageUnknown'
            ? 'xpanshare'
            : outcome == 'pageCaptcha'
                ? 'sharepage'
                : outcome == 'verify9019'
                    ? 'verify'
                    : 'websharedownload';
        final errno = outcome == 'pageCaptcha'
            ? 'unknown'
            : outcome == 'webCaptcha'
                ? '-20'
                : '9019';
        await expectLater(
            pending,
            throwsA(isA<NetdiskException>()
                .having((e) => e.code, 'code',
                    NetdiskErrorCode.verificationRequired)
                .having(
                    (e) => e.detail, 'detail', 'stage=$stage errno=$errno')));
      }
      expect(
          downloads,
          outcome == 'pageCaptcha' ||
                  outcome == 'pageUnknown' ||
                  outcome == 'verify9019'
              ? 1
              : 2);
      expect(requests.where((r) => r.url.path == '/share/init'), hasLength(1));
      expect(
          requests.where((r) => r.url.path == '/share/verify'), hasLength(1));
      expect(requests.where((r) => r.url.path == '/share/tplconfig'),
          hasLength(1));
    });
  }

  test('anonymous 9019 tries the browser once and remains verificationRequired',
      () async {
    final requests = <http.Request>[];
    var downloads = 0;
    final parser = parserFor((request) async {
      requests.add(request);
      switch (request.url.path) {
        case '/share/wxlist':
          return listing([item(1)]);
        case '/share/tplconfig':
          return response({
            'errno': 0,
            'data': {'sign': 'wx-sign', 'timestamp': 1}
          });
        case '/share/init':
          return response({});
        case '/share/verify':
          return response({'errno': 0, 'randsk': 'browser-key'});
        case '/s/1fixture':
          return http.Response(
              '<script>locals.mset({"shareid":42,"uk":17,"sign":"web-sign","timestamp":2});</script>',
              200);
        case '/api/sharedownload':
          downloads++;
          if (downloads == 2) {
            expect(request.url.queryParameters['bdstoken'], isNull);
            expect(request.url.queryParameters['clienttype'], '0');
          }
          return response({'errno': 9019});
        default:
          fail('Unexpected endpoint');
      }
    });
    await expectLater(
        parser.resolve(parser.match(shareUrl)!,
            const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8)),
        throwsA(errorCode(NetdiskErrorCode.verificationRequired)));
    expect(downloads, 2);
    expect(requests, hasLength(7));
    expect(requests.where((r) => r.url.path == '/api/gettemplatevariable'),
        isEmpty);
  });
  test(
      'WX isolates the minimal BDUSS and empty ndut_fmt session from browser cookies',
      () async {
    const browserCookies =
        'BAIDUID=old-browser; PANPSC=old-panpsc; STOKEN=old-stoken; BDUSS=fixture-account; BDCLND=old-share';
    final requests = <http.Request>[];
    final parser = parserFor((request) async {
      requests.add(request);
      expect(request.headers['Cookie'], 'BDUSS=fixture-account; ndut_fmt=');
      expect(request.headers['User-Agent'], 'netdisk');
      expect(request.headers['Accept'], '*/*');
      expect(request.headers['Referer'], isNull);
      if (request.url.path == '/share/wxlist') return listing([item(1)]);
      if (request.url.path == '/share/tplconfig') {
        return response({
          'errno': 0,
          'data': {'sign': 'fixture-sign', 'timestamp': 1}
        }, headers: {
          'set-cookie': 'STOKEN=other-browser-state; Path=/'
        });
      }
      expect(request.url.path, '/api/sharedownload');
      return response({
        'errno': 0,
        'list': [
          {'dlink': 'https://cdn.example.test/file'}
        ]
      });
    });
    const credential = NetdiskCredential(cookie: browserCookies);
    await parser.resolve(parser.match(shareUrl)!,
        const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8),
        credential: credential);
    expect(requests, hasLength(3));
    expect(credential.cookie, browserCookies);
  });

  test('an unknown page tries JSON once and safely reports malformed context',
      () async {
    final parser = parserFor((request) async {
      switch (request.url.path) {
        case '/share/wxlist':
          return response({}, status: 404);
        case '/share/init':
          return response({});
        case '/share/verify':
          return response({'errno': 0, 'randsk': 'fixture-key'});
        case '/s/1fixture':
          return http.Response('<html>private-page-content</html>', 200);
        case '/rest/2.0/xpan/share':
          return response({'errno': 0, 'private': 'private-page-content'});
        default:
          fail('Unexpected endpoint');
      }
    });
    await expectLater(
        parser.parse(parser.match(shareUrl)!),
        throwsA(isA<NetdiskException>()
            .having((e) => e.code, 'code', NetdiskErrorCode.badResponse)
            .having((e) => e.detail, 'detail', 'stage=xpanshare errno=0')
            .having((e) => e.toString(), 'redacted',
                isNot(contains('private-page-content')))));
  });
  test(
      'web errno-zero string list reports the documented direct-download restriction',
      () async {
    final parser = browserDownloadResponse({
      'errno': 0,
      'list': 'private-provider-restriction-value',
      'request_id': 'private-request-id'
    });
    await expectLater(
        parser.resolve(parser.match(shareUrl)!,
            const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8),
            credential:
                const NetdiskCredential(cookie: 'BDUSS=fixture-account')),
        throwsA(isA<NetdiskException>()
            .having((e) => e.code, 'code', NetdiskErrorCode.sizeLimitExceeded)
            .having((e) => e.statusCode, 'status', 200)
            .having((e) => e.detail, 'stage',
                startsWith('stage=websharedownload errno=0 '))
            .having((e) => e.detail, 'shape',
                contains('listType=string itemCount=0'))
            .having(
                (e) => e.toString(), 'redacted', isNot(contains('private-')))));
  });

  final malformedDownloads = <String, Map<String, Object?>>{
    'empty-list': {'errno': 0, 'list': <Object?>[]},
    'list-object': {
      'errno': 0,
      'list': {'dlink': 'https://private.example.test/private-link'}
    },
    'nested-data': {
      'errno': 0,
      'data': {
        'list': [
          {'dlink': 'https://private.example.test/private-link'}
        ]
      }
    },
    'object-dlink': {
      'errno': 0,
      'list': [
        {
          'fs_id': 1,
          'dlink': {'url': 'https://private.example.test/private-link'}
        }
      ]
    },
    'wrong-file': {
      'errno': 0,
      'list': [
        {'fs_id': 2, 'dlink': 'https://private.example.test/private-link'}
      ]
    },
    'empty-dlink': {
      'errno': 0,
      'list': [
        {'fs_id': 1, 'dlink': ''}
      ]
    },
    'batch-dlink': {
      'errno': 0,
      'dlink': 'https://private.example.test/private-batch-link'
    },
  };
  for (final entry in malformedDownloads.entries) {
    test(
        'web errno-zero ${entry.key} remains a redacted badResponse with HTTP status',
        () async {
      final parser = browserDownloadResponse(
          {...entry.value, 'private-filename.key': 'private-cookie-value'});
      await expectLater(
          parser.resolve(parser.match(shareUrl)!,
              const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8),
              credential:
                  const NetdiskCredential(cookie: 'BDUSS=fixture-account')),
          throwsA(isA<NetdiskException>()
              .having((e) => e.code, 'code', NetdiskErrorCode.badResponse)
              .having((e) => e.statusCode, 'status', 200)
              .having((e) => e.detail, 'stage',
                  startsWith('stage=websharedownload errno=0 '))
              .having(
                  (e) => e.detail, 'safe shape', contains('unknownKeyCount=1'))
              .having((e) => e.toString(), 'redacted',
                  isNot(contains('private-')))));
    });
  }

  test(
      'mismatched file diagnostics distinguish target matching from response type without IDs',
      () async {
    final parser = browserDownloadResponse({
      'errno': 0,
      'list': [
        {'fs_id': 999, 'dlink': 'https://private.example.test/hidden'}
      ]
    });
    await expectLater(
        parser.resolve(parser.match(shareUrl)!,
            const NetdiskFile(fileId: '1', name: 'sample.bin', size: 8),
            credential:
                const NetdiskCredential(cookie: 'BDUSS=fixture-account')),
        throwsA(isA<NetdiskException>()
            .having((e) => e.detail, 'shape',
                contains('listType=array itemCount=1'))
            .having((e) => e.detail, 'match',
                contains('targetMatched=0 dlinkType=null'))
            .having((e) => e.detail, 'no ID', isNot(contains('999')))));
  });
}
