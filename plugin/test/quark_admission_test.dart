import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:netdisk_direct/netdisk_direct.dart';
import 'package:netdisk_plugin/main.dart';

import 'controller_test.dart'
    show Fixture, source, loginSecret, parseSession, pageActions;

Map<String, dynamic> fieldValues(Map<String, dynamic> response) => {
      for (final field
          in ((response['page'] as Map)['fields'] as List).cast<Map>())
        field['id'] as String: field['value'],
    };
List<String> selectedIds(Map<String, dynamic> response) =>
    ((response['page'] as Map)['items'] as List)
        .cast<Map>()
        .where((item) => item['selected'] == true)
        .map((item) => item['id'] as String)
        .toList();
bool hasResources(Fixture fixture) =>
    fixture.saved.keys.any((key) => key.startsWith('resource.'));
Future<Map<String, dynamic>> prepare(
        NetdiskPlugin plugin, List<String> ids) async =>
    plugin.invoke('prepareDownloads',
        {'sessionId': await parseSession(plugin), 'selectedIds': ids});
const direct = NetdiskDownloadLink(
    platform: NetdiskPlatform.quark,
    url: 'https://cdn.quark.cn/allowed',
    fileName: 'other.bin',
    size: 4);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'only the largest selected file is resolved once; anonymous limit queues and persists nothing',
      () async {
    final fixture = Fixture()
      ..configure = (client) {
        client.share = const NetdiskShare(
            platform: NetdiskPlatform.quark,
            shareId: 'fixture',
            files: [
              NetdiskFile(fileId: 'small', name: 'small.zip', size: 8),
              NetdiskFile(
                  fileId: 'middle',
                  name: 'middle.zip',
                  size: 372 * 1024 * 1024),
              NetdiskFile(
                  fileId: 'unselected-large',
                  name: 'large.zip',
                  size: 416 * 1024 * 1024),
            ]);
        client.onResolve = () async => throw const NetdiskException(
            NetdiskErrorCode.sizeLimitExceeded, 'private-provider-detail');
      };
    final result = await prepare(fixture.controller(), ['small', 'middle']);
    expect(result['ok'], true);
    expect(result.containsKey('downloads'), false);
    expect(result.containsKey('navigate'), false);
    expect(result.containsKey('requestUi'), false);
    expect(
        ((result['page'] as Map)['items'] as List).cast<Map>().single['title'],
        '所选文件超出夸克免登录下载限制，请登录后重试');
    expect(pageActions(result).map((action) => action['id']),
        contains('loginQuark'));
    expect(fieldValues(result)['pendingSelection'], ['small', 'middle']);
    expect(fieldValues(result)['input'], source);
    expect(fieldValues(result)['password'], 'abcd');
    expect(fixture.clients, hasLength(2));
    expect(fixture.clients.last.resolvedFile!.fileId, 'middle');
    expect(fixture.clients.last.resolvedCredentials, hasLength(1));
    expect(fixture.clients.last.resolvedCredentials.single.isEmpty, true);
    expect(fixture.clients.every((client) => client.closeCount == 1), true);
    expect(hasResources(fixture), false);
    expect(jsonEncode(result), isNot(contains('private-provider-detail')));
  });

  test(
      'anonymous small-file admission succeeds and does not persist the preview signed URL',
      () async {
    final fixture = Fixture()
      ..configure = (client) {
        client.onResolve = () async => const NetdiskDownloadLink(
            platform: NetdiskPlatform.quark,
            url:
                'https://cdn.quark.cn/preflight?signature=private-admission-url',
            fileName: 'other.bin',
            size: 4);
      };
    final result = await prepare(fixture.controller(), ['file-2']);
    expect(result['ok'], true);
    expect(
        (result['downloads'] as List).cast<Map>().single['name'], 'other.bin');
    expect(fixture.clients, hasLength(2));
    expect(fixture.clients.last.resolvedFile!.fileId, 'file-2');
    expect(fixture.clients.last.resolvedCredentials.single.isEmpty, true);
    expect(fixture.clients.last.closeCount, 1);
    expect(fixture.saved.keys.where((key) => key.startsWith('resource.')),
        hasLength(1));
    expect(jsonEncode(fixture.saved), isNot(contains('private-admission-url')));
  });

  test(
      'signed-in admission limit remains a current-method restriction without another login prompt',
      () async {
    final fixture = Fixture()..saved['credential.quark'] = loginSecret;
    fixture.configure = (client) {
      client.onResolve = () async => throw const NetdiskException(
          NetdiskErrorCode.sizeLimitExceeded, 'fixture');
    };
    final result = await prepare(fixture.controller(), ['file-1']);
    expect(result.containsKey('downloads'), false);
    expect(result.containsKey('requestUi'), false);
    expect(pageActions(result).any((action) => action['id'] == 'loginQuark'),
        false);
    expect(
        ((result['page'] as Map)['items'] as List).cast<Map>().single['title'],
        '当前下载方式受网盘限制，请使用官方客户端');
    expect(fixture.clients.last.resolvedCredentials.single.cookie, loginSecret);
    expect(hasResources(fixture), false);
  });

  for (final code in [
    NetdiskErrorCode.loginRequired,
    NetdiskErrorCode.credentialExpired
  ]) {
    test(
        'admission $code returns explicit login recovery while retaining the selected subset',
        () async {
      final fixture = Fixture()..saved['credential.quark'] = loginSecret;
      fixture.configure = (client) {
        client.onResolve =
            () async => throw NetdiskException(code, 'private-error');
      };
      final result = await prepare(fixture.controller(), ['file-2']);
      expect(result.containsKey('requestUi'), false);
      expect(result.containsKey('downloads'), false);
      expect(pageActions(result).any((action) => action['id'] == 'loginQuark'),
          true);
      expect(fieldValues(result)['pendingSelection'], ['file-2']);
      expect(hasResources(fixture), false);
    });
  }

  test(
      'explicit login returns to confirmation with pending subset and password rather than downloading all',
      () async {
    final fixture = Fixture()
      ..configure = (client) {
        client.onResolve = () async {
          if (client.resolvedCredential!.isEmpty) {
            throw const NetdiskException(
                NetdiskErrorCode.sizeLimitExceeded, 'guest limit');
          }
          return direct;
        };
      };
    final plugin = fixture.controller();
    final recovered = await prepare(plugin, ['file-2']);
    final values = fieldValues(recovered);
    final login = await plugin.invoke('loginQuark', {'values': values});
    expect((login['requestUi'] as Map)['resultAction'], 'parseInput');
    expect(login.containsKey('downloads'), false);
    fixture.saved['credential.quark'] = loginSecret;
    final confirmed = await plugin.invoke('parseInput', {'values': values});
    expect(selectedIds(confirmed), ['file-2']);
    expect(confirmed.containsKey('downloads'), false);
    expect(fixture.clients, hasLength(3));
    expect(fixture.clients.last.resolvedCredentials, isEmpty);
    expect(fieldValues(confirmed)['password'], 'abcd');
    expect((confirmed['page'] as Map)['selectionControls'], true);
    final action = pageActions(confirmed).single;
    expect(action['requiresSelection'], true);
    expect(action['cancelMethod'], 'cancelInput');
    final prepared = await plugin.invoke('prepareDownloads', {
      'values': fieldValues(confirmed),
      'selectedIds': selectedIds(confirmed)
    });
    expect((prepared['downloads'] as List).cast<Map>().single['name'],
        'other.bin');
    expect(fixture.clients.last.resolvedCredential!.cookie, loginSecret);
  });

  test(
      'empty pendingSelection remains empty; empty prepare creates no preflight request',
      () async {
    final fixture = Fixture();
    final plugin = fixture.controller();
    final parsed = await plugin.invoke(
        'parseInput', {'input': source, 'pendingSelection': <String>[]});
    expect(selectedIds(parsed), isEmpty);
    expect(fieldValues(parsed)['pendingSelection'], isEmpty);
    final result = await plugin.invoke('prepareDownloads', {
      'values': fieldValues(parsed),
      'selectedIds': <String>[],
      'requestId': 'empty'
    });
    expect(result['ok'], false);
    expect(fixture.clients, hasLength(1));
    expect(fixture.clients.single.resolvedCredentials, isEmpty);
    expect(hasResources(fixture), false);
  });

  test(
      'admission errors and repeated parse errors preserve the selection for an explicit retry',
      () async {
    var parseError = false;
    final fixture = Fixture()
      ..configure = (client) {
        client.onParse = () async {
          if (parseError) {
            throw const NetdiskException(
                NetdiskErrorCode.passwordWrong, 'wrong password');
          }
          return client.share;
        };
        client.onResolve = () async => throw const NetdiskException(
            NetdiskErrorCode.network, 'network error');
      };
    final plugin = fixture.controller();
    final failed = await prepare(plugin, ['file-2']);
    expect(failed.containsKey('downloads'), false);
    expect(pageActions(failed).any((action) => action['id'] == 'loginQuark'),
        false);
    parseError = true;
    final second =
        await plugin.invoke('parseInput', {'values': fieldValues(failed)});
    expect(fieldValues(second)['pendingSelection'], ['file-2']);
    expect(fieldValues(second)['password'], 'abcd');
    parseError = false;
    final values = fieldValues(second)..['password'] = 'fixed';
    final confirmed = await plugin.invoke('parseInput', {'values': values});
    expect(selectedIds(confirmed), ['file-2']);
    expect(fixture.clients.last.parsedLink!.password, 'fixed');
    expect(hasResources(fixture), false);
  });

  test(
      'canceling admission closes its client and suppresses late completion before persistence',
      () async {
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
    final pending = plugin.invoke('prepareDownloads', {
      'sessionId': sid,
      'selectedIds': ['file-1'],
      'requestId': 'cancel-admission'
    });
    await started.future;
    await plugin.invoke('cancelInput', {'requestId': 'cancel-admission'});
    gate.complete(direct);
    final result = await pending;
    expect(result['ok'], false);
    expect(result.containsKey('downloads'), false);
    expect(result.containsKey('page'), false);
    expect(hasResources(fixture), false);
    expect(fixture.clients.last.closeCount, greaterThanOrEqualTo(1));
  });

  test('pre-canceled admission creates no additional client', () async {
    final fixture = Fixture();
    final plugin = fixture.controller();
    final sid = await parseSession(plugin);
    await plugin.invoke('cancelInput', {'requestId': 'pre-canceled-admission'});
    final result = await plugin.invoke('prepareDownloads', {
      'sessionId': sid,
      'selectedIds': ['file-1'],
      'requestId': 'pre-canceled-admission'
    });
    expect(result['ok'], false);
    expect(fixture.clients, hasLength(1));
    expect(hasResources(fixture), false);
  });
}
