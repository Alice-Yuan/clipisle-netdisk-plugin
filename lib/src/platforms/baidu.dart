import 'dart:convert';

import '../errors.dart';
import '../models.dart';
import 'parser.dart';

/// 百度网盘。
///
/// 接口链（全部实测可达）：
/// 1. `GET  /share/init?surl=`        拿 BAIDUID / STOKEN 等初始 Cookie
/// 2. `POST /share/verify`            提交提取码，换 randsk
/// 3. `GET  /s/{surl}`                抓页面里的 yunData（shareid / uk / sign / timestamp / sekey）
/// 4. `POST /api/sharedownload`       换 dlink
///
/// 关键事实：`/api/sharedownload` 与 `/rest/2.0/xpan/multimedia` 都强制要登录态。
/// 实测无 Cookie 时分别返回 `errno 113 验证码签名错误` 与 `errno -6 Invalid Bduss`，
/// 所以本平台必须提供 Cookie，免登录路径不存在。
class BaiduParser extends NetdiskParser {
  BaiduParser(super.http);

  static final Uri _initBase = Uri.parse('https://pan.baidu.com/share/init');
  static final Uri _verifyBase = Uri.parse('https://pan.baidu.com/share/verify');
  static final Uri _shareDownloadBase =
      Uri.parse('https://pan.baidu.com/api/sharedownload');
  static final Uri _tplConfigBase =
      Uri.parse('https://pan.baidu.com/share/tplconfig');
  static final Uri _listBase = Uri.parse('https://pan.baidu.com/share/list');

  static const String _webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Safari/537.36';

  /// 下载 dlink 时百度要求 UA 必须带 pan.baidu.com 标识。
  static const String downloadUserAgent = 'pan.baidu.com';

  @override
  NetdiskPlatform get platform => NetdiskPlatform.baidu;

  Map<String, String> _headers(NetdiskCredential credential) {
    final h = <String, String>{
      'User-Agent': _webUa,
      'Referer': 'https://pan.baidu.com/',
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
    if (!uri.host.endsWith('baidu.com')) return null;

    // 支持 /s/1xxxx 与 /s/1xxxx?pwd=abcd，也支持 /share/init?surl=xxxx
    String? surl;
    final segments = uri.pathSegments;
    final sIndex = segments.indexOf('s');
    if (sIndex >= 0 && sIndex + 1 < segments.length) {
      surl = segments[sIndex + 1];
    }
    surl ??= queryParam(uri, 'surl');
    if (surl == null || surl.isEmpty) return null;

    final explicit = queryParam(uri, 'pwd');
    return ParsedShareLink(
      platform: platform,
      rawUrl: uri.toString(),
      shareId: surl,
      password: explicit ?? extractPassword(input),
    );
  }

  /// 建立访客 Cookie 会话。返回服务端下发的 Set-Cookie 拼接串。
  Future<String> _bootstrapSession(
    String surl,
    Map<String, String> baseHeaders,
  ) async {
    final url = _initBase.replace(
      queryParameters: {
        'surl': surl,
        'channel': 'chunlei',
        'web': '1',
        'app_id': '250528',
        'clienttype': '0',
      },
    );
    final res = await http.get(url, headers: baseHeaders);
    final cookies = <String>[];
    for (final name in ['BAIDUID', 'BAIDUID_BFESS', 'STOKEN', 'BDCLND']) {
      final v = res.setCookieValue(name);
      if (v != null && v.isNotEmpty) cookies.add('$name=$v');
    }
    return cookies.join('; ');
  }

  /// 提交提取码。成功时服务端通过 Set-Cookie 下发 `BDCLND`（即 randsk）。
  Future<String?> _verifyPassword(
    String surl,
    String password,
    Map<String, String> headers,
  ) async {
    final url = _verifyBase.replace(
      queryParameters: {
        'surl': surl,
        't': DateTime.now().millisecondsSinceEpoch.toString(),
        'channel': 'chunlei',
        'web': '1',
        'app_id': '250528',
        'clienttype': '0',
      },
    );
    final res =
        await http.postForm(url, fields: {'pwd': password}, headers: headers);
    final json = res.jsonMap;
    final errno = json?['errno'];
    if (errno == 0) {
      return res.setCookieValue('BDCLND');
    }
    if (errno == -9 || errno == 105) {
      throw err(
        NetdiskErrorCode.passwordWrong,
        '提取码不正确',
        status: res.status,
        detail: res.bodyText,
      );
    }
    if (errno == -12) {
      throw err(
        NetdiskErrorCode.shareNotFound,
        '链接已失效',
        status: res.status,
        detail: res.bodyText,
      );
    }
    if (errno == 12) {
      throw err(
        NetdiskErrorCode.passwordRequired,
        '需要提取码',
        status: res.status,
        detail: res.bodyText,
      );
    }
    throw err(
      NetdiskErrorCode.badResponse,
      '提取码校验返回异常 errno=$errno',
      status: res.status,
      detail: res.bodyText,
    );
  }

  /// 抓分享页里的 `yunData.setData({...})`。
  /// 拿 shareid / uk / sign / timestamp / sekey。
  Future<Map<String, Object?>> _sharePageData(
    ParsedShareLink link,
    Map<String, String> headers,
  ) async {
    final url = Uri.parse('https://pan.baidu.com/s/${link.shareId}');
    final res = await http.get(url, headers: headers);
    if (res.status != 200) {
      throw err(NetdiskErrorCode.shareNotFound, '分享页打不开',
          status: res.status);
    }
    final html = res.bodyText;
    const marker = 'yunData.setData(';
    final idx = html.indexOf(marker);
    if (idx < 0) {
      // 页面没带数据，通常意味着链接失效或被重定向到验证页。
      if (html.contains('提取码') || html.contains('请输入提取码')) {
        throw err(NetdiskErrorCode.passwordRequired, '该分享需要提取码');
      }
      throw err(
        NetdiskErrorCode.shareNotFound,
        '分享页没有可解析的数据',
        detail: html.length > 200 ? html.substring(0, 200) : html,
      );
    }
    final start = idx + marker.length;
    final end = _matchBrace(html, start);
    if (end < 0) {
      throw err(NetdiskErrorCode.badResponse, 'yunData 结构不完整');
    }
    final text = html.substring(start, end);
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw err(NetdiskErrorCode.badResponse, 'yunData 不是对象');
    }
    return decoded.cast<String, Object?>();
  }

  /// 从 start（指向 `{`）开始做括号配对，返回匹配的 `}` 之后的索引。
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
        continue;
      }
      if (c == '"') {
        inString = true;
        continue;
      }
      if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return i + 1;
      }
    }
    return -1;
  }

  /// 用 tplconfig 补 sign / timestamp（页面数据里偶尔缺）。
  Future<(String?, String?)> _signAndTimestamp(
    Map<String, String> headers,
  ) async {
    final url = _tplConfigBase.replace(
      queryParameters: {
        'fields': 'sign,timestamp',
        'channel': 'chunlei',
        'web': '1',
        'app_id': '250528',
        'clienttype': '0',
        'view_mode': '1',
      },
    );
    final res = await http.get(url, headers: headers);
    final json = res.jsonMap;
    if (json == null || json['errno'] != 0) return (null, null);
    final data = json['data'];
    if (data is! Map) return (null, null);
    return (data['sign']?.toString(), data['timestamp']?.toString());
  }

  /// 列出分享目录。百度用 `uk` + `shareid` + `dir`。
  Future<List<NetdiskFile>> _listDir(
    Map<String, Object?> yunData,
    Map<String, String> headers, {
    String dir = '/',
    int page = 1,
  }) async {
    final shareId = yunData['shareid']?.toString() ?? '';
    final uk =
        yunData['share_uk']?.toString() ?? yunData['uk']?.toString() ?? '';
    final sekey = yunData['sekey']?.toString();
    if (shareId.isEmpty || uk.isEmpty) {
      throw err(NetdiskErrorCode.badResponse, 'yunData 缺少 shareid / uk');
    }
    final params = <String, String>{
      'shareid': shareId,
      'uk': uk,
      'dir': dir,
      'page': '$page',
      'num': '100',
      'order': 'time',
      'desc': '1',
      'showempty': '0',
      'web': '1',
      'app_id': '250528',
      'channel': 'chunlei',
      'clienttype': '0',
    };
    if (sekey != null && sekey.isNotEmpty) params['sekey'] = sekey;
    final url = _listBase.replace(queryParameters: params);
    final res = await http.get(url, headers: headers);
    final json = res.jsonMap;
    final errno = json?['errno'];
    if (errno != 0) {
      throw _mapBaiduErrno(errno, res.status, res.bodyText);
    }
    final list = json?['list'];
    if (list is! List) return const [];

    final out = <NetdiskFile>[];
    for (final item in list) {
      if (item is! Map) continue;
      final fsId = item['fs_id']?.toString() ?? '';
      if (fsId.isEmpty) continue;
      final isDir = item['isdir'] == 1 || item['isdir'] == true;
      out.add(
        NetdiskFile(
          fileId: fsId,
          name: item['server_filename']?.toString() ?? fsId,
          size: _asInt(item['size']),
          isFolder: isDir,
          updatedAt: _asTime(item['server_mtime']),
          parentId: dir,
          extra: {
            'path': item['path']?.toString(),
            'md5': item['md5']?.toString(),
            'fs_id': fsId,
          },
        ),
      );
    }
    return out;
  }

  NetdiskException _mapBaiduErrno(Object? errno, int status, String body) {
    final text = 'errno=$errno';
    switch (errno) {
      case -6:
        return err(
          NetdiskErrorCode.loginRequired,
          '需要登录 Cookie（BDUSS 缺失或无效）',
          status: status,
          detail: text,
        );
      case -9:
      case 105:
        return err(NetdiskErrorCode.passwordWrong, '提取码不正确',
            status: status, detail: text);
      case 12:
        return err(NetdiskErrorCode.passwordRequired, '需要提取码',
            status: status, detail: text);
      case -12:
        return err(NetdiskErrorCode.credentialExpired, '页面已过期，请重新获取',
            status: status, detail: text);
      case 112:
        return err(NetdiskErrorCode.credentialExpired, '页面已过期 / 登录态失效',
            status: status, detail: text);
      case 113:
        return err(
          NetdiskErrorCode.loginRequired,
          '签名或登录态无效（errno 113）',
          status: status,
          detail: text,
        );
      case 9019:
        return err(NetdiskErrorCode.credentialExpired, '访问令牌已过期，需要重新授权',
            status: status, detail: text);
      case -62:
        return err(NetdiskErrorCode.rateLimited, '请求过于频繁',
            status: status, detail: text);
      default:
        if (status == 429) {
          return err(NetdiskErrorCode.rateLimited, '请求过于频繁',
              status: status, detail: text);
        }
        return err(
          NetdiskErrorCode.badResponse,
          '百度接口返回异常 $text',
          status: status,
          detail: body,
        );
    }
  }

  /// 前置：建立会话 + 提交提取码，返回可复用的头。
  Future<Map<String, String>> _prepareSession(
    ParsedShareLink link,
    NetdiskCredential credential,
  ) async {
    if (credential.isEmpty) {
      throw err(
        NetdiskErrorCode.loginRequired,
        '百度网盘必须提供 Cookie（BDUSS + STOKEN）才能解析，'
        '接口在无登录态下返回 113 / -6',
      );
    }
    final base = _headers(credential);
    final session = await _bootstrapSession(link.shareId, base);
    final headers = <String, String>{...base};
    if (session.isNotEmpty) {
      headers['Cookie'] = '${credential.cookie}; $session';
    }
    final password = link.password;
    if (password != null && password.isNotEmpty) {
      final randsk = await _verifyPassword(link.shareId, password, headers);
      if (randsk != null && randsk.isNotEmpty) {
        headers['Cookie'] = '${headers['Cookie']}; BDCLND=$randsk';
      }
    }
    return headers;
  }

  @override
  Future<NetdiskShare> parse(
    ParsedShareLink link, {
    NetdiskCredential credential = const NetdiskCredential.none(),
  }) async {
    final headers = await _prepareSession(link, credential);
    final yunData = await _sharePageData(link, headers);
    final sign = yunData['sign']?.toString();
    final timestamp = yunData['timestamp']?.toString();
    if ((sign == null || sign.isEmpty) ||
        (timestamp == null || timestamp.isEmpty)) {
      final (s2, t2) = await _signAndTimestamp(headers);
      yunData['sign'] = sign ?? s2;
      yunData['timestamp'] = timestamp ?? t2;
    }

    final files = await _listDir(yunData, headers);
    if (files.isEmpty) {
      throw err(NetdiskErrorCode.emptyShare, '分享目录为空');
    }
    return NetdiskShare(
      platform: platform,
      shareId: link.shareId,
      shareUrl: link.rawUrl,
      files: files,
      title: yunData['shareid']?.toString(),
      ownerName: yunData['share_username']?.toString(),
      hasPassword: (link.password ?? '').isNotEmpty,
      raw: yunData,
    );
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
    final headers = await _prepareSession(link, credential);
    final yunData = await _sharePageData(link, headers);
    var sign = yunData['sign']?.toString();
    var timestamp = yunData['timestamp']?.toString();
    if ((sign == null || sign.isEmpty) ||
        (timestamp == null || timestamp.isEmpty)) {
      final (s2, t2) = await _signAndTimestamp(headers);
      sign ??= s2;
      timestamp ??= t2;
    }
    final shareId = yunData['shareid']?.toString() ?? '';
    final uk =
        yunData['share_uk']?.toString() ?? yunData['uk']?.toString() ?? '';
    if (shareId.isEmpty || uk.isEmpty) {
      throw err(NetdiskErrorCode.badResponse, 'yunData 缺少 shareid / uk');
    }

    final url = _shareDownloadBase.replace(
      queryParameters: {
        if (sign != null && sign.isNotEmpty) 'sign': sign,
        if (timestamp != null && timestamp.isNotEmpty) 'timestamp': timestamp,
        'channel': 'chunlei',
        'clienttype': '0',
        'web': '1',
        'app_id': '250528',
      },
    );
    final fields = <String, String>{
      'encrypt': '0',
      'product': 'share',
      'uk': uk,
      'primaryid': shareId,
      'fid_list': jsonEncode([int.tryParse(file.fileId) ?? file.fileId]),
    };
    final sekey = yunData['sekey']?.toString();
    if (sekey != null && sekey.isNotEmpty) {
      fields['extra'] = jsonEncode({'sekey': sekey});
    }

    final res = await http.postForm(url, fields: fields, headers: headers);
    final json = res.jsonMap;
    final errno = json?['errno'];
    if (errno != 0) {
      throw _mapBaiduErrno(errno, res.status, res.bodyText);
    }
    final list = json?['list'];
    if (list is! List || list.isEmpty) {
      throw err(
        NetdiskErrorCode.badResponse,
        '直链接口没有返回数据',
        status: res.status,
        detail: res.bodyText,
      );
    }
    final first = list.first;
    final dlink = first is Map ? first['dlink']?.toString() : null;
    if (dlink == null || dlink.isEmpty) {
      throw err(
        NetdiskErrorCode.badResponse,
        'dlink 为空',
        status: res.status,
        detail: res.bodyText,
      );
    }

    return NetdiskDownloadLink(
      platform: platform,
      url: dlink,
      fileName: file.name,
      size: file.size,
      fileId: file.fileId,
      // dlink 必须带 pan.baidu.com 的 UA，否则 403。
      headers: {
        'User-Agent': downloadUserAgent,
        'Referer': 'https://pan.baidu.com/',
        if (headers['Cookie'] != null) 'Cookie': headers['Cookie']!,
      },
      expiresAt: DateTime.now().add(const Duration(hours: 4)),
    );
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static DateTime? _asTime(Object? v) {
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v * 1000);
    if (v is num) return DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000);
    if (v is String) {
      final sec = int.tryParse(v);
      if (sec != null) return DateTime.fromMillisecondsSinceEpoch(sec * 1000);
      return DateTime.tryParse(v);
    }
    return null;
  }
}
