/// 三个平台的身份标识。
enum NetdiskPlatform {
  baidu('百度网盘', 'baidu', 'pan.baidu.com'),
  quark('夸克网盘', 'quark', 'pan.quark.cn'),
  aliyun('阿里云盘', 'aliyun', 'www.alipan.com');

  const NetdiskPlatform(this.label, this.id, this.homeHost);

  final String label;
  final String id;
  final String homeHost;
}

/// 账号凭证。三者都允许为空，此时走免登录路径（能力受限，见各平台注释）。
class NetdiskCredential {
  const NetdiskCredential({
    this.cookie,
    this.refreshToken,
    this.accessToken,
    this.baiduBdstoken,
  });

  const NetdiskCredential.none()
      : cookie = null,
        refreshToken = null,
        accessToken = null,
        baiduBdstoken = null;

  /// 通用 Cookie 串。百度需要 `BDUSS` + `STOKEN`，夸克需要 `__pus`/`__puus`/`ctoken`。
  final String? cookie;

  /// 阿里云盘 refresh_token（oauth）。
  final String? refreshToken;

  /// 阿里云盘 access_token（可由 refresh_token 换取，也允许直接给）。
  final String? accessToken;

  /// 百度网盘的 bdstoken，部分接口必需。
  final String? baiduBdstoken;

  bool get isEmpty =>
      (cookie == null || cookie!.isEmpty) &&
      (refreshToken == null || refreshToken!.isEmpty) &&
      (accessToken == null || accessToken!.isEmpty);

  /// 从 `a=1; b=2` 形式的 Cookie 串里取一个值。
  String? cookieValue(String key) {
    final raw = cookie;
    if (raw == null || raw.isEmpty) return null;
    for (final part in raw.split(';')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      if (part.substring(0, idx).trim() == key) {
        return part.substring(idx + 1).trim();
      }
    }
    return null;
  }

  NetdiskCredential withCookie(String value) => NetdiskCredential(
        cookie: value,
        refreshToken: refreshToken,
        accessToken: accessToken,
        baiduBdstoken: baiduBdstoken,
      );

  NetdiskCredential withTokens({
    String? refresh,
    String? access,
    String? bdstoken,
  }) =>
      NetdiskCredential(
        cookie: cookie,
        refreshToken: refresh ?? refreshToken,
        accessToken: access ?? accessToken,
        baiduBdstoken: bdstoken ?? baiduBdstoken,
      );
}

/// 解析出来的一个文件条目。
class NetdiskFile {
  const NetdiskFile({
    required this.fileId,
    required this.name,
    required this.size,
    this.isFolder = false,
    this.updatedAt,
    this.parentId,
    this.extra = const {},
  });

  final String fileId;
  final String name;
  final int size;
  final bool isFolder;
  final DateTime? updatedAt;
  final String? parentId;

  /// 平台特有字段原样保留：`fs_id`、`share_fid_token`、`md5` 等。
  final Map<String, Object?> extra;

  bool get isFile => !isFolder;

  @override
  String toString() => 'NetdiskFile($name, $size)';
}

/// 一次分享解析的完整结果。
class NetdiskShare {
  const NetdiskShare({
    required this.platform,
    required this.shareId,
    required this.files,
    this.shareUrl,
    this.title,
    this.ownerName,
    this.hasPassword = false,
    this.raw = const {},
  });

  final NetdiskPlatform platform;
  final String shareId;
  final List<NetdiskFile> files;
  final String? shareUrl;
  final String? title;
  final String? ownerName;
  final bool hasPassword;

  /// 平台原始响应，调试与排错用。
  final Map<String, Object?> raw;

  int get totalSize => files.fold(0, (sum, f) => sum + f.size);

  List<NetdiskFile> get downloadableFiles =>
      files.where((f) => f.isFile).toList();
}

/// 一个可以直接交给下载器的直链。
class NetdiskDownloadLink {
  const NetdiskDownloadLink({
    required this.platform,
    required this.url,
    required this.fileName,
    required this.size,
    this.headers = const {},
    this.expiresAt,
    this.fileId,
  });

  final NetdiskPlatform platform;
  final String url;
  final String fileName;
  final int size;

  /// 下载该直链时必须携带的请求头（Referer / User-Agent / Cookie 等）。
  final Map<String, String> headers;
  final DateTime? expiresAt;
  final String? fileId;

  bool get isExpired {
    final at = expiresAt;
    return at != null && DateTime.now().isAfter(at);
  }

  /// 剩余有效期。直链过期后必须重新解析。
  Duration? get remaining {
    final at = expiresAt;
    if (at == null) return null;
    final left = at.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  @override
  String toString() =>
      'NetdiskDownloadLink($fileName, $size, ${url.split('?').first})';
}
