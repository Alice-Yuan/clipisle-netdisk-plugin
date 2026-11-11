import 'dart:convert';

import '../errors.dart';
import '../models.dart';
import 'parser.dart';

/// 阿里云盘。
///
/// 列目录使用分享 token；原文件下载还需要阿里云盘账号 access_token。
/// 阿里开放平台 OAuth token 不能替代此处账号 token。
class AliyunParser extends NetdiskParser {
  AliyunParser(super.http);

  static const String apiHost = 'https://api.alipan.com';

  static final Uri _shareTokenUrl =
      Uri.parse('$apiHost/v2/share_link/get_share_token');
  static final Uri _fileListUrl = Uri.parse('$apiHost/adrive/v3/file/list');
  static final Uri _downloadUrlUrl =
      Uri.parse('$apiHost/v2/file/get_share_link_download_url');
  static final Uri _oauthTokenUrl =
      Uri.parse('https://auth.alipan.com/v2/account/token');
  static final Uri _userInfoUrl = Uri.parse('$apiHost/v2/user/get');

  static const String _webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Safari/537.36';

  /// 直链有效期上限（秒）。
  static const int maxExpireSec = 600;

  @override
  NetdiskPlatform get platform => NetdiskPlatform.aliyun;

  Map<String, String> _baseHeaders() => {
        'User-Agent': _webUa,
        'Referer': 'https://www.alipan.com/',
        'Origin': 'https://www.alipan.com',
      };

  @override
  ParsedShareLink? match(String input) {
    final uri = extractFirstUrl(input);
    if (uri == null) return null;
    final host = uri.host;
    if (!['alipan.com', 'aliyundrive.com', 'alywp.net'].any(
      (domain) => host == domain || host.endsWith('.$domain'),
    )) {
      return null;
    }

    // https://www.alipan.com/s/{share_id}  或 /s/{share_id}/folder/{file_id}
    final segments = uri.pathSegments;
    final sIndex = segments.indexOf('s');
    String? shareId;
    String? subPath;
    if (sIndex >= 0 && sIndex + 1 < segments.length) {
      shareId = segments[sIndex + 1];
      if (sIndex + 3 < segments.length && segments[sIndex + 2] == 'folder') {
        subPath = segments[sIndex + 3];
      }
    }
    shareId ??= queryParam(uri, 'share_id');
    if (shareId == null || shareId.isEmpty) return null;

    final explicit = queryParam(uri, 'pwd') ?? queryParam(uri, 'share_pwd');
    return ParsedShareLink(
      platform: platform,
      rawUrl: uri.toString(),
      shareId: shareId,
      password: explicit ?? extractPassword(input),
      subPath: subPath,
    );
  }

  /// 用 refresh_token 换 access_token。阿里云盘的 access_token 只有 2 小时。
  Future<String> _accessToken(NetdiskCredential credential) async {
    final existing = credential.accessToken;
    if (existing != null && existing.isNotEmpty) return existing;
    final refresh = credential.refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw err(NetdiskErrorCode.loginRequired,
          '阿里云盘需要 refresh_token 或 access_token');
    }
    final res = await http.postJson(
      _oauthTokenUrl,
      body: {'grant_type': 'refresh_token', 'refresh_token': refresh},
      headers: _baseHeaders(),
    );
    final json = res.jsonMap;
    if (json?['code'] != null || res.status < 200 || res.status >= 300) {
      throw _mapCode(json?['code']?.toString() ?? '', null, res.status);
    }
    final token = json?['access_token'];
    if (token is! String || token.isEmpty) {
      throw err(
          NetdiskErrorCode.credentialExpired, 'refresh_token 换不到 access_token',
          status: res.status, detail: 'unexpected response structure');
    }
    return token;
  }

  /// 换取用于列出分享内容的 x-share-token。
  Future<({String token, Map<String, Object?>? shareInfo})> _shareToken(
      ParsedShareLink link) async {
    final res = await http.postJson(
      _shareTokenUrl,
      body: {
        'share_id': link.shareId,
        'share_pwd': link.password ?? '',
      },
      headers: _baseHeaders(),
    );
    final json = res.jsonMap;
    if (json == null) {
      if (res.status == 401 || res.status == 403 || res.status == 429) {
        throw _mapCode('', null, res.status);
      }
      throw err(NetdiskErrorCode.badResponse, '分享 token 响应不是 JSON',
          status: res.status, detail: 'unexpected response structure');
    }
    final code = json['code']?.toString() ?? '';
    if ((code.isNotEmpty && code != '200') ||
        res.status < 200 ||
        res.status >= 300) {
      throw _mapCode(code, json['message']?.toString(), res.status);
    }
    final token = json['share_token'];
    if (token is! String || token.isEmpty) {
      throw err(NetdiskErrorCode.badResponse, '没有拿到 share_token',
          status: res.status, detail: 'unexpected response structure');
    }
    return (token: token, shareInfo: json);
  }

  NetdiskException _mapCode(String code, String? message, int status) {
    final text = 'code=$code ${message ?? ''}'.trim();
    switch (code) {
      case 'ShareLink.Cancelled':
      case 'ShareLink.Expired':
      case 'ShareLink.NotFound':
      case 'NotFound.ShareLink':
        return err(NetdiskErrorCode.shareNotFound, '分享不存在或已过期',
            status: status, detail: text);
      case 'AccessTokenInvalid':
      case 'AccessTokenExpired':
      case 'RefreshTokenInvalid':
      case 'InvalidRefreshToken':
      case 'ShareLinkTokenInvalid':
        return err(NetdiskErrorCode.credentialExpired, '账号或分享凭证无效，需要更新凭证后重试',
            status: status, detail: text);
      case 'ShareLink.PasswordRequired':
      case 'Forbidden.ShareLinkPassword':
        return err(NetdiskErrorCode.passwordRequired, '该分享需要提取码',
            status: status, detail: text);
      case 'Forbidden.ShareLinkPasswordError':
        return err(NetdiskErrorCode.passwordWrong, '提取码不正确',
            status: status, detail: text);
      case 'TooManyRequests':
        return err(NetdiskErrorCode.rateLimited, '请求过于频繁',
            status: status, detail: text);
      default:
        if (status == 401 || status == 403) {
          return err(NetdiskErrorCode.loginRequired, '需要登录',
              status: status, detail: text);
        }
        if (status == 429) {
          return err(NetdiskErrorCode.rateLimited, '请求过于频繁',
              status: status, detail: text);
        }
        return err(NetdiskErrorCode.badResponse, '阿里云盘接口返回异常 $text',
            status: status, detail: text);
    }
  }

  @override
  Future<NetdiskShare> parse(
    ParsedShareLink link, {
    NetdiskCredential credential = const NetdiskCredential.none(),
  }) async {
    final (:token, :shareInfo) = await _shareToken(link);
    final parentId = link.subPath ?? 'root';
    final files = <NetdiskFile>[];
    final pending = <({String id, String path})>[(id: parentId, path: '')];
    final visited = <String>{parentId};
    final seenFiles = <String>{};
    for (var i = 0; i < pending.length; i++) {
      final folder = pending[i];
      final children = await _list(link, token, folder.id, folder.path);
      for (final child in children) {
        if (child.isFolder) {
          if (visited.add(child.fileId)) {
            pending.add((
              id: child.fileId,
              path: child.extra['relativePath'] as String
            ));
          }
        } else if (seenFiles.add(child.fileId)) {
          files.add(child);
        }
      }
    }
    if (files.isEmpty) {
      throw err(NetdiskErrorCode.emptyShare, '分享目录为空');
    }
    return NetdiskShare(
      platform: platform,
      shareId: link.shareId,
      shareUrl: link.rawUrl,
      files: files,
      title: shareInfo?['share_name']?.toString(),
      ownerName: shareInfo?['creator_name']?.toString(),
      hasPassword: (link.password ?? '').isNotEmpty,
      raw: {'share_token': token, ...?shareInfo},
    );
  }

  Future<List<NetdiskFile>> _list(
    ParsedShareLink link,
    String shareToken,
    String parentId,
    String parentPath,
  ) async {
    final headers = _baseHeaders()
      ..['x-share-token'] = shareToken
      ..['Content-Type'] = 'application/json';
    final out = <NetdiskFile>[];
    final seen = <String>{};
    final markers = <String>{''};
    var marker = '';
    while (true) {
      final res = await http.postJson(
        _fileListUrl,
        body: {
          'share_id': link.shareId,
          'parent_file_id': parentId,
          'limit': 100,
          'marker': marker,
          'order_by': 'name',
          'order_direction': 'ASC',
          'fields': '*',
          'image_thumbnail_process': 'image/resize,w_160',
          'video_thumbnail_process': 'video/snapshot,t_1000,f_jpg',
        },
        headers: headers,
      );
      final json = res.jsonMap;
      if (json == null) {
        if (res.status == 401 || res.status == 403 || res.status == 429) {
          throw _mapCode('', null, res.status);
        }
        throw err(NetdiskErrorCode.badResponse, '目录列表响应不是 JSON',
            status: res.status, detail: 'unexpected response structure');
      }
      final code = json['code']?.toString() ?? '';
      if ((code.isNotEmpty && code != '200') ||
          res.status < 200 ||
          res.status >= 300) {
        throw _mapCode(code, json['message']?.toString(), res.status);
      }
      final items = json['items'];
      if (items is! List) {
        throw err(NetdiskErrorCode.badResponse, '目录列表缺少 items',
            status: res.status);
      }
      for (final item in items) {
        if (item is! Map) continue;
        final id = item['file_id']?.toString() ?? '';
        if (id.isEmpty || !seen.add(id)) continue;
        final type = item['type']?.toString() ?? 'file';
        final name = item['name']?.toString() ?? id;
        out.add(NetdiskFile(
          fileId: id,
          name: name,
          size: _asInt(item['size']),
          isFolder: type == 'folder',
          updatedAt: _asTime(item['updated_at']),
          parentId: parentId,
          extra: {
            'relativePath': parentPath.isEmpty ? name : '$parentPath/$name',
            'file_extension': item['file_extension']?.toString(),
            'content_hash': item['content_hash']?.toString(),
            'thumbnail': item['thumbnail']?.toString(),
            'category': item['category']?.toString(),
          },
        ));
      }
      final next = json['next_marker'];
      if (next == null || next == '') break;
      if (next is! String || !markers.add(next)) {
        throw err(NetdiskErrorCode.badResponse, '目录分页 marker 没有前进');
      }
      marker = next;
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
    final accessToken = await _accessToken(credential);
    final (:token, shareInfo: _) = await _shareToken(link);
    final headers = _baseHeaders()
      ..['Authorization'] = 'Bearer $accessToken'
      ..['x-share-token'] = token
      ..['Content-Type'] = 'application/json';

    final res = await http.postJson(
      _downloadUrlUrl,
      body: {
        'share_id': link.shareId,
        'file_id': file.fileId,
        'expire_sec': maxExpireSec,
        'image_thumbnail_process': 'image/resize,w_160',
        'video_thumbnail_process': 'video/snapshot,t_1000,f_jpg',
      },
      headers: headers,
    );
    final json = res.jsonMap;
    if (json == null) {
      if (res.status == 401 || res.status == 403 || res.status == 429) {
        throw _mapCode('', null, res.status);
      }
      // 410 是阿里给「share_token / 参数不对」的空响应，没有 JSON body。
      if (res.status == 410) {
        throw err(
            NetdiskErrorCode.credentialExpired, 'share_token 与文件不匹配，请重新解析后再取直链',
            status: res.status);
      }
      throw err(NetdiskErrorCode.badResponse, '直链响应不是 JSON',
          status: res.status, detail: 'unexpected response structure');
    }
    final code = json['code']?.toString() ?? '';
    if ((code.isNotEmpty && code != '200') ||
        res.status < 200 ||
        res.status >= 300) {
      throw _mapCode(code, json['message']?.toString(), res.status);
    }
    final urls = json['urls'];
    String? url =
        json['download_url'] is String ? json['download_url'] as String : null;
    if (url == null &&
        urls is List &&
        urls.isNotEmpty &&
        urls.first is String) {
      url = urls.first as String;
    }
    url ??= json['url']?.toString();
    if (url == null || url.isEmpty) {
      throw err(NetdiskErrorCode.badResponse, '直链为空',
          status: res.status, detail: 'unexpected response structure');
    }

    return NetdiskDownloadLink(
      platform: platform,
      url: url,
      fileName: file.name,
      size: file.size,
      fileId: file.fileId,
      headers: {
        'Referer': 'https://www.alipan.com/',
        'User-Agent': _webUa,
      },
      expiresAt: _asTime(json['expiration']) ??
          DateTime.now().add(const Duration(seconds: maxExpireSec)),
    );
  }

  /// 会员信息（可选能力，用来判断能否下原画）。
  Future<Map<String, Object?>?> userInfo(NetdiskCredential credential) async {
    final token = await _accessToken(credential);
    final res = await http.postJson(
      _userInfoUrl,
      body: const {},
      headers: _baseHeaders()..['Authorization'] = 'Bearer $token',
    );
    final json = res.jsonMap;
    final code = json?['code']?.toString() ?? '';
    if ((code.isNotEmpty && code != '200') ||
        res.status < 200 ||
        res.status >= 300) {
      throw _mapCode(code, null, res.status);
    }
    if (json == null) {
      throw err(NetdiskErrorCode.badResponse, '账号信息响应不是 JSON',
          status: res.status);
    }
    return json;
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static DateTime? _asTime(Object? v) {
    if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
    return null;
  }
}

/// 把 share_token 拼进请求体的辅助（给测试与外部调试用）。
String encodeJsonBody(Map<String, Object?> body) => jsonEncode(body);
