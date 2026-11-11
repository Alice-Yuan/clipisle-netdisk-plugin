/// 统一错误类型。每个错误带一个稳定的 [code]，便于调用方分支处理，
/// 不依赖服务端会变的文案。
class NetdiskException implements Exception {
  const NetdiskException(
    this.code,
    this.message, {
    this.platform,
    this.statusCode,
    this.detail,
  });

  final NetdiskErrorCode code;
  final String message;
  final String? platform;
  final int? statusCode;
  final String? detail;

  @override
  String toString() {
    final parts = <String>['[${code.name}]'];
    if (platform != null) parts.add('($platform)');
    parts.add(message);
    if (statusCode != null) parts.add('HTTP $statusCode');
    if (detail != null && detail!.isNotEmpty) parts.add('| $detail');
    return parts.join(' ');
  }
}

enum NetdiskErrorCode {
  /// 链接格式无法识别
  badLink,

  /// 没有匹配到任何平台的解析器
  unsupportedPlatform,

  /// 分享已取消 / 不存在 / 已过期
  shareNotFound,

  /// 分享需要提取码，但没提供
  passwordRequired,

  /// 提取码错误
  passwordWrong,

  /// 需要登录凭证才能继续（Cookie / refresh_token）
  loginRequired,

  /// 已提供登录凭据，但服务端仍要求官方账号或访问验证
  verificationRequired,

  /// 凭证已失效
  credentialExpired,

  /// 文件超出该平台免登录直链的大小限制
  sizeLimitExceeded,

  /// 分享内容为空
  emptyShare,

  /// 触发了服务端频控
  rateLimited,

  /// 网络层失败（超时、连接中断）
  network,

  /// 服务端返回了未预期的结构
  badResponse,

  /// 其它
  unknown,
}
