import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:netdisk_direct/netdisk_direct.dart';

const runtime = MethodChannel('com.clipisle.netdisk/runtime');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = NetdiskPlugin(
    read: (key) => runtime.invokeMethod<String>('read', {'key': key}),
    write: (key, value) =>
        runtime.invokeMethod<void>('write', {'key': key, 'value': value}),
    compareAndSet: (key, expected, value) async =>
        await runtime.invokeMethod<bool>('compareAndSetCredential',
            {'key': key, 'expected': expected, 'value': value}) ??
        false,
  );
  runtime.setMethodCallHandler((call) async {
    if (call.method != 'invoke') throw MissingPluginException();
    final envelope = Map<String, dynamic>.from(call.arguments as Map);
    final args =
        jsonDecode(envelope['arguments'] as String) as Map<String, dynamic>;
    final method = envelope['method'] == 'invokeAction'
        ? args['action']?.toString() ?? ''
        : envelope['method'] as String;
    return jsonEncode(await controller.invoke(method, args));
  });
  unawaited(runtime.invokeMethod<void>('ready'));
}

typedef PrivateRead = Future<String?> Function(String key);
typedef PrivateWrite = Future<void> Function(String key, String? value);
typedef PrivateCompareAndSet = Future<bool> Function(
    String key, String expected, String value);

class NetdiskPlugin {
  NetdiskPlugin(
      {required this.read,
      required this.write,
      this.compareAndSet,
      NetdiskClient Function()? clientFactory})
      : _customClientFactory = clientFactory;
  final PrivateRead read;
  final PrivateWrite write;
  final PrivateCompareAndSet? compareAndSet;
  final NetdiskClient Function()? _customClientFactory;
  NetdiskClient _createClient() =>
      _customClientFactory?.call() ??
      NetdiskClient(onCredentialUpdated: persistCredentialUpdate);

  // Native CAS is atomic across login Activity, logout and concurrent requests.
  // If no atomic store is supplied, retain operation-local cookies only.
  Future<void> persistCredentialUpdate(NetdiskPlatform platform,
      NetdiskCredential before, NetdiskCredential after) async {
    final expected = before.cookie;
    final value = after.cookie;
    if (expected == null ||
        expected.isEmpty ||
        value == null ||
        value == expected) {
      return;
    }
    await compareAndSet?.call('credential.${platform.id}', expected, value);
  }

  static bool _hasLogin(NetdiskPlatform platform, String? raw) {
    final credential = NetdiskCredential(cookie: raw);
    final name = platform == NetdiskPlatform.baidu ? 'BDUSS' : '__puus';
    return (credential.cookieValue(name) ?? '').isNotEmpty;
  }

  final _active = <String, NetdiskClient>{};
  final _canceled = <String>{};
  final _sessions = <String, ({ParsedShareLink link, NetdiskShare share})>{};
  int _sequence = 0;

  Map<String, dynamic> _values(Map<String, dynamic> args) => {
        ...args,
        if (args['values'] is Map)
          ...Map<String, dynamic>.from(args['values'] as Map),
      };

  Future<Map<String, dynamic>> invoke(
      String action, Map<String, dynamic> args) async {
    final v = _values(args);
    try {
      switch (action) {
        case 'cancelInput':
          final id = v['requestId']?.toString() ?? '';
          _canceled.add(id);
          if (_canceled.length > 128) _canceled.remove(_canceled.first);
          _active.remove(id)?.close();
          return {'ok': true};
        case 'settings':
          return _settings();
        case 'verifyBaidu':
          final url = await read('verification.baidu');
          if (url == null) return _settings();
          return {
            'ok': true,
            'requestUi': {
              'type': 'launch',
              'action': 'com.clipisle.plugin.NETDISK_LOGIN',
              'extras': {'platform': 'baidu', 'url': url},
              'resultAction': 'settings'
            }
          };

        case 'logoutBaidu':
        case 'logoutQuark':
          await write(
              'credential.${action == 'logoutBaidu' ? 'baidu' : 'quark'}',
              null);
          return _settings();
        case 'loginBaidu':
        case 'loginQuark':
          return {
            'ok': true,
            'requestUi': {
              'type': 'launch',
              'action': 'com.clipisle.plugin.NETDISK_LOGIN',
              'extras': {
                'platform': action == 'loginBaidu' ? 'baidu' : 'quark'
              },
              'resultAction': v['input'] is String ? 'parseInput' : 'settings',
            }
          };
        case 'parseInput':
          return await _parse(v);
        case 'prepareDownloads':
          return await _prepare(v);
        case 'resolveDownload':
          return await _resolve(v);
        default:
          return {'ok': false, 'message': '不支持的插件操作'};
      }
    } on NetdiskException catch (e) {
      final errno =
          RegExp(r'errno=(-?[0-9]+)').firstMatch(e.detail ?? '')?.group(1);
      final shape = RegExp(
              r'(?:(?:listType|dlinkType|topDlinkType|dataType)=(?:null|string|array|object|boolean|number|other)|itemCount=[0-9]+|targetMatched=[01])(?: |$)')
          .allMatches(e.detail ?? '')
          .map((m) => m.group(0)!.trim())
          .join(' ');
      debugPrint(
          '[Netdisk] platform=${e.platform} code=${e.code.name} http=${e.statusCode} errno=$errno stage=${RegExp(r'stage=([a-z]+)').firstMatch(e.detail ?? '')?.group(1)} $shape');
      return {'ok': false, 'code': e.code.name, 'message': _error(e.code)};
    } catch (_) {
      return {'ok': false, 'message': '网盘操作失败，请重试'};
    }
  }

  Future<NetdiskCredential> _credential(NetdiskPlatform platform) async =>
      NetdiskCredential(cookie: await read('credential.${platform.id}'));

  Future<T> _withDownloadIdentity<T>(NetdiskPlatform platform,
      Future<T> Function(NetdiskCredential credential) request) async {
    if (platform != NetdiskPlatform.baidu) {
      return request(await _credential(platform));
    }
    try {
      return await request(const NetdiskCredential.none());
    } on NetdiskException catch (error) {
      if (!{
        NetdiskErrorCode.loginRequired,
        NetdiskErrorCode.credentialExpired,
        NetdiskErrorCode.verificationRequired,
        NetdiskErrorCode.sizeLimitExceeded
      }.contains(error.code)) {
        rethrow;
      }
      final saved = await _credential(platform);
      if (!_hasLogin(platform, saved.cookie)) rethrow;
      return request(saved);
    }
  }

  Future<Map<String, dynamic>> _settings() async {
    final rows = <Map<String, dynamic>>[];
    for (final p in [NetdiskPlatform.baidu, NetdiskPlatform.quark]) {
      final logged = _hasLogin(p, await read('credential.${p.id}'));
      final suffix = p == NetdiskPlatform.baidu ? 'Baidu' : 'Quark';
      rows.add({
        'id': 'account.${p.id}',
        'title': p.label,
        'subtitle': logged ? '已登录' : '未登录',
        'icon': 'account',
        'section': 'accounts',
        'action': 'login$suffix'
      });
      if (logged) {
        rows.add({
          'id': 'logout.${p.id}',
          'title': '退出${p.label}',
          'icon': 'logout',
          'section': 'accounts',
          'action': 'logout$suffix'
        });
      }
    }
    if (await read('verification.baidu') != null) {
      rows.add({
        'id': 'verify.baidu',
        'title': '完成访问验证',
        'subtitle': '百度网盘',
        'section': 'accounts',
        'icon': 'security',
        'action': 'verifyBaidu'
      });
    }
    return {
      'ok': true,
      'page': {
        'id': 'settings',
        'title': '网盘下载',
        'sections': [
          {'id': 'accounts', 'title': '账号', 'icon': 'account'}
        ],
        'items': rows,
        'actions': []
      }
    };
  }

  Future<T> _operation<T>(
      Map<String, dynamic> v, Future<T> Function(NetdiskClient) work) async {
    final id = v['requestId']?.toString() ?? 'local-${_sequence++}';
    if (_canceled.contains(id)) {
      throw const NetdiskException(NetdiskErrorCode.network, '已取消');
    }
    final client = _createClient();
    _active[id] = client;
    try {
      final result = await work(client);
      if (_canceled.contains(id)) {
        throw const NetdiskException(NetdiskErrorCode.network, '已取消');
      }
      return result;
    } finally {
      _active.remove(id);
      client.close();
    }
  }

  Future<Map<String, dynamic>> _parse(Map<String, dynamic> v) =>
      _operation(v, (client) async {
        final input = v['input']?.toString() ?? '';
        if (input.length > 16000) {
          throw const NetdiskException(NetdiskErrorCode.badLink, '链接过长');
        }
        var link = client.detect(input);
        if (link.platform == NetdiskPlatform.aliyun) {
          throw const NetdiskException(
              NetdiskErrorCode.unsupportedPlatform, '暂不支持');
        }
        final password = v['password']?.toString().trim();
        if (password?.isNotEmpty == true) {
          link = ParsedShareLink(
              platform: link.platform,
              rawUrl: link.rawUrl,
              shareId: link.shareId,
              password: password,
              subPath: link.subPath);
        }
        NetdiskShare share;
        try {
          share = await _withDownloadIdentity(link.platform,
              (credential) => client.parseLink(link, credential: credential));
        } on NetdiskException catch (e) {
          return _recovery(e, input, link.platform);
        }
        final sessionId =
            '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
        if (_sessions.length >= 8) _sessions.remove(_sessions.keys.first);
        _sessions[sessionId] = (link: link, share: share);
        return {
          'ok': true,
          'page': {
            'id': 'files-$sessionId',
            'title': link.platform.label,
            'stickyActions': true,
            'fields': [
              {'id': 'sessionId', 'type': 'hidden', 'value': sessionId}
            ],
            'items': [
              {
                'type': 'headline',
                'title': share.title ?? '选择文件',
                'titleLiteral': true
              },
              for (final file in share.downloadableFiles)
                {
                  'id': file.fileId,
                  'title': file.extra['relativePath'] ?? file.name,
                  'subtitle': _bytes(file.size),
                  'selected': true,
                }
            ],
            'actions': [
              {'id': 'prepareDownloads', 'label': '开始下载', 'primary': true}
            ],
          }
        };
      });

  Map<String, dynamic> _recovery(
          NetdiskException e, String input, NetdiskPlatform p) =>
      {
        'ok': true,
        'page': {
          'id': 'recover-${p.id}',
          'title': p.label,
          'items': [
            {'type': 'headline', 'title': _error(e.code)}
          ],
          'fields': [
            {'id': 'input', 'type': 'hidden', 'value': input},
            if ({
              NetdiskErrorCode.passwordWrong,
              NetdiskErrorCode.passwordRequired
            }.contains(e.code))
              {'id': 'password', 'type': 'text', 'label': '提取码', 'value': ''},
          ],
          'actions': [
            if ({
              NetdiskErrorCode.loginRequired,
              NetdiskErrorCode.credentialExpired
            }.contains(e.code))
              {
                'id': p == NetdiskPlatform.baidu ? 'loginBaidu' : 'loginQuark',
                'label': '登录',
                'primary': true
              },
            {
              'id': 'parseInput',
              'label': '重试',
              'primary': true,
              'cancelMethod': 'cancelInput'
            },
          ],
        },
      };

  Future<Map<String, dynamic>> _prepare(Map<String, dynamic> v) async {
    final session = _sessions[v['sessionId']];
    if (session == null) return {'ok': false, 'message': '文件列表已过期，请重新解析'};
    final selected = ((v['selectedIds'] ?? v['selected']) as List? ?? [])
        .whereType<String>()
        .toSet();
    final files = session.share.downloadableFiles
        .where((f) => selected.contains(f.fileId))
        .toList();
    if (files.isEmpty) return {'ok': false, 'message': '请至少选择一个文件'};
    if (files.length > 500) return {'ok': false, 'message': '一次最多添加 500 个文件'};
    // Public shares must be attempted without a mandatory account gate.
    // The provider response determines whether sign-in or verification is needed.
    final downloads = <Map<String, dynamic>>[];
    for (final file in files) {
      final id = sha256
          .convert(utf8.encode(
              '${session.link.platform.id}:${session.link.shareId}:${file.fileId}'))
          .toString();
      await write(
          'resource.$id',
          jsonEncode({
            'platform': session.link.platform.id,
            'url': session.link.rawUrl,
            'shareId': session.link.shareId,
            'password': session.link.password,
            'subPath': session.link.subPath,
            'file': {
              'id': file.fileId,
              'name': file.name,
              'size': file.size,
              'parentId': file.parentId,
              'extra': file.extra
            },
          }));
      downloads.add({'resourceId': id, 'name': file.name, 'size': file.size});
    }
    return {'ok': true, 'downloads': downloads, 'navigate': 'downloads'};
  }

  Future<Map<String, dynamic>> _resolve(Map<String, dynamic> v) =>
      _operation(v, (client) async {
        final id = v['resourceId']?.toString() ?? '';
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
          return {'ok': false, 'message': '下载资源无效'};
        }
        final saved = await read('resource.$id');
        if (saved == null) return {'ok': false, 'message': '下载资源已失效，请重新解析'};
        final data = jsonDecode(saved) as Map<String, dynamic>;
        final platform =
            NetdiskPlatform.values.firstWhere((p) => p.id == data['platform']);
        final link = ParsedShareLink(
            platform: platform,
            rawUrl: data['url'] as String,
            shareId: data['shareId'] as String,
            password: data['password'] as String?,
            subPath: data['subPath'] as String?);
        final f = data['file'] as Map<String, dynamic>;
        final file = NetdiskFile(
            fileId: f['id'] as String,
            name: f['name'] as String,
            size: f['size'] as int,
            parentId: f['parentId'] as String?,
            extra: Map<String, Object?>.from(f['extra'] as Map));
        NetdiskDownloadLink direct;
        try {
          direct = await _withDownloadIdentity(
              platform,
              (credential) => client.resolveDownloadFrom(link, file,
                  credential: credential));
          if (platform == NetdiskPlatform.baidu) {
            await write('verification.baidu', null);
          }
        } on NetdiskException catch (e) {
          if (platform == NetdiskPlatform.baidu &&
              e.code == NetdiskErrorCode.verificationRequired) {
            final uri = Uri.parse(link.rawUrl);
            await write(
                'verification.baidu',
                uri.replace(queryParameters: {
                  ...uri.queryParameters,
                  if (link.password != null) 'pwd': link.password!,
                }).toString());
          }
          rethrow;
        }
        return {
          'ok': true,
          'download': {
            'resourceId': id,
            'url': direct.url,
            'name': direct.fileName,
            'size': direct.size,
            'headers': direct.headers
          }
        };
      });

  static String _bytes(int size) {
    if (size < 1000) return '$size B';
    if (size < 1000000) return '${(size / 1000).toStringAsFixed(1)} KB';
    if (size < 1000000000) return '${(size / 1000000).toStringAsFixed(1)} MB';
    return '${(size / 1000000000).toStringAsFixed(2)} GB';
  }

  static String _error(NetdiskErrorCode code) => switch (code) {
        NetdiskErrorCode.loginRequired => '此文件需要登录网盘账号后下载',
        NetdiskErrorCode.verificationRequired => '网盘要求完成官方访问验证，请打开登录页面后重试',
        NetdiskErrorCode.credentialExpired => '登录状态已失效，请重新登录',
        NetdiskErrorCode.passwordRequired => '请输入提取码',
        NetdiskErrorCode.passwordWrong => '提取码不正确',
        NetdiskErrorCode.shareNotFound => '分享已取消或不存在',
        NetdiskErrorCode.emptyShare => '分享中没有可下载的文件',
        NetdiskErrorCode.rateLimited => '网盘请求过于频繁，请稍后重试',
        NetdiskErrorCode.sizeLimitExceeded => '当前下载方式受网盘限制，请使用官方客户端',
        NetdiskErrorCode.network => '网络请求失败或超时，请重试',
        _ => '网盘解析失败，请重试',
      };
}
