import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netdisk_direct/netdisk_direct.dart';
import 'package:netdisk_plugin/main.dart';

const loginSecret = '__puus=private-account-fixture';
const source = 'https://pan.quark.cn/s/fixture?pwd=abcd';
const fixtureLink = ParsedShareLink(
    platform: NetdiskPlatform.quark,
    rawUrl: source,
    shareId: 'fixture',
    password: 'abcd');
const firstFile = NetdiskFile(
    fileId: 'file-1',
    name: 'sample.bin',
    size: 8,
    parentId: 'nested-parent',
    extra: {
      'relativePath': 'folder/sample.bin',
      'pdir_fid': 'nested-parent',
      'share_fid_token': 'private-file-token'
    });
const fixtureShare = NetdiskShare(
    platform: NetdiskPlatform.quark,
    shareId: 'fixture',
    title: 'Fixture share',
    files: [
      firstFile,
      NetdiskFile(fileId: 'file-2', name: 'other.bin', size: 4)
    ],
    raw: {
      'secret': 'private-api-response'
    });

class FakeNetdiskClient implements NetdiskClient {
  ParsedShareLink detected = fixtureLink;
  String? detectedInput;
  NetdiskShare share = fixtureShare;
  Future<NetdiskShare> Function()? onParse;
  Future<NetdiskDownloadLink> Function()? onResolve;
  ParsedShareLink? parsedLink;
  ParsedShareLink? resolvedLink;
  NetdiskFile? resolvedFile;
  NetdiskCredential? parsedCredential;
  NetdiskCredential? resolvedCredential;
  int closeCount = 0;
  @override
  ParsedShareLink detect(String input) {
    detectedInput = input;
    return detected;
  }

  @override
  Future<NetdiskShare> parseLink(
    ParsedShareLink link, {
    NetdiskCredential credential = const NetdiskCredential.none(),
  }) async {
    parsedLink = link;
    parsedCredential = credential;
    return onParse == null ? share : await onParse!();
  }

  @override
  Future<NetdiskDownloadLink> resolveDownloadFrom(
    ParsedShareLink link,
    NetdiskFile file, {
    NetdiskCredential credential = const NetdiskCredential.none(),
  }) async {
    resolvedLink = link;
    resolvedFile = file;
    resolvedCredential = credential;
    return onResolve == null
        ? const NetdiskDownloadLink(
            platform: NetdiskPlatform.quark,
            url: 'https://cdn.quark.cn/fixture',
            fileName: 'sample.bin',
            size: 8,
            headers: {
                'User-Agent': 'fixture-agent',
                'Referer': 'https://pan.quark.cn/'
              })
        : await onResolve!();
  }

  @override
  void close() {
    closeCount++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Fixture {
  final saved = <String, String>{};
  final clients = <FakeNetdiskClient>[];
  void Function(FakeNetdiskClient)? configure;
  NetdiskPlugin controller() => NetdiskPlugin(
        read: (key) async => saved[key],
        write: (key, value) async {
          if (value == null) {
            saved.remove(key);
          } else {
            saved[key] = value;
          }
        },
        clientFactory: () {
          final client = FakeNetdiskClient();
          configure?.call(client);
          clients.add(client);
          return client;
        },
      );
}

String sessionId(Map<String, dynamic> parsed) {
  final page = parsed['page'] as Map;
  return ((page['fields'] as List)
      .cast<Map>()
      .singleWhere((f) => f['id'] == 'sessionId')['value']) as String;
}

Future<String> parseSession(NetdiskPlugin plugin) async =>
    sessionId(await plugin.invoke('parseInput', {'input': source}));
List<Map> pageActions(Map<String, dynamic> response) =>
    ((response['page'] as Map)['actions'] as List).cast<Map>();

// Uses the real Quark parser across two independently owned HTTP sessions.
class QuarkSessionTransport extends HttpClient {
  QuarkSessionTransport(this.generation);
  final int generation;
  bool closed = false;
  final listedParents = <String>[];
  bool downloaded = false;
  HttpResult reply(Uri url, Object data,
          {Map<String, String> headers = const {}}) =>
      HttpResult(
          status: 200,
          bodyBytes: utf8.encode(jsonEncode(data)),
          headers: headers,
          url: url,
          elapsed: Duration.zero);
  @override
  Future<HttpResult> postJson(Uri url,
      {Object? body, Map<String, String>? headers}) async {
    if (url.path.endsWith('/token')) {
      return reply(url, {
        'code': 0,
        'data': {'stoken': 'stoken-$generation'}
      }, headers: {
        'set-cookie':
            '__pugs=anonymous-$generation; Path=/, __sdid=device-$generation; Path=/'
      });
    }
    expect(url.path, endsWith('/download'));
    final fields = body as Map;
    expect(fields['fids_token'], ['fresh-file-token-$generation']);
    expect(fields['stoken'], 'stoken-$generation');
    expect(headers?['Cookie'], contains('__pugs=anonymous-$generation'));
    downloaded = true;
    return reply(url, {
      'code': 0,
      'data': [
        {'download_url': 'https://cdn.quark.cn/fixture'}
      ]
    });
  }

  @override
  Future<HttpResult> get(Uri url, {Map<String, String>? headers}) async {
    final parent = url.queryParameters['pdir_fid']!;
    listedParents.add(parent);
    expect(headers?['Cookie'], contains('__pugs=anonymous-$generation'));
    return reply(url, {
      'code': 0,
      'metadata': {'_total': 1},
      'data': {
        'list': [
          if (parent == '0')
            {
              'fid': 'nested-parent',
              'file_name': 'folder',
              'dir': true,
              'share_fid_token': 'directory-$generation'
            }
          else
            {
              'fid': 'file-1',
              'file_name': 'sample.bin',
              'size': 8,
              'dir': false,
              'file_type': 1,
              'share_fid_token': 'fresh-file-token-$generation'
            },
        ]
      }
    });
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

const verificationUrl = 'https://pan.baidu.com/s/1verifyfixture';
const verificationPassword = 'wxyz';
Fixture baiduVerificationFixture(
        Future<NetdiskDownloadLink> Function() resolve) =>
    Fixture()
      ..saved['credential.baidu'] = 'BDUSS=private-baidu-account'
      ..configure = (client) {
        client.detected = const ParsedShareLink(
            platform: NetdiskPlatform.baidu,
            rawUrl: verificationUrl,
            shareId: '1verifyfixture',
            password: verificationPassword);
        client.share = const NetdiskShare(
            platform: NetdiskPlatform.baidu,
            shareId: '1verifyfixture',
            files: [firstFile]);
        client.onResolve = resolve;
      };
Future<String> selectedResource(NetdiskPlugin plugin) async {
  final parsed = await plugin.invoke('parseInput', {'input': verificationUrl});
  final prepared = await plugin.invoke('prepareDownloads', {
    'values': {'sessionId': sessionId(parsed)},
    'selectedIds': ['file-1'],
  });
  expect(prepared['ok'], true);
  return ((prepared['downloads'] as List).single as Map)['resourceId']
      as String;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parse exposes selection metadata without private parser state',
      () async {
    final fixture = Fixture()..saved['credential.quark'] = loginSecret;
    final plugin = fixture.controller();
    final result = await plugin.invoke('parseInput', {'input': source});
    expect(result['ok'], true);
    expect(sessionId(result), isNotEmpty);
    expect(
        ((result['page'] as Map)['items'] as List)
            .cast<Map>()
            .any((i) => i['type'] == 'headline'),
        true);
    final text = jsonEncode(result);
    expect(text, contains('folder/sample.bin'));
    expect(text, isNot(contains(loginSecret)));
    expect(text, isNot(contains('private-file-token')));
    expect(text, isNot(contains('private-api-response')));
    expect(fixture.clients.single.parsedCredential?.cookie, loginSecret);
    expect(fixture.clients.single.closeCount, 1);
  });

  test(
      'selected downloads persist opaque resources and resolve after restart with current credentials',
      () async {
    final fixture = Fixture()..saved['credential.quark'] = loginSecret;
    final plugin = fixture.controller();
    final sid = await parseSession(plugin);
    final prepared = await plugin.invoke('prepareDownloads', {
      'values': {
        'sessionId': sid,
        'selectedIds': ['file-1'],
      }
    });
    expect(prepared['ok'], true);
    final download = (prepared['downloads'] as List).single as Map;
    final id = download['resourceId'] as String;
    expect(id, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(download['name'], 'sample.bin');
    expect(download.keys, unorderedEquals(['resourceId', 'name', 'size']));
    expect(prepared['navigate'], 'downloads');
    expect(jsonEncode(prepared), isNot(contains('private-file-token')));
    expect(jsonEncode(prepared), isNot(contains(source)));
    expect(jsonEncode(prepared), isNot(contains(loginSecret)));
    final resource = jsonDecode(fixture.saved['resource.$id']!) as Map;
    expect(jsonEncode(resource), isNot(contains(loginSecret)));
    expect((resource['file'] as Map)['parentId'], 'nested-parent');
    fixture.saved['credential.quark'] = '__puus=replaced-fixture';
    final resumed = fixture.controller();
    final result = await resumed.invoke('resolveDownload', {'resourceId': id});
    expect(result['ok'], true);
    expect((result['download'] as Map)['url'], 'https://cdn.quark.cn/fixture');
    expect(fixture.clients.last.resolvedFile?.parentId, 'nested-parent');
    expect(
        fixture.clients.last.resolvedFile?.extra['pdir_fid'], 'nested-parent');
    expect(fixture.clients.last.resolvedLink?.password, 'abcd');
    expect(fixture.clients.last.resolvedCredential?.cookie,
        '__puus=replaced-fixture');
    expect(fixture.clients.last.closeCount, 1);
    expect(jsonEncode(result), isNot(contains(loginSecret)));
    final expired = await resumed.invoke('prepareDownloads', {
      'sessionId': sid,
      'selectedIds': ['file-1'],
    });
    expect(expired['ok'], false);
  });

  test(
      'real Quark parser refreshes nested file tokens after opaque-resource restore',
      () async {
    final saved = <String, String>{};
    final transports = <QuarkSessionTransport>[];
    NetdiskPlugin newController() => NetdiskPlugin(
          read: (key) async => saved[key],
          write: (key, value) async {
            if (value == null) {
              saved.remove(key);
            } else {
              saved[key] = value;
            }
          },
          clientFactory: () {
            final transport = QuarkSessionTransport(transports.length + 1);
            transports.add(transport);
            return NetdiskClient(http: transport);
          },
        );
    final first = newController();
    final parsed = await first.invoke('parseInput', {'input': source});
    final sid = sessionId(parsed);
    expect(jsonEncode(parsed), isNot(contains('anonymous-')));
    expect(jsonEncode(parsed), isNot(contains('stoken-')));
    expect(jsonEncode(parsed), isNot(contains('fresh-file-token-')));
    expect(transports.single.listedParents, ['0', 'nested-parent']);
    expect(transports.single.closed, true);
    final prepared = await first.invoke('prepareDownloads', {
      'values': {'sessionId': sid},
      'selectedIds': ['file-1'],
    });
    expect(prepared['ok'], true);
    final id =
        ((prepared['downloads'] as List).single as Map)['resourceId'] as String;
    final resource = saved['resource.$id']!;
    expect(resource, contains('fresh-file-token-1'));
    final restored = newController();
    final resolved =
        await restored.invoke('resolveDownload', {'resourceId': id});
    expect(resolved['ok'], true);
    expect(transports, hasLength(2));
    expect(transports.last.listedParents, ['nested-parent']);
    expect(transports.last.downloaded, true);
    expect(transports.last.closed, true);
    final result = resolved['download'] as Map;
    expect((result['headers'] as Map)['Cookie'], contains('anonymous-2'));
    // Session cookies are transient headers, never part of persisted opaque resources.
    expect(resource, isNot(contains('anonymous-')));
    expect(resource, isNot(contains('device-')));
    expect(resource, isNot(contains('stoken-')));
  });

  test('empty or forged selections do not persist resources', () async {
    final fixture = Fixture();
    final plugin = fixture.controller();
    final sid = await parseSession(plugin);
    for (final selected in [
      <String>[],
      ['unknown-file']
    ]) {
      final result = await plugin.invoke(
          'prepareDownloads', {'sessionId': sid, 'selectedIds': selected});
      expect(result['ok'], false);
      expect(result['message'], contains('至少选择'));
    }
    expect(fixture.saved.keys.where((key) => key.startsWith('resource.')),
        isEmpty);
  });

  test('over 500 selected files are rejected before persistence', () async {
    final fixture = Fixture()
      ..configure = (client) {
        client.share = NetdiskShare(
            platform: NetdiskPlatform.quark,
            shareId: 'fixture',
            files: List.generate(501,
                (i) => NetdiskFile(fileId: '$i', name: '$i.bin', size: 1)));
      };
    final plugin = fixture.controller();
    final sid = await parseSession(plugin);
    final result = await plugin.invoke('prepareDownloads', {
      'sessionId': sid,
      'selectedIds': List.generate(501, (i) => '$i'),
    });
    expect(result['ok'], false);
    expect(result['message'], contains('500'));
    expect(fixture.saved, isEmpty);
  });

  test(
      'password recovery preserves input and accepts a corrected explicit password',
      () async {
    var attempts = 0;
    final fixture = Fixture()
      ..configure = (client) {
        client.onParse = () async {
          attempts++;
          if (attempts == 1) {
            throw const NetdiskException(
                NetdiskErrorCode.passwordWrong, 'private-provider-error',
                detail: loginSecret);
          }
          return fixtureShare;
        };
      };
    final plugin = fixture.controller();
    final recovered = await plugin.invoke('parseInput', {'input': source});
    expect(recovered['ok'], true);
    final fields = ((recovered['page'] as Map)['fields'] as List).cast<Map>();
    expect(fields.singleWhere((f) => f['id'] == 'input')['value'], source);
    expect(fields.any((f) => f['id'] == 'password'), true);
    expect(jsonEncode(recovered), isNot(contains('private-provider-error')));
    expect(jsonEncode(recovered), isNot(contains(loginSecret)));
    final parsed = await plugin.invoke('parseInput', {
      'values': {'input': source, 'password': 'fixed'}
    });
    expect(parsed['ok'], true);
    expect(fixture.clients.last.parsedLink?.password, 'fixed');
  });

  test('Baidu login recovery occurs before enqueue and can resume parsing',
      () async {
    final fixture = Fixture()
      ..configure = (client) {
        client.detected = const ParsedShareLink(
            platform: NetdiskPlatform.baidu,
            rawUrl: 'https://pan.baidu.com/s/1fixture',
            shareId: '1fixture',
            password: 'abcd');
        client.share = const NetdiskShare(
            platform: NetdiskPlatform.baidu,
            shareId: '1fixture',
            files: [firstFile]);
      };
    final plugin = fixture.controller();
    final sid = await parseSession(plugin);
    final recovery = await plugin.invoke('prepareDownloads', {
      'sessionId': sid,
      'selectedIds': ['file-1']
    });
    expect(recovery['ok'], true);
    expect(pageActions(recovery).any((a) => a['id'] == 'loginBaidu'), true);
    expect(fixture.saved, isEmpty);
    final fields = ((recovery['page'] as Map)['fields'] as List).cast<Map>();
    final recoveryInput =
        fields.singleWhere((f) => f['id'] == 'input')['value'];
    final login = await plugin.invoke('loginBaidu', {
      'values': {'input': recoveryInput}
    });
    expect((login['requestUi'] as Map)['resultAction'], 'parseInput');
    fixture.saved['credential.baidu'] = 'BDUSS=fixture-account';
    final parsed = await plugin.invoke('parseInput', {'input': recoveryInput});
    expect(parsed['ok'], true);
    expect(
        fixture.clients.last.parsedCredential?.cookie, 'BDUSS=fixture-account');
    final prepared = await plugin.invoke('prepareDownloads', {
      'sessionId': sessionId(parsed),
      'selectedIds': ['file-1'],
    });
    expect(prepared['ok'], true);
    expect(jsonEncode(prepared), isNot(contains('BDUSS=')));
  });

  test('recovery form input takes precedence over the original host arguments',
      () async {
    final fixture = Fixture();
    final plugin = fixture.controller();
    const recoveredInput = 'https://pan.quark.cn/s/fixture 提取码: fixed';
    final result = await plugin.invoke('parseInput', {
      'input': source,
      'values': {'input': recoveredInput},
    });
    expect(result['ok'], true);
    expect(fixture.clients.single.detectedInput, recoveredInput);
  });

  test('cancellation before start creates no client', () async {
    final fixture = Fixture();
    final plugin = fixture.controller();
    expect(
        (await plugin.invoke('cancelInput', {'requestId': 'cancel-1'}))['ok'],
        true);
    final canceled = await plugin
        .invoke('parseInput', {'input': source, 'requestId': 'cancel-1'});
    expect(canceled['ok'], false);
    expect(fixture.clients, isEmpty);
  });

  test(
      'cancellation closes a pending client and prevents a successful files page',
      () async {
    final gate = Completer<NetdiskShare>();
    final started = Completer<void>();
    final fixture = Fixture()
      ..configure = (client) {
        client.onParse = () {
          started.complete();
          return gate.future;
        };
      };
    final plugin = fixture.controller();
    final pending =
        plugin.invoke('parseInput', {'input': source, 'requestId': 'cancel-2'});
    await started.future;
    await plugin.invoke('cancelInput', {'requestId': 'cancel-2'});
    expect(fixture.clients.single.closeCount, greaterThanOrEqualTo(1));
    gate.complete(fixtureShare);
    final canceled = await pending;
    expect(canceled['ok'], false);
    expect(canceled.containsKey('page'), false);
  });

  test('cancellation suppresses an in-flight resolved download', () async {
    final started = Completer<void>();
    final gate = Completer<NetdiskDownloadLink>();
    final fixture = Fixture()
      ..configure = (client) {
        client.onResolve = () {
          started.complete();
          return gate.future;
        };
      };
    final plugin = fixture.controller();
    final sid = await parseSession(plugin);
    final prepared = await plugin.invoke('prepareDownloads', {
      'sessionId': sid,
      'selectedIds': ['file-1'],
    });
    final id = ((prepared['downloads'] as List).single as Map)['resourceId'];
    final pending = plugin.invoke('resolveDownload', {
      'resourceId': id,
      'requestId': 'cancel-resolve',
    });
    await started.future;
    await plugin.invoke('cancelInput', {'requestId': 'cancel-resolve'});
    gate.complete(const NetdiskDownloadLink(
        platform: NetdiskPlatform.quark,
        url: 'https://cdn.quark.cn/fixture',
        fileName: 'sample.bin',
        size: 8));
    final result = await pending;
    expect(result['ok'], false);
    expect(result.containsKey('download'), false);
    expect(fixture.clients.last.closeCount, greaterThanOrEqualTo(1));
  });

  test('expired selection sessions do not select files from a newer parse',
      () async {
    final fixture = Fixture();
    final plugin = fixture.controller();
    final old = await parseSession(plugin);
    String latest = '';
    for (var i = 0; i < 8; i++) {
      latest = await parseSession(plugin);
    }
    final expired = await plugin.invoke('prepareDownloads', {
      'sessionId': old,
      'selectedIds': ['file-1'],
    });
    expect(expired['ok'], false);
    expect(fixture.saved, isEmpty);
    final current = await plugin.invoke('prepareDownloads', {
      'sessionId': latest,
      'selectedIds': ['file-1'],
    });
    expect(current['ok'], true);
  });

  test(
      'resolve rejects missing or corrupted resources without disclosing storage contents',
      () async {
    final fixture = Fixture();
    final plugin = fixture.controller();
    for (final id in ['invalid', 'a' * 64]) {
      final result = await plugin.invoke('resolveDownload', {'resourceId': id});
      expect(result['ok'], false);
    }
    fixture.saved['resource.${'b' * 64}'] = 'corrupt-$loginSecret';
    final result =
        await plugin.invoke('resolveDownload', {'resourceId': 'b' * 64});
    expect(result['ok'], false);
    expect(jsonEncode(result), isNot(contains(loginSecret)));
  });

  test('settings and logout expose account status without credentials',
      () async {
    final fixture = Fixture()..saved['credential.quark'] = loginSecret;
    final plugin = fixture.controller();
    final settings = await plugin.invoke('settings', {});
    expect(jsonEncode(settings), isNot(contains(loginSecret)));
    final page = settings['page'] as Map;
    expect(
        (page['sections'] as List).cast<Map>().every((s) => s['id'] is String),
        true);
    expect(
        (page['items'] as List).cast<Map>().every((i) => i['action'] is String),
        true);
    final result = await plugin.invoke('logoutQuark', {});
    expect(result['ok'], true);
    expect(fixture.saved.containsKey('credential.quark'), false);
    expect(jsonEncode(result), isNot(contains(loginSecret)));
  });
  test(
      'Baidu verification is private, requires a selected resource and launches only by explicit action',
      () async {
    final logs = <String>[];
    final previousPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      logs.add(message ?? '');
    };
    addTearDown(() {
      debugPrint = previousPrint;
    });
    final fixture = baiduVerificationFixture(() async {
      throw const NetdiskException(
          NetdiskErrorCode.verificationRequired, 'private-provider-message',
          platform: 'baidu',
          statusCode: 200,
          detail: 'stage=sharedownload errno=9019 private-provider-detail');
    });
    final plugin = fixture.controller();
    final parsed =
        await plugin.invoke('parseInput', {'input': verificationUrl});
    expect(fixture.saved.containsKey('verification.baidu'), false);
    expect(parsed.containsKey('requestUi'), false);
    final sid = sessionId(parsed);
    final empty = await plugin.invoke('prepareDownloads', {
      'sessionId': sid,
      'selectedIds': <String>[],
    });
    expect(empty['ok'], false);
    expect(fixture.saved.containsKey('verification.baidu'), false);
    final invalid =
        await plugin.invoke('resolveDownload', {'resourceId': 'a' * 64});
    expect(invalid['ok'], false);
    expect(fixture.saved.containsKey('verification.baidu'), false);
    final prepared = await plugin.invoke('prepareDownloads', {
      'sessionId': sid,
      'selectedIds': ['file-1'],
    });
    expect(prepared['ok'], true);
    expect(prepared.containsKey('requestUi'), false);
    expect(fixture.saved.containsKey('verification.baidu'), false);
    final id = ((prepared['downloads'] as List).single as Map)['resourceId'];
    final failed = await plugin.invoke('resolveDownload', {'resourceId': id});
    expect(failed['ok'], false);
    expect(failed['code'], 'verificationRequired');
    expect(failed.containsKey('download'), false);
    expect(failed.containsKey('downloads'), false);
    expect(failed.containsKey('navigate'), false);
    expect(failed.containsKey('requestUi'), false);
    expect(jsonEncode(failed), isNot(contains('private-provider')));
    final privateUrl = Uri.parse(fixture.saved['verification.baidu']!);
    expect(privateUrl.scheme, 'https');
    expect(privateUrl.host, 'pan.baidu.com');
    expect(privateUrl.path, '/s/1verifyfixture');
    expect(privateUrl.queryParameters['pwd'], verificationPassword);
    final settings = await plugin.invoke('settings', {});
    final items = ((settings['page'] as Map)['items'] as List).cast<Map>();
    expect(items.singleWhere((item) => item['id'] == 'verify.baidu')['action'],
        'verifyBaidu');
    expect(settings.containsKey('requestUi'), false);
    expect(jsonEncode(settings), isNot(contains(verificationUrl)));
    expect(jsonEncode(settings), isNot(contains(verificationPassword)));
    expect(jsonEncode(settings), isNot(contains('private-baidu-account')));
    final launch = await plugin.invoke(
        'verifyBaidu', {'url': 'https://untrusted.example.test/ignored'});
    expect(launch['ok'], true);
    final request = launch['requestUi'] as Map;
    expect(request['type'], 'launch');
    expect(request['action'], 'com.clipisle.plugin.NETDISK_LOGIN');
    expect(request['resultAction'], 'settings');
    final extras = request['extras'] as Map;
    expect(extras.keys, unorderedEquals(['platform', 'url']));
    expect(extras['platform'], 'baidu');
    expect(extras['url'], privateUrl.toString());
    expect(jsonEncode(launch), isNot(contains('BDUSS=')));
    expect(logs.join(), isNot(contains(verificationUrl)));
    expect(logs.join(), isNot(contains(verificationPassword)));
    expect(logs.join(), isNot(contains('private-provider')));
    expect(logs.join(), isNot(contains('private-baidu-account')));
  });

  test(
      'verifyBaidu without private verification context returns settings and ignores caller URLs',
      () async {
    final fixture = Fixture();
    final plugin = fixture.controller();
    final result = await plugin.invoke('verifyBaidu',
        {'url': verificationUrl, 'password': verificationPassword});
    expect(result['ok'], true);
    expect(result.containsKey('requestUi'), false);
    expect((result['page'] as Map)['id'], 'settings');
    expect(fixture.saved, isEmpty);
    expect(fixture.clients, isEmpty);
  });

  test(
      'successful Baidu resolution after restart clears private verification context and settings entry',
      () async {
    var requiresVerification = true;
    final fixture = baiduVerificationFixture(() async {
      if (requiresVerification) {
        throw const NetdiskException(NetdiskErrorCode.verificationRequired, '',
            platform: 'baidu',
            statusCode: 200,
            detail: 'stage=sharedownload errno=9019');
      }
      return const NetdiskDownloadLink(
          platform: NetdiskPlatform.baidu,
          url: 'https://cdn.example.test/verified',
          fileName: 'sample.bin',
          size: 8);
    });
    final first = fixture.controller();
    final id = await selectedResource(first);
    expect((await first.invoke('resolveDownload', {'resourceId': id}))['ok'],
        false);
    expect(fixture.saved.containsKey('verification.baidu'), true);
    requiresVerification = false;
    final resumed = fixture.controller();
    final resolved =
        await resumed.invoke('resolveDownload', {'resourceId': id});
    expect(resolved['ok'], true);
    expect((resolved['download'] as Map)['resourceId'], id);
    expect(fixture.saved.containsKey('verification.baidu'), false);
    final settings = await resumed.invoke('settings', {});
    expect(
        ((settings['page'] as Map)['items'] as List)
            .cast<Map>()
            .any((item) => item['id'] == 'verify.baidu'),
        false);
    expect((await resumed.invoke('verifyBaidu', {})).containsKey('requestUi'),
        false);
  });

  test(
      'non-verification Baidu errors never create an official-verification context',
      () async {
    for (final code in [
      NetdiskErrorCode.network,
      NetdiskErrorCode.loginRequired,
      NetdiskErrorCode.credentialExpired
    ]) {
      final fixture = baiduVerificationFixture(() async {
        throw NetdiskException(code, 'fixture');
      });
      final plugin = fixture.controller();
      final id = await selectedResource(plugin);
      final result = await plugin.invoke('resolveDownload', {'resourceId': id});
      expect(result['ok'], false);
      expect(fixture.saved.containsKey('verification.baidu'), false);
      expect(result.containsKey('requestUi'), false);
    }
  });

  test('Quark verification errors do not create Baidu verification context',
      () async {
    final fixture = Fixture()
      ..configure = (client) {
        client.onResolve = () async {
          throw const NetdiskException(
              NetdiskErrorCode.verificationRequired, 'fixture');
        };
      };
    final plugin = fixture.controller();
    final sid = await parseSession(plugin);
    final prepared = await plugin.invoke('prepareDownloads', {
      'sessionId': sid,
      'selectedIds': ['file-1']
    });
    final id = ((prepared['downloads'] as List).single as Map)['resourceId'];
    final result = await plugin.invoke('resolveDownload', {'resourceId': id});
    expect(result['ok'], false);
    expect(fixture.saved.containsKey('verification.baidu'), false);
  });
}
