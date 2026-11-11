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
      _send('POST', url,
          body: jsonEncode(body ?? const {}), json: true, headers: headers);

  Future<HttpResult> postForm(
    Uri url, {
    required Map<String, String> fields,
    Map<String, String>? headers,
  }) =>
      _send('POST', url,
          body: Uri(queryParameters: fields).query,
          json: false,
          headers: headers);

  Future<HttpResult> _send(
    String method,
    Uri url, {
    String? body,
    bool json = false,
    Map<String, String>? headers,
  }) async {
    final abort = Completer<void>();
    final stopwatch = Stopwatch()..start();
    StreamIterator<List<int>>? bodyIterator;
    void cancel() {
      if (!abort.isCompleted) abort.complete();
      final iterator = bodyIterator;
      if (iterator != null) {
        unawaited(iterator.cancel().catchError((Object _) {}));
      }
    }

    Future<HttpResult> perform() async {
      var target = url;
      for (var redirects = 0;; redirects++) {
        if (stopwatch.elapsed >= timeout) {
          throw const NetdiskException(
              NetdiskErrorCode.network, '网络请求失败或超时，请重试');
        }
        final request =
            http.AbortableRequest(method, target, abortTrigger: abort.future)
              ..followRedirects = false;
        request.headers['User-Agent'] = defaultUserAgent;
        if (json) {
          request.headers['Content-Type'] = 'application/json;charset=UTF-8';
        } else if (body != null) {
          request.headers['Content-Type'] =
              'application/x-www-form-urlencoded;charset=UTF-8';
        }
        if (headers != null) request.headers.addAll(headers);
        if (body != null) request.body = body!;
        final response = await _client.send(request);
        if (abort.isCompleted || stopwatch.elapsed >= timeout) {
          await response.stream.listen(null).cancel();
          throw const NetdiskException(
              NetdiskErrorCode.network, '网络请求失败或超时，请重试');
        }
        final location = response.headers['location'];
        if (location != null &&
            {301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final next = target.resolve(location);
          // Keep all credentials on the original HTTPS origin, without URL userinfo.
          if (next.scheme == 'https' &&
              next.origin == target.origin &&
              next.userInfo.isEmpty) {
            await response.stream.listen(null).cancel();
            if (redirects >= 3) {
              throw const NetdiskException(
                  NetdiskErrorCode.badResponse, '接口重定向次数过多');
            }
            if (response.statusCode == 303 ||
                ((response.statusCode == 301 || response.statusCode == 302) &&
                    method == 'POST')) {
              method = 'GET';
              body = null;
              json = false;
            }
            target = next;
            continue;
          }
        }
        const maxBytes = 8 * 1024 * 1024;
        if ((response.contentLength ?? 0) > maxBytes) {
          await response.stream.listen(null).cancel();
          throw const NetdiskException(
              NetdiskErrorCode.badResponse, '接口响应超过大小限制');
        }
        final bytes = <int>[];
        final iterator = bodyIterator = StreamIterator(response.stream);
        try {
          while (await iterator.moveNext()) {
            if (stopwatch.elapsed >= timeout) {
              throw const NetdiskException(
                  NetdiskErrorCode.network, '网络请求失败或超时，请重试');
            }
            final chunk = iterator.current;
            if (bytes.length + chunk.length > maxBytes) {
              throw const NetdiskException(
                  NetdiskErrorCode.badResponse, '接口响应超过大小限制');
            }
            bytes.addAll(chunk);
          }
        } finally {
          await iterator.cancel();
          bodyIterator = null;
        }
        return HttpResult(
            status: response.statusCode,
            bodyBytes: bytes,
            headers: {
              for (final e in response.headers.entries)
                e.key.toLowerCase(): e.value
            },
            url: target,
            elapsed: stopwatch.elapsed);
      }
    }

    try {
      // One deadline covers redirects, headers and the entire body. The abort
      // trigger closes supported transports; timeout also bounds custom clients.
      return await perform().timeout(timeout, onTimeout: () {
        cancel();
        throw const NetdiskException(NetdiskErrorCode.network, '网络请求失败或超时，请重试');
      });
    } on NetdiskException {
      rethrow;
    } catch (_) {
      throw const NetdiskException(NetdiskErrorCode.network, '网络请求失败或超时，请重试');
    } finally {
      stopwatch.stop();
      cancel();
    }
  }
}
