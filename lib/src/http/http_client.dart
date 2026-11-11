import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../errors.dart';

/// 一次 HTTP 往返的结果。把状态码、头、原始字节都留给调用方，
/// 由各平台自己决定如何解释错误。
class HttpResult {
  HttpResult({
    required this.status,
    required this.bodyBytes,
    required this.headers,
    required this.url,
    required this.elapsed,
  });

  final int status;
  final List<int> bodyBytes;
  final Map<String, String> headers;
  final Uri url;
  final Duration elapsed;

  String get bodyText {
    // 网盘接口有时不带 charset，强制按 UTF-8 解，避免中文乱码。
    try {
      return utf8.decode(bodyBytes);
    } on FormatException {
      return latin1.decode(bodyBytes);
    }
  }

  Object? get json {
    final text = bodyText.trim();
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  Map<String, Object?>? get jsonMap {
    final v = json;
    return v is Map ? v.cast<String, Object?>() : null;
  }

  /// 从 `Set-Cookie` 里挑出指定名字的值。
  String? setCookieValue(String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() != 'set-cookie') continue;
      for (final piece in entry.value.split(',')) {
        final head = piece.split(';').first.trim();
        final idx = head.indexOf('=');
        if (idx <= 0) continue;
        if (head.substring(0, idx).trim() == name) {
          return head.substring(idx + 1).trim();
        }
      }
    }
    return null;
  }
}

/// 薄封装。默认带超时、统一 UA、统一错误映射。
class HttpClient {
  HttpClient({
    http.Client? client,
    Duration? timeout,
    this.defaultUserAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  })  : _client = client ?? http.Client(),
        timeout = timeout ?? const Duration(seconds: 20);

  final http.Client _client;
  final Duration timeout;
  final String defaultUserAgent;

  void close() => _client.close();

  Future<HttpResult> get(
    Uri url, {
    Map<String, String>? headers,
  }) =>
      _send('GET', url, headers: headers);

  Future<HttpResult> postJson(
    Uri url, {
    Object? body,
    Map<String, String>? headers,
  }) =>
      _send('POST', url, body: jsonEncode(body ?? const {}), json: true, headers: headers);

  Future<HttpResult> postForm(
    Uri url, {
    required Map<String, String> fields,
    Map<String, String>? headers,
  }) =>
      _send('POST', url, body: Uri(queryParameters: fields).query, json: false, headers: headers);

  Future<HttpResult> _send(
    String method,
    Uri url, {
    String? body,
    bool json = false,
    Map<String, String>? headers,
  }) async {
    final request = http.Request(method, url);
    request.headers['User-Agent'] = defaultUserAgent;
    if (json) {
      request.headers['Content-Type'] = 'application/json;charset=UTF-8';
    } else if (body != null) {
      request.headers['Content-Type'] = 'application/x-www-form-urlencoded;charset=UTF-8';
    }
    if (headers != null) request.headers.addAll(headers);
    if (body != null) request.body = body;

    final stopwatch = Stopwatch()..start();
    try {
      final streamed = await _client.send(request).timeout(timeout);
      final bytes = await streamed.stream.toBytes().timeout(timeout);
      stopwatch.stop();
      return HttpResult(
        status: streamed.statusCode,
        bodyBytes: bytes,
        headers: {
          for (final e in streamed.headers.entries) e.key.toLowerCase(): e.value,
        },
        url: url,
        elapsed: stopwatch.elapsed,
      );
    } on TimeoutException {
      throw NetdiskException(
        NetdiskErrorCode.network,
        '请求超时（${timeout.inSeconds}s）',
        detail: url.toString(),
      );
    } catch (e) {
      if (e is NetdiskException) rethrow;
      throw NetdiskException(
        NetdiskErrorCode.network,
        '网络请求失败：$e',
        detail: url.toString(),
      );
    }
  }
}
