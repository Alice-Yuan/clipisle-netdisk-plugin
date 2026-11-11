# ClipIsle Netdisk Plugin

网盘分享目录解析、下载链接获取与 HTTP 下载。根目录是纯 Dart 库；`plugin/` 是单独安装的 ClipIsle Android 插件，支持百度网盘和夸克网盘。阿里云盘仅保留为库中的 experimental 实现。

当前插件版本为 `0.1.1`。公开仓库已创建：[Alice-Yuan/clipisle-netdisk-plugin](https://github.com/Alice-Yuan/clipisle-netdisk-plugin)。安装包与插件清单见 [v0.1.1 Release](https://github.com/Alice-Yuan/clipisle-netdisk-plugin/releases/tag/v0.1.1)。

## 安装

更新 ClipIsle 宿主后，在「插件 → 从 GitHub 添加」输入 `Alice-Yuan/clipisle-netdisk-plugin`，确认安装与首次授权。插件设置中管理账号；粘贴分享文本后选择文件，任务直接进入宿主下载队列。

**当前夸克已完成一个真实样例的完整下载；百度仅登录与目录解析验收通过，取原文件仍受限。**

## 支持范围

| 平台 | 匿名列目录 | 获取原文件下载链接 | Android 插件 |
| --- | --- | --- | --- |
| 百度网盘 | 匿名与登录目录均已真机验证 | 需要登录；本轮真实取链仍失败，不能宣称下载通过 | 已接入，下载验证待完成 |
| 夸克网盘 | 已实现 | 已完成一个匿名样例的手机完整下载，仍需要匿名会话 Cookie | 已接入 |
| 阿里云盘 | 已实现，experimental | 需要阿里云盘账号 access_token，或账号 refresh_token 换取 | 未公开接入 |

“匿名”指无需用户账号，不表示请求完全不需要 Cookie。有效直链、账号会员状态都不保证不限速、不保证大文件权限，也不绕过服务端风控。取链成功与完整下载成功是不同的验证层次。

当前解析器会翻页并遍历子目录，返回可下载文件的扁平列表。`file.name` 保持文件名，`file.extra['relativePath']` 用于展示目录层级。自动测试覆盖多页、多目录和同名文件；没有用超大真实分享验证整个目录树。

## Dart 库

开发环境要求 Dart SDK `^3.6.0`。源码直接引用示例：

```yaml
dependencies:
  netdisk_direct:
    path: ../clipisle-netdisk-plugin
```

```dart
import 'package:netdisk_direct/netdisk_direct.dart';

Future<void> downloadShare(String input, String targetPath) async {
  final client = NetdiskClient();
  final downloader = Downloader();
  const credential = NetdiskCredential.none();
  try {
    final source = client.detect(input);
    final share = await client.parseLink(source, credential: credential);
    final file = share.downloadableFiles.first;
    final direct = await client.resolveDownloadFrom(
      source, file, credential: credential,
    );
    await downloader.download(
      direct,
      targetPath: targetPath,
      onRefreshLink: () => client.resolveDownloadFrom(
        source, file, credential: credential,
      ),
    );
  } finally {
    downloader.close();
    client.close();
  }
}
```

这个示例选择第一个文件；需要登录的平台应提供 `NetdiskCredential(cookie: ...)` 或账号 token。批量获取可用 `resolveAll()`，每个结果独立保留错误。调用其他下载器时也要使用 `NetdiskDownloadLink.headers`，仅复制 URL 可能得到 403/412。

跨 client 或进程恢复时，要在私有存储保留 `ParsedShareLink` 的提取码上下文以及文件的 ID、父目录和必要 extra。夸克会重新列父目录刷新与当前会话绑定的文件 token；不能直接使用旧会话的 `share_fid_token`。不要把凭证、带签名直链或私有上下文写入公开日志。

### 命令行

```sh
dart pub get
dart run bin/netdisk.dart info "<分享文本>"
dart run bin/netdisk.dart links "<分享文本>"
dart run bin/netdisk.dart get "<分享文本>" -o ./downloads
```

凭证从进程环境读取：

| 环境变量 | 用途 |
| --- | --- |
| `NETDISK_BAIDU_COOKIE` | 百度账号 Cookie，取链使用 |
| `NETDISK_QUARK_COOKIE` | 夸克账号 Cookie，可选，不能保证解除下载限制 |
| `NETDISK_ALIYUN_ACCESS` | 阿里云盘账号 access_token |
| `NETDISK_ALIYUN_REFRESH` | 阿里云盘账号 refresh_token |

请用本机的安全方式注入环境，不要把真实值提交到脚本或仓库。CLI 的 `info`/`links` 会输出分享元数据，`links` 还会输出临时下载 URL；这些输出也应按私有数据处理。CLI 会清理远端文件名，并对重名文件分配后缀；它不会自动还原整个目录树到磁盘。

如运行环境需要代理，可注入自己配置的 `HttpClient`。本轮 Windows 真实验证显式使用了遵循环境代理的 `IOClient`；这不是所有部署环境的网络保证。

## 独立 Android 插件

插件源码位于 `plugin/`，包名 `com.clipisle.netdiskplugin`，最低 Android 8.0（API 26）。它通过 Android Service/Messenger 与 ClipIsle 通信，并由宿主展示声明式文件选择与账号页面。网页登录在插件自己的 WebView 中进行。

宿主必须包含新版插件协议实现：

1. 输入匹配支持 `scheme`、精确 `host` 和 `pathPrefix`，不能把所有 HTTPS 链接都交给网盘插件。
2. `parseInput` 返回文件选择页，`prepareDownloads` 返回 `downloads` 描述符；描述符包含不透明 `resourceId`，不把临时直链当作长期任务身份。
3. 下载真正开始、重试或恢复时，宿主调用插件 `resolveDownload` 获取当前下载链接和必要请求头，并将任务接入宿主下载管理器。
4. 任务持久化保留资源身份；签名 URL、下载 Cookie 和 mirrors/headers 不落盘。必要下载会话只通过受信 IPC 交给宿主内存，仅向下载地址最初的 HTTPS origin 发送。

协议仍标记 API 1，但宿主还必须支持上述新增输入与下载描述符行为；不能据此认定所有旧宿主兼容。旧宿主即使能发现 APK，也可能不识别网盘输入、文件列表或下载描述符。

在 Redmi K50 / Android 14 上，MIUI 曾拦截后台绑定插件服务。当前通过透明激活页面预热服务后再绑定，已经完成实机下载链路。首次宿主签名授权仍保留，后续下载不逐次弹出确认。

账号凭证由插件通过 Android Keystore 支持的加密私有存储保存。必要下载 Cookie 可能通过受信 IPC 提供给宿主下载内存，因此不能声称 Cookie 永远不离开插件。插件注销与 WebView Cookie 清理的行为仍需按具体版本验收。

构建调试包：

```sh
cd plugin
flutter pub get
flutter test
flutter build apk --debug
```

发布构建使用本地签名配置，不应提交 `key.properties`、私钥或 keystore。根目录的 Dart 测试不能替代 APK 构建、网页登录、受信 IPC 与手机真实下载验收。

## 接口流程

这些是当前实现采用的非开放网页接口，服务端可能改变。错误响应只能说明一次请求的结果，不能据此承诺接口长期可用。

### 百度

优先使用 `share/wxlist` 匿名列目录并翻页；结构不兼容时尝试网页分享流程。带提取码的网页流程包括 `share/init`、`share/verify`、分享页上下文和 `share/list`，并保留验证响应中的 `BDCLND`。

取链使用有效账号 Cookie 和分享上下文调用 `api/sharedownload`；返回下载链接携带下载所需的 UA/Referer。匿名能列目录不等于匿名能取原文件链接。本轮已在 Redmi K50 / Android 14 完成官方百度网页登录，匿名与登录目录均成功。真实 WX 取链返回 `9019`；网页 fallback 曾返回 `errno=0` 却没有 dlink，未取得可用链接，尚未完成百度下载。官方分享访问验证恢复入口已实现并有控制器回归覆盖，真机已打开对应官方分享页并返回，取链依然返回 9019。

### 夸克

```text
POST drive-pc.quark.cn/1/clouddrive/share/sharepage/token
GET  drive-pc.quark.cn/1/clouddrive/share/sharepage/detail
POST drive-pc.quark.cn/1/clouddrive/file/download
```

请求携带分享 ID、提取码、stoken 和从目录列表取得的文件 token。目录按页遍历；相同会话的 Cookie 必须贯穿 API 与下载。真实匿名样例中，缺少匿名 Cookie 的 Range 请求返回 412，保留 `__pugs`/`__sdid` 后返回 206。早期 Dart probe 只读取了 1 字节；后续 Redmi K50 / Android 14 已匿名完整落盘 7,332,941 字节，ZIP 共 36 项 CRC 校验通过，宿主下载进度可见。该样例不代表大文件、会员速度或所有分享均已验收。

不要仅依据第三方文字把下载端点改成 `share/sharepage/download`：本轮该路径在两个 Quark API 域名均返回 404，实际采用的 `file/download` 路径成功取得链接。

### 阿里云盘（experimental）

```text
POST api.alipan.com/v2/share_link/get_share_token
POST api.alipan.com/adrive/v3/file/list
POST auth.alipan.com/v2/account/token                 # 需要刷新账号 token 时
POST api.alipan.com/v2/file/get_share_link_download_url
```

列目录携带 `x-share-token` 并跟随 `next_marker`；下载另外需要账号 `Authorization`，读取 `download_url`。账号 token 与开放平台 OAuth token 不可混用。当前没有真实账号验证刷新、下载权限或 refresh_token 轮换，因此不在 Android 插件中提供此平台。

## 下载器与错误

库内 `Downloader` 提供周期速度采样、无进度超时、有限重试、刷新链接回调、取消与断点续传。续传依据 Range 响应以及 ETag/Last-Modified 校验；服务端缺少可用内容标识时从头下载。它还检查响应范围、提前截断和目标文件冲突，避免把异常响应拼接进旧文件。

`NetdiskException.code` 可区分 `passwordRequired`、`passwordWrong`、`loginRequired`、`credentialExpired`、`shareNotFound`、`sizeLimitExceeded`、`rateLimited`、`emptyShare`、`network` 和 `badResponse` 等情况。`sizeLimitExceeded` 表示当前服务端限制，不等于登录或开通会员必定解决。

## 验证与限制

```sh
dart analyze
dart test
cd plugin
flutter analyze
flutter test
```

本轮根库 131 项、插件 19 项、宿主 1,286 项自动测试通过，对应静态分析均无问题。测试覆盖分页/递归、凭证与提取码传递、夸克会话绑定及新 client 恢复、错误映射、下载停滞/取消/续传和插件控制器。

真机已确认签名插件安装、发现、启用、授权、官方百度登录与目录，以及夸克匿名完整下载。暂停/恢复、停用/卸载等边界属于自动回归范围，未全部完成真机验收；百度下载仍待解决。详见 [审查与验证记录](docs/review-and-verification.md) 和 [接口探测记录](docs/api-probe-log.md)。

目前没有夸克转存后下载实现，没有针对所有账号和会员等级的验证，也没有真实大文件完整下载、吞吐或多 IP 风控保证。平台协议变动可能需要更新解析器。

## 参考与许可证

本仓库按 [MIT License](LICENSE) 提供。审查对照了 [qaiu/netdisk-fast-download 的 QkTool](https://github.com/qaiu/netdisk-fast-download/blob/main/parser/src/main/java/cn/qaiu/parser/impl/QkTool.java) 的夸克接口行为，以及 [AList 的阿里分享驱动](https://github.com/AlistGo/alist/tree/main/drivers/aliyundrive_share) 的账号认证、分页和下载字段；本轮修复与测试独立编写，未复制上游实现。参考项目保留各自许可证；后续若直接复用上游代码，应按其许可证处理。
