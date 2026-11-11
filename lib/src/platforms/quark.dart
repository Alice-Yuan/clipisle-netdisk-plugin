import 'dart:convert';

import '../errors.dart';
import '../models.dart';
import 'parser.dart';

/// 夸克网盘。
///
/// 接口链（全部实测可达）：
/// 1. `POST share/sharepage/token` 换 stoken
/// 2. `GET  share/sharepage/detail` 列目录
/// 3. `POST file/download` 换直链
///
/// 免登录只能下小文件；超过上限服务端返回 code 23018，需要带 Cookie 或转存。
class QuarkParser extends NetdiskParser {
  QuarkParser(super.http);

  static final Uri _tokenUrl = Uri.parse(
    'https://drive-pc.quark.cn/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc',
  );
  static final Uri _detailBase =
      Uri.parse('https://drive-pc.quark.cn/1/clouddrive/share/sharepage/detail');
  static final Uri _downloadUrl =
      Uri.parse('https://drive-pc.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc');

  static const String _pcUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 '
      'Safari/537.36 Channel/pckk_other_ch';

  /// 单层最多取多少个文件夹，防止把整棵目录树都请求一遍。
  static const int maxFoldersPerLevel = 12;

  /// 目录最深进几层。
  static const int maxDepth = 4;

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
    if (!uri.host.endsWith('quark.cn')) return null;

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
  Future<String> _stoken(ParsedShareLink link) async {
    final res = await http.postJson(
      _tokenUrl,
      body: {'pwd_id': link.shareId, 'passcode': link.password ?? ''},
      headers: _headers(const NetdiskCredential.none()),
    );
    final json = res.jsonMap;
    final code = json?['code'];
    if (code != 0) {
      throw _mapCode(code, json?['message']?.toString(), status: res.status);
    }
    final data = json?['data'];
    final stoken = data is Map ? data['stoken'] : null;
    if (stoken is! String || stoken.isEmpty) {
      throw err(
        NetdiskErrorCode.badResponse,
        '没有拿到 stoken',
        status: res.status,
        detail: res.bodyText,
      );
    }
    return stoken;
  }

  NetdiskException _mapCode(Object? code, String? message, {int? status}) {
    final msg = message ?? '';
    final text = 'code=$code $msg'.trim();
    switch (code) {
      case 41006:
        return err(NetdiskErrorCode.shareNotFound, '分享不存在或已被取消',
            status: status, detail: text);
      case 41004:
        return err(NetdiskErrorCode.passwordRequired, '该分享需要提取码',
            status: status, detail: text);
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
          '夸克免登录直链有大小上限，当前文件超出；需要配置 Cookie',
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
    final stoken = await _stoken(link);
    final files = await _list(link, stoken, '0', 0);
    // 根目录常常只有一层文件夹，往下钻到真的有文件的位置。
    final resolved = await _drillDown(link, stoken, files, 0);
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

  Future<List<NetdiskFile>> _drillDown(
    ParsedShareLink link,
    String stoken,
    List<NetdiskFile> level,
    int depth,
  ) async {
    final fileList = level.where((f) => f.isFile).toList();
    final folders = level.where((f) => f.isFolder).toList();
    if (fileList.isNotEmpty || folders.isEmpty || depth >= maxDepth) {
      return fileList;
    }

    final limit =
        folders.length < maxFoldersPerLevel ? folders.length : maxFoldersPerLevel;
    for (var i = 0; i < limit; i++) {
      final nested = await _list(link, stoken, folders[i].fileId, depth + 1);
      final found = await _drillDown(link, stoken, nested, depth + 1);
      if (found.isNotEmpty) return found;
    }
    return fileList;
  }

  Future<List<NetdiskFile>> _list(
    ParsedShareLink link,
    String stoken,
    String pdirFid,
    int depth,
  ) async {
    final url = _detailBase.replace(
      queryParameters: {
        'pr': 'ucpro',
        'fr': 'pc',
        'pwd_id': link.shareId,
        'stoken': stoken,
        'pdir_fid': pdirFid.isEmpty ? '0' : pdirFid,
        'force': '0',
        '_page': '1',
        '_size': '50',
        '_fetch_banner': '0',
        '_fetch_share': '1',
        '_fetch_total': '1',
        '_sort': 'file_type:asc,updated_at:desc',
      },
    );
    final res =
        await http.get(url, headers: _headers(const NetdiskCredential.none()));
    final json = res.jsonMap;
    final code = json?['code'];
    if (code != 0) {
      throw _mapCode(code, json?['message']?.toString(), status: res.status);
    }
    final data = json?['data'];
    final list = data is Map ? data['list'] : null;
    if (list is! List) return const [];

    final out = <NetdiskFile>[];
    for (final item in list) {
      if (item is! Map) continue;
      final fid = item['fid']?.toString() ?? '';
      if (fid.isEmpty) continue;
      final dir = item['dir'] == true || item['file_type'] == 0;
      out.add(
        NetdiskFile(
          fileId: fid,
          name: item['file_name']?.toString() ?? fid,
          size: _asInt(item['size']),
          isFolder: dir,
          updatedAt: _asTime(item['updated_at'] ?? item['utime']),
          parentId: pdirFid,
          extra: {
            'share_fid_token': item['share_fid_token']?.toString(),
            'share_id': item['share_id']?.toString(),
            'format_type': item['format_type'],
            if (depth > 0) 'depth': depth,
          },
        ),
      );
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
    final stoken = await _stoken(link);
    final fidToken = file.extra['share_fid_token']?.toString();

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
      headers: _headers(credential),
    );
    final json = res.jsonMap;
    final code = json?['code'];
    if (code != 0) {
      throw _mapCode(code, json?['message']?.toString(), status: res.status);
    }
    final data = json?['data'];
    if (data is! List || data.isEmpty) {
      throw err(
        NetdiskErrorCode.badResponse,
        '直链接口没有返回数据',
        status: res.status,
        detail: res.bodyText,
      );
    }
    final first = data.first;
    final url = first is Map ? first['download_url']?.toString() : null;
    if (url == null || url.isEmpty) {
      throw err(
        NetdiskErrorCode.badResponse,
        '直链为空',
        status: res.status,
        detail: res.bodyText,
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
      },
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
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
