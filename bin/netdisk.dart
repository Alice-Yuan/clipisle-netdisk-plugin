import 'dart:io';

import 'package:netdisk_direct/netdisk_direct.dart';

/// 命令行入口。
///
/// ```sh
/// dart run bin/netdisk.dart info  "https://pan.quark.cn/s/xxxx 提取码: 1234"
/// dart run bin/netdisk.dart links "https://www.alipan.com/s/xxxx"
/// dart run bin/netdisk.dart get   "<链接>" -o ./downloads
/// ```
///
/// Cookie / token 从环境变量读，避免泄进 shell 历史：
///   NETDISK_BAIDU_COOKIE      百度网盘 Cookie（BDUSS + STOKEN，必需）
///   NETDISK_QUARK_COOKIE      夸克 Cookie（可选，免登录有大小上限）
///   NETDISK_ALIYUN_REFRESH    阿里云盘 refresh_token（可选，匿名可解析）
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '-h' || args.first == '--help') {
    _usage();
    exit(args.isEmpty ? 64 : 0);
  }

  final command = args.first;
  final rest = args.sublist(1);
  final options = _Options.parse(rest);
  if (options.positional.isEmpty) {
    stderr.writeln('缺少链接参数');
    _usage();
    exit(64);
  }

  final input = options.positional.first;
  final client = NetdiskClient();
  final credential = _credentialFromEnv();

  try {
    switch (command) {
      case 'info':
        final link = client.detect(input);
        _printLink(link);
        final share = await client.parseLink(link, credential: credential);
        _printShare(share);
      case 'links':
        final link = client.detect(input);
        _printLink(link);
        final share = await client.parseLink(link, credential: credential);
        stdout.writeln('共 ${share.downloadableFiles.length} 个文件：');
        for (final file in share.downloadableFiles) {
          try {
            final dl = await client.resolveDownloadFrom(
              link,
              file,
              credential: credential,
            );
            stdout.writeln('  ${file.name}');
            stdout.writeln('    ${dl.url}');
            if (dl.headers.isNotEmpty) {
              final headerText = dl.headers.entries
                  .map((e) => '-H "${e.key}: ${e.value}"')
                  .join(' ');
              stdout.writeln('    需要请求头：$headerText');
            }
          } on NetdiskException catch (e) {
            stderr.writeln('  ${file.name} 取直链失败：${e.code.name} ${e.message}');
          }
        }
      case 'get':
        await _downloadAll(client, input, options, credential);
      default:
        stderr.writeln('未知命令：$command');
        _usage();
        exit(64);
    }
  } on NetdiskException catch (e) {
    stderr.writeln('错误：$e');
    exit(1);
  } finally {
    client.close();
  }
}

Future<void> _downloadAll(
  NetdiskClient client,
  String input,
  _Options options,
  NetdiskCredential credential,
) async {
  final link = client.detect(input);
  final share = await client.parseLink(link, credential: credential);
  final outDir = Directory(options.output ?? './downloads');
  await outDir.create(recursive: true);

  final downloader = Downloader();
  var index = 0;
  for (final file in share.downloadableFiles) {
    index++;
    stdout.writeln('[$index/${share.downloadableFiles.length}] ${file.name}');
    final dl = await client.resolveDownloadFrom(link, file, credential: credential);
    final safeName = _safeName(dl.fileName);
    final target = '${outDir.path}${Platform.pathSeparator}$safeName';

    var lastLine = 0;
    final result = await downloader.download(
      dl,
      targetPath: target,
      onRefreshLink: () => client.resolveDownloadFrom(
        link,
        file,
        credential: credential,
      ),
      onProgress: (p) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastLine < 500 && p.state != DownloadState.completed) return;
        lastLine = now;
        final pct = p.hasTotal ? (p.fraction * 100).toStringAsFixed(1) : '??';
        final speed = _speed(p.speedBytesPerSec);
        final eta = p.eta == null ? '--' : _duration(p.eta!);
        stdout.write(
          '\r  $pct%  ${_bytes(p.received)}/${p.hasTotal ? _bytes(p.total) : "?"}'
          '  $speed  ETA $eta   ',
        );
      },
    );
    stdout.writeln();
    if (result.isCompleted) {
      stdout.writeln('  完成 -> ${result.path} (${_bytes(result.bytes)})');
    } else {
      stderr.writeln('  未完成：${result.state.name}');
    }
  }
  downloader.close();
}

NetdiskCredential _credentialFromEnv() {
  return NetdiskCredential(
    cookie: Platform.environment['NETDISK_BAIDU_COOKIE'] ??
        Platform.environment['NETDISK_QUARK_COOKIE'],
    refreshToken: Platform.environment['NETDISK_ALIYUN_REFRESH'],
  );
}

/// 每个平台独立的 Cookie 需要分开取，这里给调用方留一个显式入口。
NetdiskCredential credentialFor(NetdiskPlatform platform) {
  final env = Platform.environment;
  return switch (platform) {
    NetdiskPlatform.baidu =>
      NetdiskCredential(cookie: env['NETDISK_BAIDU_COOKIE']),
    NetdiskPlatform.quark =>
      NetdiskCredential(cookie: env['NETDISK_QUARK_COOKIE']),
    NetdiskPlatform.aliyun => NetdiskCredential(
        refreshToken: env['NETDISK_ALIYUN_REFRESH'],
        accessToken: env['NETDISK_ALIYUN_ACCESS'],
      ),
  };
}

void _printLink(ParsedShareLink link) {
  stdout.writeln('平台：${link.platform.label}');
  stdout.writeln('分享 ID：${link.shareId}');
  stdout.writeln('提取码：${link.password ?? "（无）"}');
  if (link.subPath != null) stdout.writeln('子目录：${link.subPath}');
}

void _printShare(NetdiskShare share) {
  stdout.writeln('标题：${share.title ?? "（无）"}');
  stdout.writeln('分享者：${share.ownerName ?? "（未知）"}');
  stdout.writeln('条目：${share.files.length} 个，总计 ${_bytes(share.totalSize)}');
  for (final f in share.files) {
    final kind = f.isFolder ? '目录' : '文件';
    stdout.writeln('  [$kind] ${f.name}  ${_bytes(f.size)}');
  }
}

void _usage() {
  stdout.writeln('''
网盘直链解析与下载 — 百度网盘 / 夸克网盘 / 阿里云盘

用法：dart run bin/netdisk.dart <命令> <链接> [选项]

命令：
  info    识别平台并列出分享内容
  links   解析出全部直链
  get     解析并下载到本地

选项：
  -o, --output <目录>   下载目录，默认 ./downloads

环境变量：
  NETDISK_BAIDU_COOKIE   百度网盘 Cookie（BDUSS + STOKEN，必需）
  NETDISK_QUARK_COOKIE   夸克 Cookie（可选）
  NETDISK_ALIYUN_REFRESH 阿里云盘 refresh_token（可选）

示例：
  dart run bin/netdisk.dart info "https://pan.quark.cn/s/abc 提取码: 1234"
  dart run bin/netdisk.dart get  "https://www.alipan.com/s/xyz" -o ./out
''');
}

String _safeName(String name) {
  var out = name;
  for (final ch in ['/', r'\', ':', '*', '?', '"', '<', '>', '|']) {
    out = out.replaceAll(ch, '_');
  }
  out = out.trim();
  if (out.isEmpty) out = 'unnamed';
  if (out.length > 120) out = out.substring(0, 120);
  return out;
}

String _bytes(int n) {
  if (n < 0) return '?';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = n.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)}${units[unit]}';
}

String _speed(double bps) {
  if (bps <= 0) return '0B/s';
  return '${_bytes(bps.round())}/s';
}

String _duration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  if (h > 0) return '${h}h${m}m';
  if (m > 0) return '${m}m${s}s';
  return '${s}s';
}

class _Options {
  _Options({required this.positional, this.output});

  final List<String> positional;
  final String? output;

  static _Options parse(List<String> args) {
    final positional = <String>[];
    String? output;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-o' || arg == '--output') {
        if (i + 1 < args.length) output = args[++i];
      } else if (arg.startsWith('--output=')) {
        output = arg.substring('--output='.length);
      } else {
        positional.add(arg);
      }
    }
    return _Options(positional: positional, output: output);
  }
}
