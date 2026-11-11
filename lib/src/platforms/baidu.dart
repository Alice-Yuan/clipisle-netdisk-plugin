import 'dart:convert';

import '../errors.dart';
import '../models.dart';
import 'parser.dart';

/// 百度分享：匿名列目录；下载能力由服务端按登录态、签名及风控决定。
/// 分享 API 属于非官方接口，成功列目录不代表能够取得下载链接。
class BaiduParser extends NetdiskParser {
  BaiduParser(super.http);

  static const downloadUserAgent = 'pan.baidu.com';
  static const _webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static final _base = Uri.parse('https://pan.baidu.com/');

  @override
  NetdiskPlatform get platform => NetdiskPlatform.baidu;

  @override
  ParsedShareLink? match(String input) {
    final uri = extractFirstUrl(input);
    if (uri == null ||
        !{'pan.baidu.com', 'yun.baidu.com'}.contains(uri.host.toLowerCase()) ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    String? id;
    if (uri.pathSegments.length == 2 && uri.pathSegments.first == 's') {
      id = uri.pathSegments[1];
      if (!id.startsWith('1') || id.length < 2) return null;
    } else if (uri.path == '/share/init') {
      id = queryParam(uri, 'surl');
    }
    if (id == null || !RegExp(r'^[\w-]+$').hasMatch(id)) return null;
    return ParsedShareLink(
      platform: platform,
      rawUrl: uri.toString(),
      shareId: id,
      password: queryParam(uri, 'pwd') ?? extractPassword(input),
    );
  }

  // /s/ includes a routing prefix "1"; /share/init?surl= excludes it.
  String _fullSurl(ParsedShareLink link) =>
      Uri.tryParse(link.rawUrl)?.path == '/share/init'
          ? '1${link.shareId}'
          : link.shareId;

  Map<String, String> _headers(NetdiskCredential credential) => {
        'User-Agent': _webUa,
        'Referer': 'https://pan.baidu.com/',
        'Accept': 'application/json, text/plain, */*',
        if ((credential.cookie ?? '').trim().isNotEmpty)
          'Cookie': credential.cookie!.trim(),
      };

  Map<String, String> _wxHeaders(NetdiskCredential credential) {
    final bduss = credential.cookieValue('BDUSS');
    // The netdisk profile uses its own minimal session. Browser state such as
    // PANPSC/STOKEN/BAIDUID must not be mixed into this client profile.
    return {
      'User-Agent': 'netdisk',
      'Accept': '*/*',
      'Cookie':
          '${bduss == null || bduss.isEmpty ? '' : 'BDUSS=$bduss; '}ndut_fmt=',
    };
  }

  Uri _url(String path, Map<String, String> query) =>
      _base.resolve(path).replace(queryParameters: query);

  void _setCookie(Map<String, String> headers, String name, String value) {
    final cookies = <String, String>{};
    for (final item in (headers['Cookie'] ?? '').split(';')) {
      final index = item.indexOf('=');
      if (index > 0) {
        cookies[item.substring(0, index).trim()] =
            item.substring(index + 1).trim();
      }
    }
    cookies[name] = value;
    headers['Cookie'] =
        cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  String? _cookie(Map<String, String> headers, String name) =>
      NetdiskCredential(cookie: headers['Cookie']).cookieValue(name);

  NetdiskException _apiError(Object? value, int status,
      {required String stage,
      bool wx = false,
      String? errtype,
      bool authenticated = false}) {
    final code = _asInt(value, fallback: -99999);
    final detail = 'stage=$stage errno=${code == -99999 ? 'unknown' : code}';
    if (status == 429 || code == -62 || code == 31326) {
      return err(NetdiskErrorCode.rateLimited, '请求过于频繁，请稍后重试',
          status: status, detail: detail);
    }
    if (code == -9 ||
        code == 105 ||
        (code == -130 && (errtype ?? '').contains('mispwd'))) {
      return err(NetdiskErrorCode.passwordWrong, '提取码不正确',
          status: status, detail: detail);
    }
    if (code == 12) {
      return err(NetdiskErrorCode.passwordRequired, '需要提取码',
          status: status, detail: detail);
    }
    if (code == -12 || code == -7 || (wx && code == 2)) {
      return err(NetdiskErrorCode.shareNotFound, '分享不存在或已失效',
          status: status, detail: detail);
    }
    if (code == 9019 || code == -20) {
      // "need verify" is not proof that a captured BDUSS has expired.
      return err(
          authenticated || code == -20
              ? NetdiskErrorCode.verificationRequired
              : NetdiskErrorCode.loginRequired,
          '百度要求完成账号或访问验证，请在官方网页验证或重新登录后重试',
          status: status,
          detail: detail);
    }
    if (code == -6) {
      return err(
          authenticated
              ? NetdiskErrorCode.credentialExpired
              : NetdiskErrorCode.loginRequired,
          authenticated
              ? '登录凭证或访问令牌已失效，请更新 Cookie'
              : '此操作需要有效的百度登录 Cookie（BDUSS）',
          status: status,
          detail: detail);
    }
    if (code == 112) {
      return err(NetdiskErrorCode.credentialExpired, '页面或登录态已过期',
          status: status, detail: detail);
    }
    // 113 also means a bad signature/captcha; it does not prove login is required.
    return err(NetdiskErrorCode.badResponse,
        code == 113 ? '下载签名校验失败，可能需要完成验证码或刷新会话' : '百度接口返回异常',
        status: status, detail: detail);
  }

  Future<(Map<String, Object?>, List<NetdiskFile>)> _wxList(
    ParsedShareLink link,
    Map<String, String> headers, {
    String? dir,
  }) async {
    final files = <NetdiskFile>[];
    final seen = <String>{};
    Map<String, Object?>? info;
    for (var page = 1; page <= 10000; page++) {
      final res = await http.postForm(
        _url('share/wxlist', {
          'channel': 'weixin',
          'version': '2.2.2',
          'clienttype': '25',
          'web': '1',
        }),
        fields: {
          'shorturl': _fullSurl(link),
          'pwd': link.password ?? '',
          'root': dir == null ? '1' : '0',
          if (dir != null) 'dir': dir,
          'page': '$page',
          'num': '100',
          'order': 'time',
        },
        // wxlist rejects some browser JSON Accept headers even for public shares.
        headers: {...headers, 'User-Agent': 'netdisk', 'Accept': '*/*'},
      );
      final json = res.jsonMap;
      if ((link.password ?? '').isEmpty &&
          json?['errno'] == -130 &&
          (json?['errtype']?.toString() ?? '').contains('mispwd')) {
        throw err(NetdiskErrorCode.passwordRequired, '需要提取码',
            status: res.status);
      }
      if (res.status != 200 || json?['errno'] != 0) {
        throw _apiError(json?['errno'], res.status,
            stage: 'wxlist',
            wx: true,
            errtype: json?['errtype']?.toString(),
            authenticated: (_cookie(headers, 'BDUSS') ?? '').isNotEmpty);
      }
      final data = json?['data'];
      if (data is! Map || data['list'] is! List) {
        throw err(NetdiskErrorCode.badResponse, '目录接口缺少 data/list');
      }
      info ??= data.cast<String, Object?>();
      final batch = _files(data['list'] as List, dir ?? '/');
      final fresh = batch.where((f) => seen.add(f.fileId)).toList();
      files.addAll(fresh);
      final more = data['has_more'];
      if (more == false ||
          more == 0 ||
          more == '0' ||
          (more == null && batch.length < 100)) {
        return (info, files);
      }
      if (fresh.isEmpty) {
        throw err(NetdiskErrorCode.badResponse, '目录分页没有进展');
      }
    }
    throw err(NetdiskErrorCode.badResponse, '目录页数超过安全上限');
  }

  List<NetdiskFile> _files(List<dynamic> list, String parent) => [
        for (final item in list)
          if (item is Map && (item['fs_id']?.toString() ?? '').isNotEmpty)
            NetdiskFile(
              fileId: item['fs_id'].toString(),
              name: item['server_filename']?.toString() ??
                  item['fs_id'].toString(),
              size: _asInt(item['size']),
              isFolder:
                  item['isdir'] == true || item['isdir'].toString() == '1',
              updatedAt: _asTime(item['server_mtime']),
              parentId: parent,
              extra: {
                'path': item['path']?.toString(),
                'md5': item['md5']?.toString(),
                'fs_id': item['fs_id'].toString()
              },
            ),
      ];

  Future<Map<String, String>> _prepareWeb(
      ParsedShareLink link, NetdiskCredential credential) async {
    final headers = _headers(credential)
      ..['Referer'] = _base.resolve('s/${_fullSurl(link)}').toString();
    final surl = _fullSurl(link).substring(1);
    final res =
        await http.get(_url('share/init', {'surl': surl}), headers: headers);
    for (final name in ['BAIDUID', 'BAIDUID_BFESS', 'STOKEN', 'BDCLND']) {
      final value = res.setCookieValue(name);
      if (value != null && value.isNotEmpty) _setCookie(headers, name, value);
    }
    if ((link.password ?? '').isNotEmpty) {
      final verify = await http.postForm(
          _url('share/verify', {
            'surl': surl,
            'channel': 'chunlei',
            'web': '1',
            'app_id': '250528',
            'clienttype': '0',
          }),
          fields: {'pwd': link.password!},
          headers: headers);
      final json = verify.jsonMap;
      if (json?['errno'] != 0) {
        throw _apiError(json?['errno'], verify.status,
            stage: 'verify',
            authenticated: (_cookie(headers, 'BDUSS') ?? '').isNotEmpty);
      }
      // Some responses put randsk only in JSON, others also send BDCLND.
      final randsk = verify.setCookieValue('BDCLND') ??
          (json?['randsk'] is String
              ? Uri.encodeComponent(json!['randsk'] as String)
              : null);
      if (randsk != null && randsk.isNotEmpty) {
        _setCookie(headers, 'BDCLND', randsk);
      }
    }
    return headers;
  }

  Future<Map<String, Object?>> _page(
      ParsedShareLink link, Map<String, String> headers) async {
    final res =
        await http.get(_base.resolve('s/${_fullSurl(link)}'), headers: headers);
    if (res.status != 200) {
      throw _apiError(null, res.status, stage: 'sharepage');
    }
    final html = res.bodyText;
    final marker = RegExp(
        r'(?:yunData\s*\.\s*setData\s*\(|locals\s*\.\s*mset\s*\(|(?:window\s*\.\s*)?yunData\s*=)\s*(\{)');
    for (final match in marker.allMatches(html)) {
      final start = match.end - 1;
      final end = _matchBrace(html, start);
      if (end < 0) continue;
      try {
        final decoded = jsonDecode(html.substring(start, end));
        if (decoded is Map &&
            decoded['shareid'] != null &&
            (decoded['share_uk'] != null || decoded['uk'] != null)) {
          return decoded.cast<String, Object?>();
        }
      } on FormatException {
        continue;
      }
    }
    if (html.contains('安全验证') ||
        html.contains('访问验证') ||
        html.contains('验证码')) {
      throw err(NetdiskErrorCode.verificationRequired, '请在百度官方分享页完成访问验证后重试',
          detail: 'stage=sharepage errno=unknown');
    }
    if (html.contains('请输入提取码') || html.contains('输入提取码')) {
      throw err(NetdiskErrorCode.passwordRequired, '该分享需要提取码或验证会话已过期');
    }
    if (html.contains('分享的文件已经被取消') ||
        html.contains('链接不存在') ||
        html.contains('分享已过期')) {
      throw err(NetdiskErrorCode.shareNotFound, '分享已取消或失效');
    }
    throw err(NetdiskErrorCode.badResponse, '分享页没有可识别的数据，可能需要验证或页面已变更',
        detail: 'stage=sharepage errno=unknown');
  }

  static int _matchBrace(String s, int start) {
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var i = start; i < s.length; i++) {
      final c = s[i];
      if (inString) {
        if (escape) {
          escape = false;
        } else if (c == r'\') {
          escape = true;
        } else if (c == '"') {
          inString = false;
        }
      } else if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}' && --depth == 0) {
        return i + 1;
      }
    }
    return -1;
  }

  Future<List<NetdiskFile>> _webList(_BaiduSession session,
      {String? dir}) async {
    final files = <NetdiskFile>[];
    final seen = <String>{};
    for (var page = 1; page <= 10000; page++) {
      final res = await http.get(
          _url('share/list', {
            'shareid': session.data['shareid'].toString(),
            'uk': (session.data['share_uk'] ?? session.data['uk']).toString(),
            'root': dir == null ? '1' : '0',
            if (dir != null) 'dir': dir,
            'page': '$page',
            'num': '100',
            'order': 'time',
            'desc': '1',
            'web': '1',
            'app_id': '250528',
            'channel': 'chunlei',
            'clienttype': '0',
          }),
          headers: session.headers);
      final json = res.jsonMap;
      if (res.status != 200 || json?['errno'] != 0) {
        throw _apiError(json?['errno'], res.status,
            stage: 'sharelist',
            authenticated:
                (_cookie(session.headers, 'BDUSS') ?? '').isNotEmpty);
      }
      final list = json?['list'];
      if (list is! List) throw err(NetdiskErrorCode.badResponse, '目录接口缺少 list');
      final batch = _files(list, dir ?? '/');
      final fresh = batch.where((f) => seen.add(f.fileId)).toList();
      files.addAll(fresh);
      final more = json?['has_more'];
      if (more == false ||
          more == 0 ||
          more == '0' ||
          (more == null && batch.length < 100)) {
        return files;
      }
      if (fresh.isEmpty) throw err(NetdiskErrorCode.badResponse, '目录分页没有进展');
    }
    throw err(NetdiskErrorCode.badResponse, '目录页数超过安全上限');
  }

  Future<(_BaiduSession, List<NetdiskFile>)> _load(
      ParsedShareLink link, NetdiskCredential credential) async {
    final headers = _wxHeaders(credential);
    try {
      final (data, files) = await _wxList(link, headers);
      if (data['shareid'] == null || data['uk'] == null) {
        throw err(NetdiskErrorCode.badResponse, '目录接口缺少 shareid/uk');
      }
      // Keep the WX-derived share key, signature and download in one client
      // profile. Switching back to a browser UA can change verification behavior.
      headers.addAll({'User-Agent': 'netdisk', 'Accept': '*/*'});
      return (_BaiduSession(data, headers, true), files);
    } on NetdiskException catch (e) {
      // A changed/unsupported wxlist response can still use the web protocol.
      // Known share/password/auth/rate errors must keep their original meaning.
      if (e.code != NetdiskErrorCode.badResponse) rethrow;
    }
    final session = await _webSession(link, credential);
    return (session, await _webList(session));
  }

  Future<_BaiduSession> _webSession(
      ParsedShareLink link, NetdiskCredential credential) async {
    final headers = await _prepareWeb(link, credential);
    final data = await _page(link, headers);
    headers['Origin'] = 'https://pan.baidu.com';
    headers['X-Requested-With'] = 'XMLHttpRequest';
    return _BaiduSession(data, headers, false);
  }

  Future<List<NetdiskFile>> _walk(
      ParsedShareLink link, _BaiduSession session, List<NetdiskFile> level,
      {int depth = 0}) async {
    final out = <NetdiskFile>[];
    final visited = <String>{};
    Future<void> visit(
        List<NetdiskFile> items, String relative, int currentDepth) async {
      if (currentDepth > 64) {
        throw err(NetdiskErrorCode.badResponse, '分享目录嵌套过深');
      }
      for (final file in items) {
        final relativePath =
            relative.isEmpty ? file.name : '$relative/${file.name}';
        if (!file.isFolder) {
          out.add(NetdiskFile(
              fileId: file.fileId,
              name: file.name,
              size: file.size,
              updatedAt: file.updatedAt,
              parentId: file.parentId,
              extra: {
                ...file.extra,
                'relativePath': relativePath,
                'depth': currentDepth
              }));
          continue;
        }
        final path = file.extra['path']?.toString();
        if (path == null || !path.startsWith('/')) {
          throw err(NetdiskErrorCode.badResponse, '目录条目缺少绝对 path');
        }
        if (!visited.add(path)) {
          throw err(NetdiskErrorCode.badResponse, '目录包含循环引用');
        }
        final children = session.wx
            ? (await _wxList(link, session.headers, dir: path)).$2
            : await _webList(session, dir: path);
        await visit(children, relativePath, currentDepth + 1);
      }
    }

    await visit(level, '', depth);
    return out;
  }

  @override
  Future<NetdiskShare> parse(
    ParsedShareLink link, {
    NetdiskCredential credential = const NetdiskCredential.none(),
  }) async {
    final (session, root) = await _load(link, credential);
    final files = await _walk(link, session, root);
    if (files.isEmpty) throw err(NetdiskErrorCode.emptyShare, '分享中没有可下载文件');
    return NetdiskShare(
        platform: platform,
        shareId: link.shareId,
        shareUrl: link.rawUrl,
        files: files,
        title: session.data['title']?.toString(),
        ownerName: (session.data['uname'] ?? session.data['share_username'])
            ?.toString(),
        hasPassword: (link.password ?? '').isNotEmpty,
        raw: session.data);
  }

  @override
  Future<List<NetdiskFile>> listAll(
    ParsedShareLink link,
    List<NetdiskFile> level, {
    NetdiskCredential credential = const NetdiskCredential.none(),
    int depth = 0,
  }) async {
    if (!level.any((f) => f.isFolder)) return level;
    final (session, _) = await _load(link, credential);
    return _walk(link, session, level, depth: depth);
  }

  Future<(String, String)> _signature(
      ParsedShareLink link, _BaiduSession session) async {
    var sign = session.data['sign']?.toString() ?? '';
    var timestamp = session.data['timestamp']?.toString() ?? '';
    if (sign.isEmpty || timestamp.isEmpty) {
      final res = await http.get(
          _url('share/tplconfig', {
            'surl': _fullSurl(link),
            'fields': 'sign,timestamp',
            'channel': 'chunlei',
            'web': '1',
            'app_id': '250528',
            'clienttype': '0',
          }),
          headers: session.headers);
      final json = res.jsonMap;
      if (res.status != 200 || json?['errno'] != 0) {
        throw _apiError(json?['errno'], res.status,
            stage: 'tplconfig',
            authenticated:
                (_cookie(session.headers, 'BDUSS') ?? '').isNotEmpty);
      }
      final data = json?['data'];
      if (data is Map) {
        if (sign.isEmpty) sign = data['sign']?.toString() ?? '';
        if (timestamp.isEmpty) timestamp = data['timestamp']?.toString() ?? '';
      }
    }
    if (sign.isEmpty || timestamp.isEmpty) {
      throw err(NetdiskErrorCode.badResponse, '下载签名或时间戳为空',
          detail: 'stage=tplconfig errno=0');
    }
    return (sign, timestamp);
  }

  @override
  Future<NetdiskDownloadLink> resolve(
    ParsedShareLink link,
    NetdiskFile file, {
    NetdiskCredential credential = const NetdiskCredential.none(),
  }) async {
    if (file.isFolder) throw err(NetdiskErrorCode.badLink, '文件夹不能直接取直链');
    if (!RegExp(r'^\d+$').hasMatch(file.fileId)) {
      throw err(NetdiskErrorCode.badLink, '百度文件 ID 必须为数字');
    }
    final (session, _) = await _load(link, credential);
    try {
      return await _resolveSession(link, file, credential, session);
    } on NetdiskException catch (error, stack) {
      final canUseWeb = session.wx &&
          (credential.cookieValue('BDUSS') ?? '').isNotEmpty &&
          error.code == NetdiskErrorCode.verificationRequired &&
          error.detail == 'stage=sharedownload errno=9019';
      if (!canUseWeb) rethrow;
      // One official web-session attempt, never a recursive retry or captcha loop.
      try {
        final webSession = await _webSession(link, credential);
        return await _resolveSession(link, file, credential, webSession);
      } on NetdiskException catch (fallbackError) {
        if (fallbackError.code == NetdiskErrorCode.badResponse &&
            fallbackError.detail == 'stage=sharepage errno=unknown') {
          // An unrecognized fallback page cannot disprove the provider's
          // original explicit verification requirement.
          Error.throwWithStackTrace(error, stack);
        }
        rethrow;
      }
    }
  }

  Future<NetdiskDownloadLink> _resolveSession(
      ParsedShareLink link,
      NetdiskFile file,
      NetdiskCredential credential,
      _BaiduSession session) async {
    final (sign, timestamp) = await _signature(link, session);
    var sekey = (session.data['seckey'] ?? session.data['sekey'])?.toString();
    if (!session.wx || sekey == null || sekey.isEmpty) {
      final encoded = _cookie(session.headers, 'BDCLND');
      if (encoded != null) {
        try {
          sekey = Uri.decodeComponent(encoded);
        } on FormatException {
          throw err(NetdiskErrorCode.badResponse, '分享会话密钥编码无效');
        }
      }
    }
    final res = await http.postForm(
        _url('api/sharedownload', {
          'sign': sign,
          'timestamp': timestamp,
          'channel': 'chunlei',
          'clienttype': session.wx ? '12' : '0',
          'web': '1',
          'app_id': '250528',
          if (!session.wx)
            'bdstoken': credential.baiduBdstoken ??
                (session.data['bdstoken'] ?? session.data['MYBDSTOKEN'])
                    ?.toString() ??
                '',
        }),
        fields: {
          'encrypt': '0',
          'product': 'share',
          if (session.wx) 'type': 'nolimit',
          'uk': (session.data['share_uk'] ?? session.data['uk']).toString(),
          'primaryid': session.data['shareid'].toString(),
          'fid_list': '[${file.fileId}]',
          if (sekey != null && sekey.isNotEmpty)
            'extra': jsonEncode({'sekey': sekey}),
        },
        headers: session.headers);
    final json = res.jsonMap;
    if (res.status != 200 || json?['errno'] != 0) {
      throw _apiError(json?['errno'], res.status,
          stage: session.wx ? 'sharedownload' : 'websharedownload',
          authenticated: (_cookie(session.headers, 'BDUSS') ?? '').isNotEmpty);
    }
    final list = json?['list'];
    final stage = session.wx ? 'sharedownload' : 'websharedownload';
    if (!session.wx && list is String) {
      // The web API can return errno=0 with a string list instead of file
      // links when direct sharing download is restricted for this file.
      throw err(
          NetdiskErrorCode.sizeLimitExceeded, '百度网页版接口不允许直接下载此文件，请使用官方客户端下载',
          status: res.status,
          detail: 'stage=$stage errno=0 ${_downloadShape(json!, null)}');
    }
    Map<Object?, Object?>? selected;
    if (list is List) {
      for (final item in list) {
        if (item is Map &&
            (item['fs_id']?.toString() == file.fileId ||
                (list.length == 1 && item['fs_id'] == null))) {
          selected = item.cast<Object?, Object?>();
          break;
        }
      }
    }
    final candidate = selected?['dlink'];
    final dlink = candidate is String ? candidate : null;
    final uri = dlink == null ? null : Uri.tryParse(dlink);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw err(NetdiskErrorCode.badResponse, '下载接口未返回有效的目标文件链接',
          status: res.status,
          detail: 'stage=$stage errno=0 ${_downloadShape(json!, selected)}');
    }
    return NetdiskDownloadLink(
      platform: platform, url: uri.toString(),
      fileName: file.name, size: file.size, fileId: file.fileId,
      headers: {
        'User-Agent': downloadUserAgent,
        'Referer': 'https://pan.baidu.com/'
      },
      // The server does not promise an expiry; do not invent a four-hour TTL.
    );
  }

  static String _valueType(Object? value) => switch (value) {
        null => 'null',
        List() => 'array',
        Map() => 'object',
        String() => 'string',
        bool() => 'boolean',
        num() => 'number',
        _ => 'other',
      };

  // Only allowlisted schema names and value types are safe diagnostics.
  // Never include URLs, IDs, filenames, cookies, signatures or response values.
  static String _downloadShape(
      Map<String, Object?> response, Map<Object?, Object?>? selected) {
    const responseFields = {
      'errno',
      'list',
      'dlink',
      'data',
      'errmsg',
      'request_id',
      'error_code',
      'error_msg',
      'vcode',
      'vcode_str',
      'captcha',
      'need_verify',
    };
    const itemFields = {
      'fs_id',
      'dlink',
      'errno',
      'isdir',
      'server_filename',
      'filename',
      'path',
      'size',
      'md5',
      'category',
    };
    final responseKeys = response.keys.where(responseFields.contains).toList()
      ..sort();
    final list = response['list'];
    final first = list is List && list.isNotEmpty ? list.first : null;
    final firstKeys = first is Map
        ? first.keys.whereType<String>().where(itemFields.contains).toList()
        : <String>[];
    firstKeys.sort();
    return 'responseKeys=${responseKeys.isEmpty ? '-' : responseKeys.join(',')} '
        'unknownKeyCount=${response.length - responseKeys.length} '
        'listType=${_valueType(list)} itemCount=${list is List ? list.length : 0} '
        'firstType=${_valueType(first)} itemKeys=${firstKeys.isEmpty ? '-' : firstKeys.join(',')} '
        'targetMatched=${selected == null ? 0 : 1} dlinkType=${_valueType(selected?['dlink'])} '
        'topDlinkType=${_valueType(response['dlink'])} dataType=${_valueType(response['data'])}';
  }

  static int _asInt(Object? value, {int fallback = 0}) => value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '') ?? fallback;
  static DateTime? _asTime(Object? value) {
    final seconds = int.tryParse(value?.toString() ?? '');
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }
}

class _BaiduSession {
  _BaiduSession(this.data, this.headers, this.wx);
  final Map<String, Object?> data;
  final Map<String, String> headers;
  final bool wx;
}
