import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../errors.dart';
import '../models.dart';
import 'progress.dart';

/// 一个支持断点续传的下载器。
///
/// 三个关键设计（针对网盘直链的常见坑）：
/// - **速度按墙上时间采样**，停流 2 秒即归零，不冻结在旧值；
/// - **无进度看门狗**，[idleTimeout] 内没收到任何字节就判定停滞并中断，
///   让调用方重新解析直链（网盘直链通常 1-4 小时过期）；
/// - **断点续传**：`.part` 文件 + `Range` 请求，用 `ETag`/`Last-Modified`
///   校验续传的确实是同一份内容。
class Downloader {
  Downloader({
    http.Client? client,
    this.chunkSize = 256 * 1024,
    this.idleTimeout = const Duration(seconds: 30),
    this.maxRetries = 3,
    this.probeTimeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// 写盘块大小。
  final int chunkSize;

  /// 多久没收到字节算停滞。
  final Duration idleTimeout;

  /// 单个直链最多重试几次（含续传）。
  final int maxRetries;

  /// 探测元数据的超时。
  final Duration probeTimeout;

  /// 下载一个直链到 [targetPath]。
  ///
  /// [onLinkExpired] 会在直链过期或返回 403 时被调用，用它换一条新直链再继续。
  Future<DownloadResult> download(
    NetdiskDownloadLink link, {
    required String targetPath,
    void Function(DownloadProgress progress)? onProgress,
    bool Function()? shouldCancel,
    Future<NetdiskDownloadLink> Function()? onRefreshLink,
  }) async {
    var currentLink = link;
    var attempt = 0;
    Object? lastError;

    while (attempt <= maxRetries) {
      if (shouldCancel?.call() ?? false) {
        return const DownloadResult(state: DownloadState.canceled);
      }
      try {
        return await _attempt(
          currentLink,
          targetPath: targetPath,
          onProgress: onProgress,
          shouldCancel: shouldCancel,
        );
      } on _LinkExpired {
        if (onRefreshLink == null) rethrow;
        attempt++;
        onProgress?.call(DownloadProgress(
          received: _lastKnownBytes(targetPath),
          total: currentLink.size,
          speedBytesPerSec: 0,
          state: DownloadState.preparing,
          idleFor: Duration.zero,
          fileName: currentLink.fileName,
        ));
        currentLink = await onRefreshLink();
      } on _Stalled catch (e) {
        lastError = e;
        attempt++;
        if (attempt > maxRetries) break;
        // 停滞先续传重试；续传也拿不到数据就交给上层换源。
        if (onRefreshLink != null && attempt > 1) {
          currentLink = await onRefreshLink();
        }
      } on NetdiskException catch (e) {
        if (e.code == NetdiskErrorCode.network && attempt < maxRetries) {
          lastError = e;
          attempt++;
          continue;
        }
        rethrow;
      }
    }
    throw lastError is NetdiskException
        ? lastError
        : NetdiskException(
            NetdiskErrorCode.network,
            '下载失败，重试 $maxRetries 次后放弃：${lastError ?? "未知原因"}',
          );
  }

  Future<DownloadResult> _attempt(
    NetdiskDownloadLink link, {
    required String targetPath,
    void Function(DownloadProgress progress)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final file = File(targetPath);
    final partFile = File('$targetPath.part');
    final metaFile = File('$targetPath.part.meta');

    await file.parent.create(recursive: true);

    var existing = 0;
    String? savedValidator;
    if (await partFile.exists()) {
      existing = await partFile.length();
      if (await metaFile.exists()) {
        savedValidator = (await metaFile.readAsString()).trim();
      }
    }

    // 续传前先用 Range: 0-0 探一次，确认直链还有效、服务端支持 Range、
    // 且内容标识没变（换了内容就不能续）。
    final probe = await _probe(link);
    if (existing > 0 && savedValidator != null && probe.validator != null &&
        savedValidator != probe.validator) {
      // 内容变了：丢弃旧分片重新下。
      existing = 0;
      await partFile.writeAsBytes(const []);
    }
    if (existing > 0 && !probe.acceptsRange) {
      existing = 0;
      await partFile.writeAsBytes(const []);
    }
    if (existing > 0 && probe.total > 0 && existing > probe.total) {
      existing = 0;
      await partFile.writeAsBytes(const []);
    }
    if (probe.validator != null) {
      await metaFile.writeAsString(probe.validator!);
    }

    final total = probe.total;
    if (existing > 0 && total > 0 && existing == total) {
      // 上次其实已经下完，只是没来得及改名。
      await partFile.rename(targetPath);
      await _deleteQuietly(metaFile);
      onProgress?.call(DownloadProgress(
        received: total,
        total: total,
        speedBytesPerSec: 0,
        state: DownloadState.completed,
        idleFor: Duration.zero,
        fileName: link.fileName,
      ));
      return DownloadResult(
        state: DownloadState.completed,
        bytes: total,
        path: targetPath,
        reusedExisting: true,
      );
    }

    final headers = <String, String>{
      ...link.headers,
      if (existing > 0) 'Range': 'bytes=$existing-',
    };

    final request = http.Request('GET', Uri.parse(link.url))..headers.addAll(headers);
    final streamed = await _client.send(request).timeout(probeTimeout);

    if (streamed.statusCode == 403 || streamed.statusCode == 401) {
      await streamed.stream.drain<void>();
      throw const _LinkExpired();
    }
    if (streamed.statusCode == 404 || streamed.statusCode == 410) {
      await streamed.stream.drain<void>();
      throw const _LinkExpired();
    }
    if (streamed.statusCode != 200 && streamed.statusCode != 206) {
      final body = await streamed.stream.bytesToString();
      throw NetdiskException(
        NetdiskErrorCode.network,
        '下载返回 HTTP ${streamed.statusCode}',
        statusCode: streamed.statusCode,
        detail: body.length > 300 ? body.substring(0, 300) : body,
      );
    }

    // 服务端忽略了 Range，返回 200 整份：必须从头写，不能追加。
    final appending = streamed.statusCode == 206 && existing > 0;
    final sink = partFile.openWrite(
      mode: appending ? FileMode.append : FileMode.write,
    );

    var received = appending ? existing : 0;
    final startBytes = received;

    // ---- 速度采样：按墙上时间，收不到字节也继续走 ----
    var lastSampleBytes = received;
    var lastSampleAt = DateTime.now();
    var lastByteAt = DateTime.now();
    var speed = 0.0;
    var state = DownloadState.running;

    final sampler = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final now = DateTime.now();
      final elapsed = now.difference(lastSampleAt).inMilliseconds;
      if (elapsed <= 0) return;
      final delta = received - lastSampleBytes;
      speed = delta * 1000 / elapsed;
      lastSampleBytes = received;
      lastSampleAt = now;

      final idle = now.difference(lastByteAt);
      if (idle >= const Duration(seconds: 2) && speed > 0) speed = 0;
      final nextState = idle >= idleTimeout
          ? DownloadState.stalled
          : (idle >= const Duration(seconds: 2) ? DownloadState.stalled : DownloadState.running);
      if (nextState != state) state = nextState;

      onProgress?.call(DownloadProgress(
        received: received,
        total: total,
        speedBytesPerSec: speed,
        state: state,
        idleFor: idle,
        fileName: link.fileName,
      ));
    });

    var stalled = false;
    try {
      await for (final chunk in streamed.stream.timeout(
        idleTimeout,
        onTimeout: (sink) {
          stalled = true;
          sink.addError(const _Stalled());
          sink.close();
        },
      )) {
        if (shouldCancel?.call() ?? false) {
          await sink.flush();
          await sink.close();
          sampler.cancel();
          return DownloadResult(
            state: DownloadState.canceled,
            bytes: received,
            path: targetPath,
          );
        }
        sink.add(chunk);
        received += chunk.length;
        lastByteAt = DateTime.now();
      }
    } on _Stalled {
      rethrow;
    } finally {
      sampler.cancel();
      await sink.flush();
      await sink.close();
    }

    if (stalled) throw const _Stalled();

    if (total > 0 && received < total) {
      // 没下完：保留 .part，下次续传。
      throw _Stalled('连接提前结束，已收 $received / $total 字节');
    }

    await partFile.rename(targetPath);
    await _deleteQuietly(metaFile);
    onProgress?.call(DownloadProgress(
      received: received,
      total: total > 0 ? total : received,
      speedBytesPerSec: 0,
      state: DownloadState.completed,
      idleFor: Duration.zero,
      fileName: link.fileName,
    ));

    return DownloadResult(
      state: DownloadState.completed,
      bytes: received,
      path: targetPath,
      resumedFrom: startBytes,
    );
  }

  Future<_Probe> _probe(NetdiskDownloadLink link) async {
    final request = http.Request('GET', Uri.parse(link.url))
      ..headers.addAll({...link.headers, 'Range': 'bytes=0-0'});
    final streamed = await _client.send(request).timeout(probeTimeout);
    await streamed.stream.drain<void>();

    if (streamed.statusCode == 403 || streamed.statusCode == 401) {
      throw const _LinkExpired();
    }
    if (streamed.statusCode == 404 || streamed.statusCode == 410) {
      throw const _LinkExpired();
    }
    final headers = streamed.headers;
    final contentRange = headers['content-range'];
    final total =
        _parseTotal(contentRange) ?? _parseInt(headers['content-length']) ?? -1;

    return _Probe(
      acceptsRange: streamed.statusCode == 206,
      total: total,
      validator: headers['etag'] ?? headers['last-modified'],
    );
  }

  static int? _parseTotal(String? contentRange) {
    if (contentRange == null) return null;
    final idx = contentRange.lastIndexOf('/');
    if (idx < 0) return null;
    return int.tryParse(contentRange.substring(idx + 1).trim());
  }

  static int? _parseInt(String? v) => v == null ? null : int.tryParse(v.trim());

  static int _lastKnownBytes(String targetPath) {
    final f = File('$targetPath.part');
    try {
      return f.existsSync() ? f.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 清理失败不影响结果。
    }
  }

  void close() => _client.close();
}

class DownloadResult {
  const DownloadResult({
    required this.state,
    this.bytes = 0,
    this.path,
    this.resumedFrom,
    this.reusedExisting = false,
  });

  final DownloadState state;
  final int bytes;
  final String? path;

  /// 从第几个字节开始续传的（0 表示全新下载）。
  final int? resumedFrom;
  final bool reusedExisting;

  bool get isCompleted => state == DownloadState.completed;
}

class _Probe {
  const _Probe({required this.acceptsRange, required this.total, this.validator});
  final bool acceptsRange;
  final int total;
  final String? validator;
}

/// 直链失效（403 / 404 / 410）。内部用，触发换链重试。
class _LinkExpired implements Exception {
  const _LinkExpired();
  @override
  String toString() => '直链已失效';
}

/// 停滞或提前断流。内部用。
class _Stalled implements Exception {
  const _Stalled([this.message = '超过 ${"30s"} 没有收到数据']);
  final String message;
  @override
  String toString() => message;
}
