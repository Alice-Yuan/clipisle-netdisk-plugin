// 用真实网络验证一版链接识别与平台探测：不发凭证、不下载，
// 只打「一定会失败但能证明路由活着」的请求，确认错误映射正确。
// 用法：dart run tool/probe_live.dart

// ignore_for_file: avoid_print

import 'package:netdisk_direct/netdisk_direct.dart';

Future<void> main() async {
  final client = NetdiskClient();

  Future<void> probe(String label, String input) async {
    print('── $label');
    try {
      final link = client.detect(input);
      print('   平台=${link.platform.label} shareId=${link.shareId} '
          'pwd=${link.password ?? "-"}');
      final share = await client.parseLink(link);
      print('   解析成功：${share.files.length} 项');
    } on NetdiskException catch (e) {
      print('   ${e.code.name} | ${e.message}'
          '${e.statusCode != null ? " | HTTP ${e.statusCode}" : ""}');
    }
    print('');
  }

  await probe('夸克 · 不存在的分享', 'https://pan.quark.cn/s/000000000000 提取码: 1234');
  await probe('阿里云盘 · 不存在的分享', 'https://www.alipan.com/s/0000000000');
  await probe('百度 · 无 Cookie', 'https://pan.baidu.com/s/1abcdefgh');
  await probe('不支持的平台', 'https://www.123pan.com/s/abcd-1234');

  client.close();
}
