/// 网盘直链解析与下载库。
///
/// 支持百度网盘、夸克网盘、阿里云盘三个平台。对外只需要三个入口：
/// [NetdiskClient.parse]、[NetdiskClient.resolveDownload]、[Downloader.download]。
library;

export 'src/client.dart';
export 'src/errors.dart';
export 'src/http/http_client.dart';
export 'src/models.dart';
export 'src/platforms/platforms.dart';
export 'src/download/downloader.dart';
export 'src/download/progress.dart';
