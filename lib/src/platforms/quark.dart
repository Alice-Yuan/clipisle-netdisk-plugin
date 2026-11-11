import 'dart:convert';

import '../errors.dart';
import '../http/http_client.dart';
import '../models.dart';
import 'parser.dart';

/// 夸克网盘。
///
/// 分享元数据与下载接口：
/// 1. `POST share/sharepage/token` 换 stoken
/// 2. `GET  share/sharepage/detail` 列目录
/// 3. `POST file/download` 换直链
///
/// 匿名响应下发的会话 Cookie 也必须用于下载；登录 Cookie 不保证解除平台限制。
class QuarkParser extends NetdiskParser {
  QuarkParser(super.http);

  final _contexts =
      Expando<({String shareId, String token, _QuarkSession session})>();

  static final Uri _tokenUrl = Uri.parse(
    'https://drive-pc.quark.cn/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc',
  );
  static final Uri _detailBase = Uri.parse(
      'https://drive-pc.quark.cn/1/clouddrive/share/sharepage/detail');
  static final Uri _downloadUrl = Uri.parse(
      'https://drive-pc.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc');

  static const String _pcUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 '
      'Safari/537.36 Channel/pckk_other_ch';

  @override
  NetdiskPlatform get platform => NetdiskPlatform.quark;

  Map<String, String> _headers(NetdiskCredential credential) {
    final h = <String, String>{
      'User-Agent': _pcUa,
      'Referer': 'https://pan.quark.cn/',
      'Origin': 'https://pan.quark.cn',
      'Accept': 'application/json, text/plain, */*',
    };
    final cookie = credential.cookie;
    if (cookie != null && cookie.isNotEmpty) h['Cookie'] = cookie;
    return h;
  }

  @override
  ParsedShareLink? match(String input) {
    final uri = extractFirstUrl(input);
    if (uri == null) return null;
    if (uri.host != 'quark.cn' && !uri.host.endsWith('.quark.cn')) {
      return null;
    }

    // https://pan.quark.cn/s/{pwd_id}
    final segments = uri.pathSegments;
    if (segments.length < 2 || segments.first != 's') return null;
    final pwdId = segments[1];
    if (pwdId.isEmpty) return null;

    final explicit = queryParam(uri, 'pwd') ?? queryParam(uri, 'passcode');
    return ParsedShareLink(
      platform: platform,
      rawUrl: uri.toString(),
      shareId: pwdId,
      password: explicit ?? extractPassword(input),
    );
  }

  /// 换 stoken。这一步同时承担「分享是否存在 / 提取码是否正确」的判定。
  Future<String> _stoken(ParsedShareLink link, _QuarkSession session) async {
    final res = await http.postJson(
      _tokenUrl,
      body: {'pwd_id': link.shareId, 'passcode': link.password ?? ''},
      headers: _headers(session.credential),
    );
    session.absorb(res);
    final json = res.jsonMap;
    final code = json?['code'];
    if (code?.toString() != '0' || res.status < 200 || res.status >= 300) {
      throw _mapCode(code, json?['message']?.toString(), status: res.status);
    }
    final data = json?['data'];
    final stoken = data is Map ? data['stoken'] : null;
    if (stoken is! String || stoken.isEmpty) {
      throw err(
        NetdiskErrorCode.badResponse,
        '没有拿到 stoken',
        status: res.status,
        detail: 'unexpected response structure',
      );
    }
    return stoken;
  }

  NetdiskException _mapCode(Object? code, String? message, {int? status}) {
    final msg = message ?? '';
    code = int.tryParse(code?.toString() ?? '') ?? code;
    final text = 'code=$code $msg'.trim();
    switch (code) {
      case 41006:
        return err(NetdiskErrorCode.shareNotFound, '分享不存在或已被取消',
            status: status, detail: text);
      case 41008:
      case 41004:
        return err(NetdiskErrorCode.passwordRequired, '该分享需要提取码',
            status: status, detail: text);
      case 41007:
      case 41001:
      case 41002:
        return err(NetdiskErrorCode.passwordWrong, '提取码不正确',
            status: status, detail: text);
      case 31001:
        return err(NetdiskErrorCode.credentialExpired, 'Cookie 已失效',
            status: status, detail: text);
      case 23018:
        return err(
          NetdiskErrorCode.sizeLimitExceeded,
          '当前文件受夸克下载大小限制；登录 Cookie 也可能无法解除限制',
          status: status,
          detail: text,
        );
      default:
        if (status == 401 || status == 403) {
          return err(NetdiskErrorCode.loginRequired, '需要登录凭证',
              status: status, detail: text);
        }
        if (status == 429) {
          return err(NetdiskErrorCode.rateLimited, '请求过于频繁',
              status: status, detail: text);
        }
        return err(
          NetdiskErrorCode.badResponse,
          msg.isEmpty ? '夸克接口返回异常' : msg,
          status: status,
          detail: text,
        );
    }
  }

  @override
  Future<NetdiskShare> parse(
    ParsedShareLink link, {
    NetdiskCredential credential = const NetdiskCredential.none(),
  }) async {
    final session = _QuarkSession(credential);
    final stoken = await _stoken(link, session);
    final resolved = <NetdiskFile>[];
    final pending = <({String id, String path, int depth})>[
      (id: '0', path: '', depth: 0),
    ];
    final visited = <String>{'0'};
    final seenFiles = <String>{};
    for (var i = 0; i < pending.length; i++) {
      final folder = pending[i];
      final children = await _list(
        link,
        stoken,
        folder.id,
        folder.depth,
        folder.path,
        session,
      );
      for (final child in children) {
        if (child.isFolder) {
          if (visited.add(child.fileId)) {
            pending.add((
              id: child.fileId,
              path: child.extra['relativePath'] as String,
              depth: folder.depth + 1,
            ));
          }
        } else if (seenFiles.add(child.fileId)) {
          resolved.add(child);
          _contexts[child] =
              (shareId: link.shareId, token: stoken, session: session);
        }
      }
    }
    if (resolved.isEmpty) {
      throw err(NetdiskErrorCode.emptyShare, '分享目录为空');
    }
    return NetdiskShare(
      platform: platform,
      shareId: link.shareId,
      shareUrl: link.rawUrl,
      files: resolved,
      hasPassword: (link.password ?? '').isNotEmpty,
      raw: {'stoken': stoken},
    );
  }

  Future<List<NetdiskFile>> _list(
    ParsedShareLink link,
    String stoken,
    String pdirFid,
    int depth,
    String parentPath,
    _QuarkSession session,
  ) async {
    final out = <NetdiskFile>[];
    final seen = <String>{};
    for (var page = 1;; page++) {
      final url = _detailBase.replace(
        queryParameters: {
          'pr': 'ucpro',
          'fr': 'pc',
          'pwd_id': link.shareId,
          'stoken': stoken,
          'pdir_fid': pdirFid.isEmpty ? '0' : pdirFid,
          'force': '0',
          '_page': '$page',
          '_size': '50',
          '_fetch_banner': '0',
          '_fetch_share': '1',
          '_fetch_total': '1',
          '_sort': 'file_type:asc,file_name:asc',
        },
      );
      final res = await http.get(url, headers: _headers(session.credential));
      session.absorb(res);
      final json = res.jsonMap;
      final code = json?['code'];
      if (code?.toString() != '0' || res.status < 200 || res.status >= 300) {
        throw _mapCode(code, json?['message']?.toString(), status: res.status);
      }
      final data = json?['data'];
      final list = data is Map ? data['list'] : null;
      if (list is! List) {
        throw err(NetdiskErrorCode.badResponse, '目录列表缺少 list',
            status: res.status);
      }
      final before = seen.length;
      for (final item in list) {
        if (item is! Map) continue;
        final fid = item['fid']?.toString() ?? '';
        if (fid.isEmpty || !seen.add(fid)) continue;
        final dir =
            item['dir'] == true || item['dir'] == 1 || item['file_type'] == 0;
        final name = item['file_name']?.toString() ?? fid;
        out.add(
          NetdiskFile(
            fileId: fid,
            name: name,
            size: _asInt(item['size']),
            isFolder: dir,
            updatedAt: _asTime(item['updated_at'] ?? item['utime']),
            parentId: pdirFid,
            extra: {
              'pdir_fid': pdirFid,
              'relativePath': parentPath.isEmpty ? name : '$parentPath/$name',
              'share_fid_token': item['share_fid_token']?.toString(),
              'share_id': item['share_id']?.toString(),
              'format_type': item['format_type'],
              if (depth > 0) 'depth': depth,
            },
          ),
        );
      }
      final metadata = json?['metadata'];
      final total =
          metadata is Map ? int.tryParse('${metadata['_total']}') : null;
      if ((total != null && seen.length >= total) ||
          (total == null && list.length < 50)) {
        break;
      }
      if (seen.length == before) {
        throw err(NetdiskErrorCode.badResponse, '目录分页没有前进');
      }
    }
    return out;
  }

  @override
  Future<NetdiskDownloadLink> resolve(
    ParsedShareLink link,
    NetdiskFile file, {
    NetdiskCredential credential = const NetdiskCredential.none(),
  }) async {
    if (file.isFolder) {
      throw err(NetdiskErrorCode.badLink, '文件夹不能直接取直链');
    }
    final context = _contexts[file];
    final reusable = context != null &&
        context.shareId == link.shareId &&
        context.session.initialCookie == (credential.cookie ?? '');
    final session =
        reusable ? context.session.fork() : _QuarkSession(credential);
    final stoken = reusable ? context.token : await _stoken(link, session);
    var fidToken = file.extra['share_fid_token']?.toString();
    if (!reusable) {
      // File tokens can be bound to the guest session that listed the file.
      final siblings = await _list(
          link,
          stoken,
          file.parentId ?? file.extra['pdir_fid']?.toString() ?? '0',
          0,
          '',
          session);
      final matches = siblings.where((item) => item.fileId == file.fileId);
      if (matches.isEmpty) {
        throw err(NetdiskErrorCode.badLink, '分享目录中找不到该文件，请重新解析');
      }
      fidToken = matches.first.extra['share_fid_token']?.toString();
    }

    final body = <String, Object?>{
      'fids': [file.fileId],
      'pwd_id': link.shareId,
      'stoken': stoken,
    };
    if (fidToken != null && fidToken.isNotEmpty) {
      body['fids_token'] = [fidToken];
    }

    final res = await http.postJson(
      _downloadUrl,
      body: body,
      headers: _headers(session.credential),
    );
    session.absorb(res);
    final json = res.jsonMap;
    final code = json?['code'];
    if (code?.toString() != '0' || res.status < 200 || res.status >= 300) {
      throw _mapCode(code, json?['message']?.toString(), status: res.status);
    }
    final data = json?['data'];
    if (data is! List || data.isEmpty) {
      throw err(
        NetdiskErrorCode.badResponse,
        '直链接口没有返回数据',
        status: res.status,
        detail: 'unexpected response structure',
      );
    }
    final first = data.first;
    final url = first is Map ? first['download_url']?.toString() : null;
    if (url == null || url.isEmpty) {
      throw err(
        NetdiskErrorCode.badResponse,
        '直链为空',
        status: res.status,
        detail: 'unexpected response structure',
      );
    }

    return NetdiskDownloadLink(
      platform: platform,
      url: url,
      fileName: file.name,
      size: file.size,
      fileId: file.fileId,
      headers: {
        'User-Agent': _pcUa,
        'Referer': 'https://pan.quark.cn/',
        if (_quarkHost(Uri.tryParse(url)?.host) && session.cookie.isNotEmpty)
          'Cookie': session.cookie,
      },
    );
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static DateTime? _asTime(Object? v) {
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    if (v is num) return DateTime.fromMillisecondsSinceEpoch(v.toInt());
    if (v is String) {
      final ms = int.tryParse(v);
      if (ms != null) return DateTime.fromMillisecondsSinceEpoch(ms);
      return DateTime.tryParse(v);
    }
    return null;
  }
}

/// 让 jsonDecode 的异常也走统一错误类型。
Never badJson(Object e, Uri url) => throw NetdiskException(
      NetdiskErrorCode.badResponse,
      '响应不是合法 JSON：$e',
      detail: url.toString(),
    );

/// 供测试注入用。
String decodeUtf8(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

// Sessions are local to an operation, so concurrent users never share credentials.
class _QuarkSession {
  _QuarkSession(NetdiskCredential credential)
      : initialCookie = credential.cookie ?? '' {
    for (final part in (credential.cookie ?? '').split(';')) {
      final index = part.indexOf('=');
      if (index > 0) {
        _cookies[part.substring(0, index).trim()] =
            part.substring(index + 1).trim();
      }
    }
  }

  final String initialCookie;
  final Map<String, String> _cookies = {};

  _QuarkSession fork() {
    final copy = _QuarkSession(NetdiskCredential(cookie: initialCookie));
    copy._cookies.addAll(_cookies);
    return copy;
  }

  String get cookie =>
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  NetdiskCredential get credential => NetdiskCredential(cookie: cookie);

  void absorb(HttpResult response) {
    // The anonymous API issues these cookies; the signed CDN URL requires them.
    for (final name in ['__pugs', '__sdid', '__pus', '__puus', 'ctoken']) {
      final value = response.setCookieValue(name);
      if (value != null) _cookies[name] = value;
    }
  }
}

bool _quarkHost(String? host) =>
    host == 'quark.cn' || (host?.endsWith('.quark.cn') ?? false);
