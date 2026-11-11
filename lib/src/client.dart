import 'dart:async';

import 'errors.dart';
import 'http/http_client.dart';
import 'models.dart';
import 'platforms/platforms.dart';

/// 对外主入口。把链接识别、解析、直链三段串起来。
///
/// ```dart
/// final client = NetdiskClient();
/// final share = await client.parse('https://pan.quark.cn/s/xxxx 提取码: 1234');
/// final link = await client.resolveDownload(share, share.files.first);
/// ```
class NetdiskClient {
  factory NetdiskClient({
    HttpClient? http,
    List<NetdiskParser>? parsers,
    CredentialUpdatedCallback? onCredentialUpdated,
  }) {
    final transport = http ?? HttpClient();
    final selected = parsers ?? defaultParsers(transport);
    if (onCredentialUpdated != null) {
      for (final parser in selected.whereType<QuarkParser>()) {
        parser.onCredentialUpdated = onCredentialUpdated;
      }
    }
    return NetdiskClient._(transport, selected);
  }
  NetdiskClient._(this.http, this.parsers);
  final _contexts = Expando<ParsedShareLink>();

  final HttpClient http;
  final List<NetdiskParser> parsers;

  /// 按 host 认出平台，并抽出 shareId / 提取码。
  ParsedShareLink detect(String input) {
    final text = input.trim();
    if (text.isEmpty) {
      throw const NetdiskException(NetdiskErrorCode.badLink, '输入为空');
    }
    for (final parser in parsers) {
      final hit = parser.match(text);
      if (hit != null) return hit;
    }
    final uri = extractFirstUrl(text);
    throw NetdiskException(
      NetdiskErrorCode.unsupportedPlatform,
      '不支持的链接，本库只处理百度网盘 / 夸克网盘 / 阿里云盘',
      detail: uri?.host,
    );
  }

  /// 解析分享，列出文件。
  Future<NetdiskShare> parse(
    String input, {
    NetdiskCredential credential = const NetdiskCredential.none(),
    String? password,
  }) async {
    final link = detect(input);
    final effective = password == null || password.isEmpty
        ? link
        : ParsedShareLink(
            platform: link.platform,
            rawUrl: link.rawUrl,
            shareId: link.shareId,
            password: password,
            subPath: link.subPath,
          );
    return parseLink(effective, credential: credential);
  }

  /// 用一个已经识别好的链接再解析（避免重复 detect）。
  Future<NetdiskShare> parseLink(
    ParsedShareLink link, {
    NetdiskCredential credential = const NetdiskCredential.none(),
  }) async {
    final share =
        await _parserFor(link.platform).parse(link, credential: credential);
    _contexts[share] = link;
    return share;
  }

  /// 把文件换成直链。
  ///
  /// 同一客户端解析出的分享会复用私有提取码上下文；跨客户端请用 [resolveDownloadFrom]。
  Future<NetdiskDownloadLink> resolveDownload(
    NetdiskShare share,
    NetdiskFile file, {
    NetdiskCredential credential = const NetdiskCredential.none(),
  }) async {
    final link = _contexts[share] ?? detect(share.shareUrl ?? '');
    return _parserFor(share.platform)
        .resolve(link, file, credential: credential);
  }

  /// 带链接上下文取直链：分享对象本身不保留提取码，所以用这个更稳。
  Future<NetdiskDownloadLink> resolveDownloadFrom(
    ParsedShareLink link,
    NetdiskFile file, {
    NetdiskCredential credential = const NetdiskCredential.none(),
  }) =>
      _parserFor(link.platform).resolve(link, file, credential: credential);

  /// 批量取直链，带并发上限与失败隔离。
  Future<List<({NetdiskFile file, NetdiskDownloadLink? link, Object? error})>>
      resolveAll(
    ParsedShareLink link,
    List<NetdiskFile> files, {
    NetdiskCredential credential = const NetdiskCredential.none(),
    int concurrency = 3,
    void Function(int done, int total)? onProgress,
  }) async {
    final parser = _parserFor(link.platform);
    final out = List<
        ({
          NetdiskFile file,
          NetdiskDownloadLink? link,
          Object? error
        })?>.filled(files.length, null);
    var cursor = 0;
    var done = 0;
    final limit = concurrency.clamp(1, 8).clamp(0, files.length);

    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= files.length) return;
        final file = files[index];
        try {
          final direct =
              await parser.resolve(link, file, credential: credential);
          out[index] = (file: file, link: direct, error: null);
        } catch (e) {
          out[index] = (file: file, link: null, error: e);
        }
        done++;
        onProgress?.call(done, files.length);
      }
    }

    await Future.wait(List.generate(limit, (_) => worker()));
    return out.map((entry) => entry!).toList(growable: false);
  }

  NetdiskParser _parserFor(NetdiskPlatform platform) {
    for (final p in parsers) {
      if (p.platform == platform) return p;
    }
    throw NetdiskException(
      NetdiskErrorCode.unsupportedPlatform,
      '没有注册 ${platform.label} 的解析器',
    );
  }

  void close() => http.close();
}
