import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../errors.dart';
import '../models.dart';
import 'progress.dart';

/// 支持校验断点、可取消请求和无数据超时的下载器。
class Downloader {
  Downloader({
    http.Client? client,
    this.chunkSize = 256 * 1024,
    this.idleTimeout = const Duration(seconds: 30),
    this.maxRetries = 3,
    this.probeTimeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client() {
    if (chunkSize <= 0 ||
        maxRetries < 0 ||
        idleTimeout <= Duration.zero ||
        probeTimeout <= Duration.zero) {
      throw ArgumentError('下载块大小和超时必须大于零，重试次数不能为负');
    }
  }

  final http.Client _client;
  final int chunkSize;
  final Duration idleTimeout;

  /// 首次请求以外允许的重试次数。
  final int maxRetries;
  final Duration probeTimeout;
  static final _activePaths = <String>{};

  /// 下载至显式指定的路径；不会覆盖已存在的最终文件。
  /// 同一目标及其临时文件不能同时被另一个下载使用。
  Future<DownloadResult> download(
    NetdiskDownloadLink link, {
    required String targetPath,
    void Function(DownloadProgress progress)? onProgress,
    bool Function()? shouldCancel,
    Future<NetdiskDownloadLink> Function()? onRefreshLink,
  }) async {
    final operation = _Operation(shouldCancel);
    final reserved = <String>[];
    RandomAccessFile? lock;
    var path = p.normalize(p.absolute(targetPath));
    try {
      operation.check();
      await File(path).parent.create(recursive: true);
      path = p.join(
          await File(path).parent.resolveSymbolicLinks(), p.basename(path));
      for (final candidate in [
        path,
        '$path.part',
        '$path.part.meta',
        '$path.part.lock'
      ]) {
        final key = Platform.isWindows ? candidate.toLowerCase() : candidate;
        if (_activePaths.contains(key)) {
          throw const NetdiskException(NetdiskErrorCode.unknown, '目标正在下载中');
        }
      }
      for (final candidate in [
        path,
        '$path.part',
        '$path.part.meta',
        '$path.part.lock'
      ]) {
        final key = Platform.isWindows ? candidate.toLowerCase() : candidate;
        _activePaths.add(key);
        reserved.add(key);
      }
      for (final candidate in [
        path,
        '$path.part',
        '$path.part.meta',
        '$path.part.lock'
      ]) {
        await _checkFile(candidate, allowFile: candidate != path);
      }
      lock = await File('$path.part.lock').open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      var current = link;
      for (var attempt = 0;; attempt++) {
        operation.check();
        try {
          return await _attempt(current, path, operation, onProgress);
        } on _LinkExpired {
          if (onRefreshLink == null || attempt >= maxRetries) {
            throw const NetdiskException(NetdiskErrorCode.network, '下载直链已失效');
          }
          current = await operation.wait(onRefreshLink(), probeTimeout);
        } on _Stalled catch (e) {
          if (attempt >= maxRetries) {
            throw NetdiskException(NetdiskErrorCode.network, e.message);
          }
          if (onRefreshLink != null && attempt >= 1) {
            current = await operation.wait(onRefreshLink(), probeTimeout);
          }
        } on http.ClientException {
          operation.check();
          if (attempt >= maxRetries) {
            throw const NetdiskException(NetdiskErrorCode.network, '下载连接中断');
          }
        } on SocketException {
          operation.check();
          if (attempt >= maxRetries) {
            throw const NetdiskException(NetdiskErrorCode.network, '下载网络连接失败');
          }
        } on IOException {
          // 写盘失败不作为网络错误反复重试。
          rethrow;
        }
      }
    } on _Canceled {
      return DownloadResult(
          state: DownloadState.canceled,
          path: targetPath,
          bytes: _lastKnownBytes(path));
    } on TimeoutException {
      throw const NetdiskException(NetdiskErrorCode.network, '下载请求超时');
    } finally {
      operation.dispose();
      if (lock != null) await lock.close();
      _activePaths.removeAll(reserved);
    }
  }

  Future<DownloadResult> _attempt(NetdiskDownloadLink link, String path,
      _Operation operation, void Function(DownloadProgress)? onProgress) async {
    final part = File('$path.part');
    final meta = File('$path.part.meta');
    final probe = await _probe(link, operation);
    var existing = await part.exists() ? await part.length() : 0;
    String? saved;
    if (await meta.exists()) {
      final raw = await meta.readAsString();
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map &&
            decoded['identity'] == _identity(link) &&
            decoded['validator'] is String) {
          saved = decoded['validator'] as String;
        }
      } on FormatException {
        // 兼容早期仅保存 validator 的断点文件。
        saved = raw.trim();
      }
    }
    if (existing > 0 &&
        (!probe.acceptsRange ||
            saved == null ||
            probe.validator == null ||
            saved != probe.validator ||
            (probe.total >= 0 && existing > probe.total))) {
      existing = 0;
    }
    // 即使断点长度等于总长，也要向服务端验证实际响应再提交。
    if (existing > 0 && existing == probe.total) existing = 0;
    final headers = _headers(link);
    if (existing > 0) {
      headers['Range'] = 'bytes=$existing-';
      headers['If-Range'] = probe.validator!;
    }
    final response = await _send(link, headers, operation);
    RandomAccessFile? output;
    StreamIterator<List<int>>? reader;
    Timer? sampler;
    var received = existing;
    var startBytes = existing;
    var total = probe.total;
    try {
      _checkStatus(response.statusCode);
      _checkEncoding(response.headers);
      final length = _contentLength(response);
      final validator = _validator(response.headers);
      int? expectedBody = length;
      if (response.statusCode == 206) {
        final range = _range(response.headers['content-range']);
        if (range == null ||
            range.start != existing ||
            (range.total != null && range.end != range.total! - 1) ||
            (length != null && length != range.end - range.start + 1)) {
          throw _bad('下载返回的 Content-Range 不匹配');
        }
        if (existing > 0 && validator != saved) {
          throw _bad('续传响应的内容标识已改变');
        }
        if (probe.total >= 0 &&
            range.total != null &&
            probe.total != range.total) {
          throw _bad('下载响应总长度与探测结果不一致');
        }
        total = range.total ?? probe.total;
        expectedBody = range.end - range.start + 1;
      } else {
        // 服务端忽略 Range / If-Range 时，整份响应必须从零开始。
        received = 0;
        startBytes = 0;
        total = length ?? (validator == probe.validator ? probe.total : -1);
        if (length != null &&
            probe.total >= 0 &&
            length != probe.total &&
            validator == probe.validator) {
          throw _bad('下载响应长度与探测结果不一致');
        }
      }
      if (total < 0 && link.size >= 0) total = link.size;
      if (total >= 0 &&
          expectedBody != null &&
          received + expectedBody != total) {
        throw _bad('下载响应长度不完整');
      }
      operation.check();
      await _checkFile(part.path);
      await _checkFile(meta.path);
      // 元数据记录实际响应标识，避免探测后内容变化污染下一次续传。
      if (startBytes == 0) await part.writeAsBytes(const []);
      await meta.writeAsString(
          jsonEncode({
            'identity': _identity(link),
            'validator': validator,
          }),
          flush: true);
      output = await part.open(mode: FileMode.append);
      var lastBytes = received;
      var lastSample = DateTime.now();
      var lastByte = lastSample;
      sampler = Timer.periodic(const Duration(milliseconds: 500), (_) {
        final now = DateTime.now();
        final elapsed = now.difference(lastSample).inMicroseconds;
        final idle = now.difference(lastByte);
        try {
          onProgress?.call(DownloadProgress(
            received: received,
            total: total,
            speedBytesPerSec:
                elapsed > 0 ? (received - lastBytes) * 1000000 / elapsed : 0,
            state: idle >= const Duration(seconds: 2)
                ? DownloadState.stalled
                : DownloadState.running,
            idleFor: idle,
            fileName: link.fileName,
          ));
        } catch (e, st) {
          operation.stop(e, st);
        }
        lastSample = now;
        lastBytes = received;
      });
      reader = StreamIterator(response.stream);
      var bodyBytes = 0;
      while (await operation.wait(reader.moveNext(),
          idleTimeout - DateTime.now().difference(lastByte))) {
        operation.check();
        final chunk = reader.current;
        if ((expectedBody != null && bodyBytes + chunk.length > expectedBody) ||
            (total >= 0 && received + chunk.length > total)) {
          throw _bad('下载响应包含超出声明长度的数据');
        }
        for (var offset = 0; offset < chunk.length; offset += chunkSize) {
          operation.check();
          final end = offset + chunkSize < chunk.length
              ? offset + chunkSize
              : chunk.length;
          await output.writeFrom(chunk, offset, end);
          received += end - offset;
        }
        bodyBytes += chunk.length;
        if (chunk.isNotEmpty) lastByte = DateTime.now();
      }
      operation.check();
      if ((expectedBody != null && bodyBytes != expectedBody) ||
          (total >= 0 && received != total)) {
        throw _Stalled('下载连接提前结束：$received / $total 字节');
      }
      await output.flush();
      await output.close();
      output = null;
      await _checkFile(path, allowFile: false);
      await part.rename(path);
      try {
        await meta.delete();
      } on FileSystemException {
        // 已完成文件不因辅助元数据清理失败而被判为失败。
      }
      onProgress?.call(DownloadProgress(
          received: received,
          total: total >= 0 ? total : received,
          speedBytesPerSec: 0,
          state: DownloadState.completed,
          idleFor: Duration.zero,
          fileName: link.fileName));
      return DownloadResult(
          state: DownloadState.completed,
          bytes: received,
          path: path,
          resumedFrom: startBytes);
    } on TimeoutException {
      throw const _Stalled('下载响应长时间没有数据');
    } finally {
      sampler?.cancel();
      if (reader != null) {
        await reader.cancel();
      } else {
        await response.stream.listen(null).cancel();
      }
      if (output != null) await output.close();
    }
  }

  Future<_Probe> _probe(NetdiskDownloadLink link, _Operation operation) async {
    final response =
        await _send(link, {..._headers(link), 'Range': 'bytes=0-0'}, operation);
    try {
      // 无需消费探测响应；忽略 Range 的服务器可能发送整个大文件。
      if (response.statusCode == 416 &&
          response.headers['content-range']?.trim() == 'bytes */0') {
        return _Probe(false, 0, _validator(response.headers));
      }
      _checkStatus(response.statusCode);
      _checkEncoding(response.headers);
      final length = _contentLength(response);
      if (response.statusCode == 206) {
        final range = _range(response.headers['content-range']);
        if (range == null ||
            range.start != 0 ||
            range.end != 0 ||
            (length != null && length != 1)) {
          throw _bad('探测返回的 Content-Range 不匹配');
        }
        return _Probe(true, range.total ?? -1, _validator(response.headers));
      }
      return _Probe(false, length ?? -1, _validator(response.headers));
    } finally {
      await response.stream.listen(null).cancel();
    }
  }

  Future<http.StreamedResponse> _send(NetdiskDownloadLink link,
      Map<String, String> headers, _Operation operation) async {
    final uri = Uri.tryParse(link.url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const NetdiskException(
          NetdiskErrorCode.badLink, '下载地址必须为 HTTP(S) URL');
    }
    final original = uri;
    var current = uri;
    final currentHeaders = Map<String, String>.of(headers);
    const sensitive = [
      'cookie',
      'authorization',
      'proxy-authorization',
      'x-api-key',
      'x-auth-token'
    ];
    const forwarded = [
      'accept',
      'user-agent',
      'accept-encoding',
      'range',
      'if-range'
    ];
    for (var redirects = 0;; redirects++) {
      operation.check();
      if (current.scheme != 'https') {
        currentHeaders
            .removeWhere((key, _) => sensitive.contains(key.toLowerCase()));
      }
      final abort = Completer<void>();
      final request =
          http.AbortableRequest('GET', current, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers.addAll(currentHeaders);
      var abandoned = false;
      final pending = _client.send(request).then((response) {
        if (abandoned) {
          unawaited(response.stream.listen(null).cancel());
        }
        return response;
      });
      late final http.StreamedResponse response;
      try {
        response = await operation.wait(pending, probeTimeout);
      } catch (e) {
        abandoned = true;
        abort.complete();
        if (e is TimeoutException) throw const _Stalled('等待下载响应头超时');
        rethrow;
      }
      if (![301, 302, 303, 307, 308].contains(response.statusCode)) {
        return response;
      }
      await response.stream.listen(null).cancel();
      if (redirects >= 5) throw _bad('下载重定向次数过多');
      final location = response.headers['location'];
      final next = location == null ? null : current.resolve(location);
      if (next == null ||
          !['http', 'https'].contains(next.scheme) ||
          next.host.isEmpty ||
          (current.scheme == 'https' && next.scheme != 'https')) {
        throw _bad('下载重定向地址无效或降低了传输安全性');
      }
      if (next.origin != original.origin) {
        currentHeaders
            .removeWhere((key, _) => !forwarded.contains(key.toLowerCase()));
      }
      current = next;
    }
  }

  static Map<String, String> _headers(NetdiskDownloadLink link) => {
        for (final entry in link.headers.entries)
          if (!['range', 'if-range', 'accept-encoding']
              .contains(entry.key.toLowerCase()))
            entry.key: entry.value,
        'Accept-Encoding': 'identity',
      };

  static String _identity(NetdiskDownloadLink link) =>
      '${link.platform.id}:${sha256.convert(utf8.encode(link.fileId ?? link.url))}';

  static String? _validator(Map<String, String> headers) {
    final etag = headers['etag'];
    if (etag != null && etag.isNotEmpty && !etag.startsWith('W/')) return etag;
    final modified = headers['last-modified'];
    if (modified != null) {
      try {
        HttpDate.parse(modified);
        return modified;
      } on HttpException {
        return null;
      }
    }
    return null;
  }

  static int? _contentLength(http.StreamedResponse response) {
    final raw = response.headers['content-length'];
    if (raw == null) return response.contentLength;
    final value = int.tryParse(raw);
    if (value == null || value < 0) throw _bad('非法 Content-Length');
    return value;
  }

  static _Range? _range(String? value) {
    final match =
        RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(value?.trim() ?? '');
    if (match == null) return null;
    final start = int.tryParse(match[1]!);
    final end = int.tryParse(match[2]!);
    final total = match[3] == '*' ? null : int.tryParse(match[3]!);
    if (start == null ||
        end == null ||
        start > end ||
        (match[3] != '*' && (total == null || end >= total))) {
      return null;
    }
    return _Range(start, end, total);
  }

  static void _checkEncoding(Map<String, String> headers) {
    final encoding = headers['content-encoding'];
    if (encoding != null && encoding.toLowerCase() != 'identity') {
      throw _bad('下载服务器未遵循 identity 编码请求');
    }
  }

  static void _checkStatus(int status) {
    if ([401, 403, 404, 410].contains(status)) throw const _LinkExpired();
    if (status != 200 && status != 206) {
      throw NetdiskException(NetdiskErrorCode.network, '下载返回 HTTP $status',
          statusCode: status);
    }
  }

  static NetdiskException _bad(String message) =>
      NetdiskException(NetdiskErrorCode.badResponse, message);
  static Future<void> _checkFile(String path, {bool allowFile = true}) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        !(allowFile && type == FileSystemEntityType.file)) {
      throw NetdiskException(
          NetdiskErrorCode.unknown, '拒绝覆盖已有文件、目录或符号链接：$path');
    }
  }

  static int _lastKnownBytes(String path) {
    try {
      return File('$path.part').lengthSync();
    } on FileSystemException {
      return 0;
    }
  }

  void close() => _client.close();
}

class DownloadResult {
  const DownloadResult(
      {required this.state,
      this.bytes = 0,
      this.path,
      this.resumedFrom,
      this.reusedExisting = false});
  final DownloadState state;
  final int bytes;
  final String? path;
  final int? resumedFrom;
  final bool reusedExisting;
  bool get isCompleted => state == DownloadState.completed;
}

class _Probe {
  const _Probe(this.acceptsRange, this.total, this.validator);
  final bool acceptsRange;
  final int total;
  final String? validator;
}

class _Range {
  const _Range(this.start, this.end, this.total);
  final int start;
  final int end;
  final int? total;
}

class _LinkExpired implements Exception {
  const _LinkExpired();
}

class _Canceled implements Exception {
  const _Canceled();
}

class _Stalled implements Exception {
  const _Stalled(this.message);
  final String message;
}

class _Operation {
  _Operation(this.shouldCancel) {
    timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      try {
        check();
      } catch (e, st) {
        stop(e, st);
      }
    });
  }
  final bool Function()? shouldCancel;
  final _waiters = <void Function()>{};
  Object? error;
  StackTrace? stack;
  late final Timer timer;
  void check() {
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    if (shouldCancel?.call() ?? false) throw const _Canceled();
  }

  void stop(Object e, StackTrace st) {
    if (error != null) return;
    error = e;
    stack = st;
    for (final waiter in _waiters.toList()) {
      waiter();
    }
  }

  Future<T> wait<T>(Future<T> future, Duration timeout) async {
    final stopped = Completer<T>();
    void cancel() => stopped.completeError(error!, stack!);
    _waiters.add(cancel);
    try {
      // Attach handlers before observing cancellation so late network errors are consumed.
      final pending = Future.any([future, stopped.future]);
      try {
        check();
      } catch (e, st) {
        stop(e, st);
      }
      return await pending.timeout(timeout);
    } finally {
      _waiters.remove(cancel);
    }
  }

  void dispose() => timer.cancel();
}
