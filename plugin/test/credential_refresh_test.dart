import 'package:flutter_test/flutter_test.dart';
import 'package:netdisk_direct/netdisk_direct.dart';
import 'package:netdisk_plugin/main.dart';

void main() {
  test(
      'refreshed credentials are stored only when the original session still matches',
      () async {
    final store = <String, String>{'credential.quark': '__puus=old'};
    final plugin = NetdiskPlugin(
        read: (key) async => store[key],
        write: (key, value) async {
          if (value == null) {
            store.remove(key);
          } else {
            store[key] = value;
          }
        },
        compareAndSet: (key, expected, value) async {
          if (store[key] != expected) return false;
          store[key] = value;
          return true;
        });
    await plugin.persistCredentialUpdate(
        NetdiskPlatform.quark,
        const NetdiskCredential(cookie: '__puus=old'),
        const NetdiskCredential(cookie: '__puus=new'));
    expect(store['credential.quark'], '__puus=new');
    // An older concurrent response cannot roll back a freshly stored session.
    await plugin.persistCredentialUpdate(
        NetdiskPlatform.quark,
        const NetdiskCredential(cookie: '__puus=old'),
        const NetdiskCredential(cookie: '__puus=stale'));
    expect(store['credential.quark'], '__puus=new');
  });

  test(
      'in-flight cookie updates cannot resurrect logout or overwrite a new login',
      () async {
    for (final current in [null, '__puus=another-account']) {
      String? saved = current;
      final plugin = NetdiskPlugin(
          read: (_) async => saved,
          write: (_, value) async {
            saved = value;
          },
          compareAndSet: (_, expected, value) async {
            if (saved != expected) return false;
            saved = value;
            return true;
          });
      await plugin.persistCredentialUpdate(
          NetdiskPlatform.quark,
          const NetdiskCredential(cookie: '__puus=old'),
          const NetdiskCredential(cookie: '__puus=refreshed'));
      expect(saved, current);
    }
  });

  test('without an atomic store cookie refresh stays local to the request',
      () async {
    var writes = 0;
    final plugin = NetdiskPlugin(
        read: (_) async => '__puus=old',
        write: (key, value) async {
          writes++;
        });
    await plugin.persistCredentialUpdate(
        NetdiskPlatform.quark,
        const NetdiskCredential(cookie: '__puus=old'),
        const NetdiskCredential(cookie: '__puus=new'));
    expect(writes, 0);
  });

  test(
      'guest cookies and explicitly cleared login cookies are not shown as signed in',
      () async {
    final plugin = NetdiskPlugin(
        read: (key) async => key == 'credential.baidu'
            ? 'BAIDUID=guest; BDUSS='
            : key == 'credential.quark'
                ? '__pugs=guest; __puus='
                : null,
        write: (key, value) async {});
    final result = await plugin.invoke('settings', {});
    final rows = ((result['page'] as Map)['items'] as List).cast<Map>();
    expect(rows.where((row) => row['subtitle'] == '已登录'), isEmpty);
    expect(rows.where((row) => row['subtitle'] == '未登录'), hasLength(2));
    expect(rows.where((row) => row['icon'] == 'logout'), isEmpty);
  });
}
