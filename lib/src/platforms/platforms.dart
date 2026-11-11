import '../http/http_client.dart';
import 'aliyun.dart';
import 'baidu.dart';
import 'parser.dart';
import 'quark.dart';

export 'aliyun.dart';
export 'baidu.dart';
export 'parser.dart';
export 'quark.dart';

/// 默认解析器集合：本仓库只支持这三个平台。
List<NetdiskParser> defaultParsers(HttpClient http) => [
      BaiduParser(http),
      QuarkParser(http),
      AliyunParser(http),
    ];
