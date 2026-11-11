/// 下载进度快照。速度是**定时采样**算的，不依赖收到字节：
/// 停流时 [speedBytesPerSec] 会在 2 秒内归零，不会冻结在旧值。
class DownloadProgress {
  const DownloadProgress({
    required this.received,
    required this.total,
    required this.speedBytesPerSec,
    required this.state,
    required this.idleFor,
    this.fileName,
  });

  final int received;

  /// 总量。-1 表示服务端没给 Content-Length。
  final int total;
  final double speedBytesPerSec;
  final DownloadState state;

  /// 距离上次收到字节过了多久。
  final Duration idleFor;
  final String? fileName;

  bool get hasTotal => total > 0;

  double get fraction {
    if (!hasTotal) return 0;
    final f = received / total;
    return f > 1 ? 1 : f;
  }

  /// 预计剩余时间；没有总量或无速度时为 null。
  Duration? get eta {
    if (!hasTotal || speedBytesPerSec <= 0) return null;
    final remain = total - received;
    if (remain <= 0) return Duration.zero;
    return Duration(seconds: (remain / speedBytesPerSec).ceil());
  }

  @override
  String toString() => 'DownloadProgress(${state.name}, $received/$total, '
      '${speedBytesPerSec.toStringAsFixed(0)} B/s, idle ${idleFor.inSeconds}s)';
}

enum DownloadState {
  preparing,
  running,
  stalled,
  paused,
  merging,
  completed,
  failed,
  canceled,
}
