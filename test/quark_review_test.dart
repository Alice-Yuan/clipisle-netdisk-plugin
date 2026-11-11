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

  group('Quark account credential updates', () {
    const original = NetdiskCredential(
      cookie: 'custom=keep; __pus=old-pus; __puus=old-puus; ctoken=old-token',
      accessToken: 'unrelated-access',
      refreshToken: 'unrelated-refresh',
      baiduBdstoken: 'unrelated-bdstoken',
    );
    const file = NetdiskFile(fileId: 'f', name: 'fixture.bin', size: 1);

    NetdiskClient createClient({
      Map<String, String> tokenHeaders = const {},
      Map<String, String> listHeaders = const {},
      Map<String, String> downloadHeaders = const {},
      required CredentialUpdatedCallback callback,
    }) {
      final client = NetdiskClient(
        onCredentialUpdated: callback,
        http: HttpClient(client: MockClient((request) async {
          if (request.url.path.endsWith('/token')) {
            return reply({
              'code': 0,
              'data': {'stoken': 'fixture-token'}
            }, headers: tokenHeaders);
          }
          if (request.method == 'GET') {
            return reply({
              'code': 0,
              'data': {
                'list': [entry('f')]
              }
            }, headers: listHeaders);
          }
          return reply({
            'code': 0,
            'data': [
              {'download_url': 'https://dl.quark.cn/fixture'}
            ]
          }, headers: downloadHeaders);
        })),
      );
      addTearDown(client.close);
      return client;
    }

    test('anonymous tokens stay operation-local and never create an account',
        () async {
      var updates = 0;
      final client = createClient(
          tokenHeaders: {
            'set-cookie': '__pugs=guest; Path=/'
          },
          downloadHeaders: {
            'set-cookie': '__sdid=device; Path=/, __puus=guest-shaped; Path=/'
          },
          callback: (_, __, ___) {
            updates++;
          });
      final direct = await client.resolveDownloadFrom(link, file);
      expect(updates, 0);
      expect(direct.headers['Cookie'], contains('__pugs=guest'));
      expect(direct.headers['Cookie'], contains('__sdid=device'));
      expect(direct.headers['Cookie'], contains('__puus=guest-shaped'));
    });

    test(
        'successful parse emits one final allowlisted update with original before',
        () async {
      final changes = <(NetdiskCredential, NetdiskCredential)>[];
      final client = createClient(
          tokenHeaders: {
            'set-cookie': '__puus=middle; Path=/, __pugs=guest; Path=/'
          },
          listHeaders: {
            'set-cookie': '__puus=latest; Path=/, __pus=new-pus; Path=/, '
                'ctoken=new-token; Path=/, __sdid=device; Path=/, custom=replace'
          },
          callback: (platform, before, after) async {
            expect(platform, NetdiskPlatform.quark);
            changes.add((before, after));
          });
      final share = await client.parseLink(link, credential: original);
      expect(share.files, hasLength(1));
      expect(changes, hasLength(1));
      expect(identical(changes.single.$1, original), isTrue);
      final after = changes.single.$2;
      expect(after.cookieValue('__puus'), 'latest');
      expect(after.cookieValue('__pus'), 'new-pus');
      expect(after.cookieValue('ctoken'), 'new-token');
      expect(after.cookieValue('custom'), 'keep');
      expect(after.cookieValue('__pugs'), isNull);
      expect(after.cookieValue('__sdid'), isNull);
      expect(after.accessToken, original.accessToken);
      expect(after.refreshToken, original.refreshToken);
      expect(after.baiduBdstoken, original.baiduBdstoken);
      // Reusing the parsed context without new response changes must not emit
      // the parse update a second time merely because a fork inherited it.
      await client.resolveDownload(share, share.files.single,
          credential: original);
      expect(changes, hasLength(1));
    });

    test('resolve publishes latest cookie and binds it to the returned URL',
        () async {
      final changes = <(NetdiskCredential, NetdiskCredential)>[];
      final client = createClient(
          tokenHeaders: {'set-cookie': '__puus=middle; Path=/'},
          listHeaders: {'set-cookie': '__puus=listed; Path=/'},
          downloadHeaders: {'set-cookie': '__puus=download; Path=/'},
          callback: (_, before, after) {
            changes.add((before, after));
          });
      final direct =
          await client.resolveDownloadFrom(link, file, credential: original);
      expect(changes, hasLength(1));
      expect(identical(changes.single.$1, original), isTrue);
      expect(changes.single.$2.cookieValue('__puus'), 'download');
      expect(direct.headers['Cookie'], contains('__puus=download'));
    });

    test('unchanged account cookies and guest-only changes do not notify',
        () async {
      var updates = 0;
      final client = createClient(
          tokenHeaders: {
            'set-cookie': '__puus=old-puus; Path=/, __pugs=guest; Path=/'
          },
          listHeaders: {
            'set-cookie': '__sdid=device; Path=/'
          },
          callback: (_, __, ___) {
            updates++;
          });
      await client.parseLink(link, credential: original);
      await client.resolveDownloadFrom(link, file, credential: original);
      expect(updates, 0);
    });

    for (final deletion in [
      '__puus=; Path=/',
      '__puus=deleted; Max-Age=0',
      '__puus=deleted; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
      '__puus=deleted; Max-Age=0; Expires=Fri, 01 Jan 2100 00:00:00 GMT',
      '__puus=deleted; Max-Age=invalid; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
      '__puus=deleted; Max-Age=0invalid; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
      '__pus=; Path=/',
    ]) {
      test('cleared login is not recreated by guest tokens: $deletion',
          () async {
        final changes = <NetdiskCredential>[];
        final client = createClient(
            tokenHeaders: {'set-cookie': deletion},
            listHeaders: {'set-cookie': '__puus=guest-shaped; Path=/'},
            callback: (_, before, after) {
              expect(identical(before, original), isTrue);
              changes.add(after);
            });
        await client.resolveDownloadFrom(link, file, credential: original);
        expect(changes, hasLength(1));
        expect(
            changes.single.cookieValue(
                deletion.startsWith('__pus=') ? '__pus' : '__puus'),
            isNull);
        expect(changes.single.cookieValue('__puus'), isNot('guest-shaped'));
      });
    }

    for (final attributes in [
      'Expires=Fri, 01 Jan 2100 00:00:00 GMT',
      'Expires=invalid-date',
      'Max-Age=60; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
      'Max-Age=999999999999999999999999999999; '
          'Expires=Thu, 01 Jan 1970 00:00:00 GMT',
      'Max-Age=0invalid; Expires=Fri, 01 Jan 2100 00:00:00 GMT',
    ]) {
      test('cookie expiration retains a valid login: $attributes', () async {
        final changes = <NetdiskCredential>[];
        final client = createClient(
            downloadHeaders: {
              'set-cookie': '__puus=fresh; $attributes, __pugs=guest; Path=/'
            },
            callback: (_, __, after) {
              changes.add(after);
            });
        final direct =
            await client.resolveDownloadFrom(link, file, credential: original);
        expect(changes, hasLength(1));
        expect(changes.single.cookieValue('__puus'), 'fresh');
        expect(changes.single.cookieValue('__pugs'), isNull);
        expect(direct.headers['Cookie'], contains('__puus=fresh'));
        expect(direct.headers['Cookie'], contains('__pugs=guest'));
      });
    }

    for (final asynchronous in [false, true]) {
      test('callback failure cannot invalidate download (async=$asynchronous)',
          () async {
        final client = createClient(
            downloadHeaders: {'set-cookie': '__puus=new; Path=/'},
            callback: (_, __, ___) {
              if (asynchronous) return Future<void>.error(StateError('store'));
              throw StateError('store');
            });
        final direct =
            await client.resolveDownloadFrom(link, file, credential: original);
        expect(direct.url, 'https://dl.quark.cn/fixture');
        expect(direct.headers['Cookie'], contains('__puus=new'));
      });
    }

    test('parallel forks keep distinct final updates and download headers',
        () async {
      final changes = <NetdiskCredential>[];
      final client = NetdiskClient(onCredentialUpdated: (_, before, after) {
        expect(identical(before, original), isTrue);
        changes.add(after);
      }, http: HttpClient(client: MockClient((request) async {
        if (request.url.path.endsWith('/token')) {
          return reply({
            'code': 0,
            'data': {'stoken': 'fixture'}
          });
        }
        if (request.method == 'GET') {
          return reply({
            'code': 0,
            'data': {
              'list': [entry('a'), entry('b')]
            }
          });
        }
        final id = (jsonDecode(request.body)['fids'] as List).single;
        if (id == 'a') await Future<void>.delayed(Duration.zero);
        return reply({
          'code': 0,
          'data': [
            {'download_url': 'https://dl.quark.cn/$id'}
          ]
        }, headers: {
          'set-cookie': '__puus=for-$id; Path=/'
        });
      })));
      addTearDown(client.close);
      final share = await client.parseLink(link, credential: original);
      final resolved = await client.resolveAll(link, share.files,
          credential: original, concurrency: 2);
      expect(changes, hasLength(2));
      expect(changes.map((c) => c.cookieValue('__puus')).toSet(),
          {'for-a', 'for-b'});
      for (final result in resolved) {
        expect(result.error, isNull);
        expect(result.link!.headers['Cookie'],
            contains('__puus=for-${result.file.fileId}'));
      }
    });
  });
}
