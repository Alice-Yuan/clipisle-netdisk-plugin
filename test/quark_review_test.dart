import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netdisk_direct/netdisk_direct.dart';
import 'package:test/test.dart';

http.Response reply(Object body, {Map<String, String> headers = const {}}) =>
    http.Response(jsonEncode(body), 200, headers: headers);
Map<String, Object?> entry(String id, {bool folder = false, String? name}) => {
      'fid': id,
      'file_name': name ?? id,
      'size': 1,
      'dir': folder,
      'share_fid_token': 'fixture-file-token',
    };

void main() {
  const link = ParsedShareLink(
      platform: NetdiskPlatform.quark,
      rawUrl: 'https://pan.quark.cn/s/fixture',
      shareId: 'fixture');

  test('Quark retains all pages, siblings and mixed root files with paths',
      () async {
    final visited = <String>[];
    final client = HttpClient(client: MockClient((request) async {
      if (request.url.path.endsWith('/token')) {
        return reply({
          'code': 0,
          'data': {'stoken': 'fixture-token'}
        });
      }
      final parent = request.url.queryParameters['pdir_fid'];
      final page = request.url.queryParameters['_page'];
      visited.add('$parent:$page');
      final List<Map<String, Object?>> items;
      if (parent == '0' && page == '1') {
        items = [
          entry('a', folder: true),
          entry('b', folder: true),
          ...List.generate(48, (i) => entry('root$i'))
        ];
      } else if (parent == '0') {
        items = [entry('last')];
      } else {
        items = [entry('file-$parent', name: 'same.txt')];
      }
      return reply({
        'code': 0,
        'data': {'list': items}
      });
    }));
    addTearDown(client.close);
    final share = await QuarkParser(client).parse(link);
    expect(share.files, hasLength(51));
    expect(visited, ['0:1', '0:2', 'a:1', 'b:1']);
    expect(
        share.files
            .where((f) => f.name == 'same.txt')
            .map((f) => f.extra['relativePath']),
        ['a/same.txt', 'b/same.txt']);
  });

  test(
      'Quark preserves anonymous cookies through APIs and signed download headers',
      () async {
    final requests = <http.Request>[];
    final client = HttpClient(client: MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/token')) {
        return reply({
          'code': 0,
          'data': {'stoken': 'fixture-token'}
        }, headers: {
          'set-cookie': '__pugs=session-fixture; Domain=.quark.cn; Path=/'
        });
      }
      if (request.method == 'GET') {
        return reply({
          'code': 0,
          'data': {
            'list': [entry('f')]
          }
        });
      }
      expect(request.headers['cookie'], contains('__pugs=session-fixture'));
      expect(request.headers['cookie'], contains('__puus=account-fixture'));
      return reply({
        'code': 0,
        'data': [
          {'download_url': 'https://dl.quark.cn/fixture?sign=fixture'}
        ]
      }, headers: {
        'set-cookie': '__sdid=device-fixture; Domain=.quark.cn; Path=/'
      });
    }));
    addTearDown(client.close);
    final result = await QuarkParser(client).resolve(
        link, const NetdiskFile(fileId: 'f', name: 'test.bin', size: 1),
        credential: const NetdiskCredential(cookie: '__puus=account-fixture'));
    expect(
        requests.first.headers['cookie'], contains('__puus=account-fixture'));
    expect(result.headers['Cookie'], contains('__pugs=session-fixture'));
    expect(result.headers['Cookie'], contains('__sdid=device-fixture'));
    expect(result.headers['Cookie'], contains('__puus=account-fixture'));
    expect(requests.last.url.path, '/1/clouddrive/file/download');
    expect(jsonDecode(requests.last.body)['stoken'], 'fixture-token');
  });

  test(
      'Quark keeps credentials isolated and excludes cookies on other CDN hosts',
      () async {
    final tokenCookies = <String?>[];
    final client = HttpClient(client: MockClient((request) async {
      if (request.url.path.endsWith('/token')) {
        tokenCookies.add(request.headers['cookie']);
        return reply({
          'code': 0,
          'data': {'stoken': 'fixture-token'}
        });
      }
      if (request.method == 'GET') {
        return reply({
          'code': 0,
          'data': {
            'list': [entry('f')]
          }
        });
      }
      return reply({
        'code': 0,
        'data': [
          {'download_url': 'https://example.test/f'}
        ]
      });
    }));
    addTearDown(client.close);
    final parser = QuarkParser(client);
    const file = NetdiskFile(fileId: 'f', name: 'f', size: 1);
    final result = await parser.resolve(link, file,
        credential: const NetdiskCredential(cookie: '__puus=fixture'));
    await parser.resolve(link, file);
    expect(tokenCookies, ['__puus=fixture', null]);
    expect(result.headers, isNot(contains('Cookie')));
  });

  test('Quark reuses guest-bound context and refreshes it when accounts change',
      () async {
    var tokens = 0;
    var listings = 0;
    final client = HttpClient(client: MockClient((request) async {
      if (request.url.path.endsWith('/token')) {
        tokens++;
        return reply({
          'code': 0,
          'data': {'stoken': 'token-$tokens'}
        }, headers: {
          'set-cookie': '__pugs=guest-$tokens; Domain=.quark.cn; Path=/'
        });
      }
      if (request.method == 'GET') {
        listings++;
        return reply({
          'code': 0,
          'data': {
            'list': [
              {...entry('f'), 'share_fid_token': 'file-token-$tokens'}
            ]
          }
        });
      }
      final body = jsonDecode(request.body);
      expect(body['stoken'], 'token-$tokens');
      expect(body['fids_token'], ['file-token-$tokens']);
      expect(request.headers['cookie'], contains('__pugs=guest-$tokens'));
      return reply({
        'code': 0,
        'data': [
          {'download_url': 'https://dl.quark.cn/f'}
        ]
      });
    }));
    addTearDown(client.close);
    final parser = QuarkParser(client);
    final share = await parser.parse(link);
    final anonymous = await parser.resolve(link, share.files.single);
    expect(tokens, 1);
    expect(listings, 1);
    expect(anonymous.headers['Cookie'], contains('__pugs=guest-1'));
    final account = await parser.resolve(link, share.files.single,
        credential: const NetdiskCredential(cookie: '__puus=fixture-account'));
    expect(tokens, 2);
    expect(listings, 2);
    expect(account.headers['Cookie'], contains('__pugs=guest-2'));
    expect(account.headers['Cookie'], contains('__puus=fixture-account'));
  });

  test(
      'Quark resolves serialized nested files in a fresh parser using pdir_fid',
      () async {
    final requests = <http.Request>[];
    final client = HttpClient(client: MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/token')) {
        return reply({
          'code': 0,
          'data': {'stoken': 'fresh-token'}
        }, headers: {
          'set-cookie': '__pugs=fresh-guest; Domain=.quark.cn; Path=/'
        });
      }
      if (request.method == 'GET') {
        expect(request.url.queryParameters['pdir_fid'], 'nested-parent');
        return reply({
          'code': 0,
          'data': {
            'list': [
              {...entry('f'), 'share_fid_token': 'fresh-file-token'}
            ]
          }
        });
      }
      expect(jsonDecode(request.body)['fids_token'], ['fresh-file-token']);
      expect(request.headers['cookie'], contains('__pugs=fresh-guest'));
      return reply({
        'code': 0,
        'data': [
          {'download_url': 'https://dl.quark.cn/f'}
        ]
      });
    }));
    addTearDown(client.close);
    final serialized = jsonDecode(jsonEncode(
            {'pdir_fid': 'nested-parent', 'share_fid_token': 'stale-token'}))
        as Map<String, dynamic>;
    await QuarkParser(client).resolve(
        link, NetdiskFile(fileId: 'f', name: 'f', size: 1, extra: serialized));
    expect(requests.map((r) => r.method), ['POST', 'GET', 'POST']);
  });

  for (final error in {
    41008: NetdiskErrorCode.passwordRequired,
    41007: NetdiskErrorCode.passwordWrong,
    23018: NetdiskErrorCode.sizeLimitExceeded,
    31001: NetdiskErrorCode.credentialExpired
  }.entries) {
    test('Quark maps observed API code ${error.key}', () async {
      final client = HttpClient(
          client:
              MockClient((_) async => reply({'code': error.key.toString()})));
      addTearDown(client.close);
      await expectLater(
          QuarkParser(client).parse(link),
          throwsA(isA<NetdiskException>()
              .having((e) => e.code, 'code', error.value)));
    });
  }

  test(
      'Quark rejects repeated full pages rather than returning partial results',
      () async {
    final client = HttpClient(client: MockClient((request) async {
      if (request.url.path.endsWith('/token')) {
        return reply({
          'code': 0,
          'data': {'stoken': 'fixture-token'}
        });
      }
      return reply({
        'code': 0,
        'data': {'list': List.generate(50, (i) => entry('$i'))}
      });
    }));
    addTearDown(client.close);
    await expectLater(
        QuarkParser(client).parse(link),
        throwsA(isA<NetdiskException>()
            .having((e) => e.code, 'code', NetdiskErrorCode.badResponse)));
  });

  test('Quark rejects lookalike hosts', () {
    final client = HttpClient();
    addTearDown(client.close);
    expect(QuarkParser(client).match('https://evilquark.cn/s/fixture'), isNull);
  });
}
