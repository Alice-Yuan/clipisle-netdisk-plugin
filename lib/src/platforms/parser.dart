import 'dart:async';

import '../errors.dart';
import '../http/http_client.dart';
import '../models.dart';

/// 从一段分享文本里抽出的链接与提取码。
class ParsedShareLink {
  const ParsedShareLink({
    required this.platform,
    required this.rawUrl,
    required this.shareId,
    this.password,
    this.subPath,
  });

  final NetdiskPlatform platform;
  final String rawUrl;

  /// 平台侧的分享 ID：百度是 surl，夸克是 pwd_id，阿里是 share_id。
  final String shareId;
  final String? password;

  /// 阿里云盘的子目录 file_id（链接里带 /folder/xxx 时）。
  final String? subPath;

  @override
  String toString() => 'ParsedShareLink(${platform.id}, $shareId, pwd=${password ?? "-"})';
}

/// 每个平台解析器实现这一组方法。
abstract class NetdiskParser {
  NetdiskParser(this.http);

  final HttpClient http;

  NetdiskPlatform get platform;

  /// 认出属于本平台的链接，抽出 shareId 与提取码。
  ParsedShareLink? match(String input);

  /// 列出分享根目录下的条目。
  Future<NetdiskShare> parse(ParsedShareLink link, {NetdiskCredential credential = const NetdiskCredential.none()});

  /// 把一个具体文件换成直链。
  Future<NetdiskDownloadLink> resolve(
    ParsedShareLink link,
    NetdiskFile file, {
    NetdiskCredential credential = const NetdiskCredential.none(),
  });

  /// 子类共用的错误构造。
  NetdiskException err(
    NetdiskErrorCode code,
    String message, {
    int? status,
    String? detail,
  }) =>
      NetdiskException(
        code,
        message,
        platform: platform.id,
        statusCode: status,
        detail: detail,
      );

  /// 递归列出目录，默认实现只取一层；需要多层的平台覆写。
  Future<List<NetdiskFile>> listAll(
    ParsedShareLink link,
    List<NetdiskFile> level, {
    NetdiskCredential credential = const NetdiskCredential.none(),
    int depth = 0,
  }) async =>
      level;
}

/// 主流程用的提取码解析：兼容中英文分享文案里的常见写法。
final _pwdPatterns = <RegExp>[
  RegExp(r'(?:提取码|提取碼|密码|密碼|访问码|訪問碼)\s*[:：=]?\s*([0-9a-zA-Z]{4,8})'),
  RegExp(r'(?:pwd|passcode|password|code)\s*[=:]\s*([0-9a-zA-Z]{4,8})', caseSensitive: false),
];

/// 从整段文本里找提取码。
String? extractPassword(String text) {
  for (final re in _pwdPatterns) {
    final m = re.firstMatch(text);
    if (m != null) {
      final v = m.group(1);
      if (v != null && v.isNotEmpty) return v;
    }
  }
  return null;
}

/// 从文本里找出第一个 http(s) 链接。
Uri? extractFirstUrl(String text) {
  final re = RegExp(r'https?://[^\s\u4e00-\u9fff，。、；：）】》」]+');
  final m = re.firstMatch(text);
  if (m == null) return null;
  try {
    return Uri.parse(m.group(0)!);
  } on FormatException {
    return null;
  }
}

/// 取 query 参数，同时兼容 `?pwd=1234` 与 hash 里带参数两种写法。
String? queryParam(Uri uri, String key) {
  final direct = uri.queryParameters[key];
  if (direct != null && direct.isNotEmpty) return direct;
  final frag = uri.fragment;
  if (frag.contains('=')) {
    final q = Uri.splitQueryString(frag.startsWith('?') ? frag.substring(1) : frag);
    final v = q[key];
    if (v != null && v.isNotEmpty) return v;
  }
  return null;
}
