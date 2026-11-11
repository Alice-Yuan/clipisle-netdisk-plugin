import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netdisk_direct/netdisk_direct.dart';
import 'package:test/test.dart';

http.Response reply(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status);
Map<String, Object?> entry(String id, {bool folder = false}) => {
      'file_id': id,
      'name': id,
      'size': 1,
      'type': folder ? 'folder' : 'file',
    };

void main() {
  const link = ParsedShareLink(
      platform: NetdiskPlatform.aliyun,
      rawUrl: 'https://www.alipan.com/s/fixture',
      shareId: 'fixture');
  const file = NetdiskFile(fileId: 'f', name: 'fixture.bin', size: 1);

  test('Aliyun includes all marker pages, sibling folders and root files',
      () async {
    final visited = <String>[];
    final client = HttpClient(client: MockClient((request) async {
      if (request.url.path.endsWith('get_share_token')) {
        return reply({'share_token': 'fixture-share-token'});
      }
      final body = jsonDecode(request.body);
      final parent = body['parent_file_id'];
      final marker = body['marker'];
      visited.add('$parent:$marker');
      if (parent == 'root') {
        return reply({
          'items': marker == ''
              ? [entry('a', folder: true), entry('root-file')]
              : [entry('b', folder: true)],
          'next_marker': marker == '' ? 'next' : ''
        });
      }
      return reply({
        'items': [entry('child-$parent')],
        'next_marker': ''
      });
    }));
    addTearDown(client.close);
    final share = await AliyunParser(client).parse(link);
    expect(
        share.files.map((f) => f.fileId), ['root-file', 'child-a', 'child-b']);
    expect(visited, ['root:', 'root:next', 'a:', 'b:']);
    expect(share.files.last.extra['relativePath'], 'b/child-b');
  });

  test('Aliyun uses account refresh route and authenticated download_url',
      () async {
    final requests = <http.Request>[];
    final client = HttpClient(client: MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/v2/account/token') {
        expect(request.url.host, 'auth.alipan.com');
        expect(jsonDecode(request.body)['refresh_token'], 'fixture-refresh');
        return reply({'access_token': 'fixture-access'});
      }
      if (request.url.path.endsWith('get_share_token')) {
        return reply({'share_token': 'fixture-share'});
      }
      expect(request.url.path, '/v2/file/get_share_link_download_url');
      expect(request.headers['authorization'], 'Bearer fixture-access');
      expect(request.headers['x-share-token'], 'fixture-share');
      return reply({
        'download_url': 'https://example.test/file',
        'expiration': '2030-01-01T00:00:00Z'
      });
    }));
    addTearDown(client.close);
    final result = await AliyunParser(client).resolve(link, file,
        credential: const NetdiskCredential(refreshToken: 'fixture-refresh'));
    expect(result.url, 'https://example.test/file');
    expect(result.expiresAt, DateTime.utc(2030));
    expect(result.headers, isNot(contains('Authorization')));
    expect(requests, hasLength(3));
  });

  test(
      'Aliyun fails download without account credentials before making requests',
      () async {
    var calls = 0;
    final client = HttpClient(client: MockClient((_) async {
      calls++;
      return reply({});
    }));
    addTearDown(client.close);
    await expectLater(
        AliyunParser(client).resolve(link, file),
        throwsA(isA<NetdiskException>()
            .having((e) => e.code, 'code', NetdiskErrorCode.loginRequired)));
    expect(calls, 0);
  });

  test('Aliyun maps invalid access tokens to credentialExpired', () async {
    final client = HttpClient(
        client: MockClient((request) async =>
            request.url.path.endsWith('get_share_token')
                ? reply({'share_token': 'fixture-share'})
                : reply({'code': 'AccessTokenInvalid'}, status: 401)));
    addTearDown(client.close);
    await expectLater(
        AliyunParser(client).resolve(link, file,
            credential:
                const NetdiskCredential(accessToken: 'fixture-expired')),
        throwsA(isA<NetdiskException>().having(
            (e) => e.code, 'code', NetdiskErrorCode.credentialExpired)));
  });

  test('Aliyun rejects repeated markers rather than looping', () async {
    final client = HttpClient(
        client: MockClient(
            (request) async => request.url.path.endsWith('get_share_token')
                ? reply({'share_token': 'fixture-share'})
                : reply({
                    'items': [entry('f')],
                    'next_marker': 'same'
                  })));
    addTearDown(client.close);
    await expectLater(
        AliyunParser(client).parse(link),
        throwsA(isA<NetdiskException>()
            .having((e) => e.code, 'code', NetdiskErrorCode.badResponse)));
  });

  test('Aliyun rejects missing items rather than reporting an empty share',
      () async {
    final client = HttpClient(
        client: MockClient((request) async =>
            request.url.path.endsWith('get_share_token')
                ? reply({'share_token': 'fixture-share'})
                : reply({})));
    addTearDown(client.close);
    await expectLater(
        AliyunParser(client).parse(link),
        throwsA(isA<NetdiskException>()
            .having((e) => e.code, 'code', NetdiskErrorCode.badResponse)));
  });

  test('Aliyun rejects lookalike hosts', () {
    final client = HttpClient();
    addTearDown(client.close);
    expect(
        AliyunParser(client).match('https://evilalipan.com/s/fixture'), isNull);
  });
}
