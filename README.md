# netdisk-direct

网盘分享链接 → 直链 → 下载。只做三个平台：**百度网盘 / 夸克网盘 / 阿里云盘**。

纯 Dart，无 Flutter 依赖，可同时用于命令行、服务端和 Flutter 应用。

```dart
final client = NetdiskClient();
final share = await client.parse('https://pan.quark.cn/s/abc123 提取码: 8x9k');
for (final file in share.downloadableFiles) {
  final link = await client.resolveDownloadFrom(detect, file);
  print('${file.name} -> ${link.url}');
}
```

## 实现状态（不是设计目标，是实测结论）

| 平台 | 免登录解析 | 免登录取直链 | 需要什么 |
|---|---|---|---|
| 夸克网盘 | 可以 | 小文件可以，超限返回 `code 23018` | 大文件需 Cookie |
| 阿里云盘 | 可以 | 可以 | 无需凭证 |
| 百度网盘 | 不行 | 不行 | 必须 `BDUSS` + `STOKEN` |

百度这一条是硬结论，不是偷懒。实测无 Cookie 直接打接口：

```
POST https://pan.baidu.com/api/sharedownload
  → {"errno":113,"show_msg":"验证码签名错误"}

GET  https://pan.baidu.com/rest/2.0/xpan/multimedia?method=filemetas&dlink=1
  → {"errmsg":"Invalid Bduss","errno":-6}
```

所以 `BaiduParser.parse()` 在凭证为空时**直接抛 `loginRequired`，一个请求都不发**，不做无意义的往返。

## 三个平台的真实接口链

全部由本仓库实际请求验证可达，不是抄文档。

### 夸克

```
POST https://drive-pc.quark.cn/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc
     body {"pwd_id":"<shareId>","passcode":"<提取码>"}   → data.stoken
GET  https://drive-pc.quark.cn/1/clouddrive/share/sharepage/detail
     ?pwd_id&stoken&pdir_fid=0&_page=1&_size=50&...      → data.list[]
POST https://drive-pc.quark.cn/1/clouddrive/file/download?pr=ucpro&fr=pc
     body {"fids":["<fid>"],"pwd_id","stoken","fids_token":["<share_fid_token>"]}
                                                          → data[0].download_url
```

要点：
- `share_fid_token` 必须从 detail 响应里带上，否则 download 会拒；
- 根目录常常只有一个文件夹套着文件，`_drillDown` 会自动往下钻（最深 4 层，每层最多 12 个文件夹）；
- 错误码映射：`41006` 分享不存在、`41004` 需提取码、`41001/41002` 提取码错、`31001` Cookie 失效、`23018` 超大小上限。

### 阿里云盘

```
POST https://api.alipan.com/v2/share_link/get_share_token
     body {"share_id":"<id>","share_pwd":"<提取码>"}      → share_token
POST https://api.alipan.com/adrive/v3/file/list
     header x-share-token: <token>
     body {"share_id","parent_file_id":"root","limit":100,...}  → items[]
POST https://api.alipan.com/adrive/v2/file/get_share_link_download_url
     header x-share-token: <token>
     body {"share_id","file_id","expire_sec":14400}       → urls[0]
```

**域名坑**（这条踩过，写进代码注释了）：
- `/v2/share_link/get_share_token` 只在 **`api.alipan.com` / `api.aliyundrive.com`** 的**根路径**下存在，前面**不加** `/adrive` 前缀；
- `/adrive/v2|v3/...` 系列在 `openapi.alipan.com` 上**全部 404**，不要混用；
- `get_share_link_download_url` 参数不对时返回 **HTTP 410 空响应**，没有 JSON body，代码里专门判了这种情况。

路由枚举实测（同一次请求，只换 host/path）：

| 路径 | api.alipan.com | openapi.alipan.com |
|---|---|---|
| `/v2/share_link/get_share_token` | ✅ 存在 | ❌ 404 |
| `/adrive/v3/file/list` | ✅ 存在 | ❌ 404 |
| `/adrive/v3/share_link/get_share_by_anonymous` | ✅ 存在 | ❌ 404 |
| `/adrive/v2/file/get_share_link_download_url` | ✅ 存在 | ❌ 404 |
| `/adrive/v2/file/list_by_anonymous` | ❌ 不存在 | ❌ 不存在 |

### 百度

```
GET  https://pan.baidu.com/share/init?surl=<surl>&channel=chunlei&web=1&app_id=250528
                                                          → Set-Cookie: BAIDUID/STOKEN
POST https://pan.baidu.com/share/verify?surl=<surl>&t=<ts>&...
     form pwd=<提取码>                                     → Set-Cookie: BDCLND=<randsk>
GET  https://pan.baidu.com/s/<surl>
     → HTML 里 window.yunData.setData({shareid,share_uk,sign,timestamp,sekey})
GET  https://pan.baidu.com/share/list?shareid&uk&dir=/&page=1&num=100&sekey
                                                          → list[]
POST https://pan.baidu.com/api/sharedownload?sign&timestamp&channel=chunlei&...
     form encrypt=0&product=share&uk&primaryid&fid_list=[<fs_id>]&extra={"sekey":...}
                                                          → list[0].dlink
```

要点：
- `BDCLND` 必须从 `verify` 的 **Set-Cookie** 里捞，直接拼在后续 Cookie 上，否则带提取码的分享列不出文件；
- `yunData` 从 HTML 里抠，用的是括号配对扫描（`_matchBrace`），不是正则——里面有字符串和转义，正则会被反斜杠带偏；
- `sign` / `timestamp` 页面里偶尔缺，会回落到 `/share/tplconfig?fields=sign,timestamp` 再补一次；
- **dlink 下载时必须用 `User-Agent: pan.baidu.com`**，用浏览器 UA 直接 403。这条在 `BaiduParser.downloadUserAgent` 里，`NetdiskDownloadLink.headers` 会带出去。

## 下载器

`Downloader` 不是简单 `client.send` 循环，针对网盘直链的三个真实毛病：

**1. 速度按墙上时间采样，停流归零。**
很多实现只在收到字节时算速度，流一停就冻在最后一次的值上（显示 `3.1 KB/s` 十几分钟不动）。这里用 `Timer.periodic(500ms)` 独立采样，2 秒没字节就归零。

**2. 无进度看门狗。**
`idleTimeout`（默认 30 秒）内收不到任何字节 → 判定停滞 → 中断并续传重试，而不是被 HTTP 的 `receiveTimeout`（动辄 10 分钟）拖死。

**3. 断点续传 + 内容身份校验。**
`.part` 文件 + `.part.meta` 存 `ETag`/`Last-Modified`。续传前先 `Range: bytes=0-0` 探一次：
- 服务端不支持 Range（返回 200 而非 206）→ 丢弃旧分片从头下；
- `ETag` 变了 → 内容已经不是同一份，丢弃旧分片；
- 旧分片比总量还大 → 丢弃。

不做这一步就会把两份不同内容拼在一起，出来的文件永远是坏的。

直链过期（403 / 404 / 410）会触发 `onRefreshLink` 回调换一条新链继续，网盘直链通常 1–4 小时过期。

## 用法

### 库

```dart
import 'package:netdisk_direct/netdisk_direct.dart';

final client = NetdiskClient();
final link = client.detect(input);          // 认平台 + 抠提取码
final share = await client.parseLink(link, credential: cred);

// 单个
final dl = await client.resolveDownloadFrom(link, share.files.first, credential: cred);

// 批量，并发 3，失败隔离
final results = await client.resolveAll(link, share.downloadableFiles, concurrency: 3);
for (final r in results) {
  if (r.link != null) print('${r.file.name} -> ${r.link!.url}');
  else print('${r.file.name} 失败：${r.error}');
}
```

### 命令行

```sh
dart run bin/netdisk.dart info  "<链接> 提取码: xxxx"
dart run bin/netdisk.dart links "<链接>"
dart run bin/netdisk.dart get   "<链接>" -o ./downloads
```

凭证走环境变量，不进 shell 历史：

```sh
export NETDISK_BAIDU_COOKIE='BDUSS=xxx; STOKEN=yyy'
export NETDISK_QUARK_COOKIE='__pus=xxx; __puus=yyy'
export NETDISK_ALIYUN_REFRESH='xxxxx'
```

### 在 ClipIsle 里接入

这个库是纯 Dart，可以直接作为 ClipIsle 的 dependency：

```yaml
dependencies:
  netdisk_direct:
    path: ../netdisk-direct
```

然后写一个 `PlatformKind` 适配器，把 `NetdiskShare` 转成 ClipIsle 的 `MediaItem`，直链丢给现有的 `DownloadManager`。注意两点：
- ClipIsle 现有下载器**没有**上面说的零速归零和无进度看门狗，接网盘直链前建议先把这两个补上（见 `docs/12-download-speed-diagnosis.md`）；
- 百度必须走 Cookie，ClipIsle 已有的 `SessionStore` 可以直接存。

## 错误码

所有异常是 `NetdiskException`，带稳定的 `NetdiskErrorCode`，不依赖服务端文案。

| code | 含义 | 典型触发 |
|---|---|---|
| `badLink` | 链接格式无法识别 | 输入为空、对文件夹取直链 |
| `unsupportedPlatform` | 不是这三个平台 | 贴了 123pan / 蓝奏云链接 |
| `shareNotFound` | 分享不存在/已取消/过期 | 夸克 41006、阿里 NotFound.ShareLink |
| `passwordRequired` | 需要提取码 | 夸克 41004、百度 errno 12 |
| `passwordWrong` | 提取码错 | 夸克 41001/41002、百度 -9/105 |
| `loginRequired` | 需要登录凭证 | 百度无 Cookie、阿里 401 |
| `credentialExpired` | 凭证失效 | 夸克 31001、阿里 ShareLinkTokenInvalid / 410 |
| `sizeLimitExceeded` | 超免登录大小上限 | 夸克 23018 |
| `emptyShare` | 分享内容为空 | 目录里没有文件 |
| `rateLimited` | 频控 | 429、百度 -62 |
| `network` | 网络层失败 | 超时、连接中断 |
| `badResponse` | 结构不符合预期 | JSON 解析失败、缺字段 |

## 测试

```sh
dart pub get
dart analyze     # 零问题
dart test        # 35 项全过
```

测试用 `MockClient` 打桩，覆盖：
- 三平台的完整接口链（token → list → download）；
- 提取码传递（夸克 `passcode`、阿里 `share_pwd`、百度 `pwd` + `BDCLND`）；
- 错误码映射（41006 / 23018 / 410 / ShareLinkTokenInvalid / errno -6 / -9）；
- 夸克根目录只有文件夹时的自动下钻；
- 下载器：速度采样、403 换链、断点续传保留前缀字节、ETag 变化丢弃分片、取消。

## 已知限制

- **百度**需要用户自己提供 Cookie，本库不实现登录流程（扫码/账号密码）。
- **夸克**免登录直链有大小上限，大文件必须配 Cookie；转存（save + task 轮询）路径未实现。
- **阿里云盘**匿名路径已通；`refresh_token` 换 `access_token` 的代码在 `_accessToken()` 里，但匿名解析不需要它。会员画质判断未做。
- 只取分享**根目录第一层**（夸克会下钻找文件），多级目录的完整递归遍历未实现。
- 直链有效期是各平台的经验值（夸克 1h / 百度 4h / 阿里 4h），实际以服务端为准，过期靠 403 触发换链。
- **没有在任何真实分享上跑过完整下载**——本轮只验证了接口可达性与错误映射。要确认能真下下来，需要你给一个真实分享链接。

## 参考项目

看过的两个：

- [hmjz100/LinkSwift](https://github.com/hmjz100/LinkSwift) — 油猴脚本，前端注入方式取直链，逻辑全在浏览器里跑，靠页面已登录的会话。**没法直接用**：它依赖用户浏览器上下文，服务端/CLI 跑不起来。有用的部分是 `config/*.json` 里的接口清单，拿来对照了百度和夸克的 endpoint。AGPL3。
- [qaiu/netdisk-fast-download](https://github.com/qaiu/netdisk-fast-download) — Java/Vert.x 服务端，覆盖 30+ 网盘。**架构参考价值大于代码复用**：它的 `PanDomainTemplate` 枚举（正则 → 标准 URL → Parser 类）是我这套 `NetdiskParser.match` 的雏形；`QkTool` 的夸克三级链路（token → detail → download）和 `23018` 处理直接对本仓库的夸克实现做了交叉验证。但它**没有百度解析器**（grep 全仓库 `baidu` 零命中），阿里云盘的实现也只剩测试里的注释，所以这两个平台是按官方接口自己写的。

两个项目的许可证不同（AGPL3 / 未标注），本仓库没有复制它们的代码，只参考了接口路径和流程结构。接口路径本身是公开的服务端行为，不属于可版权标的。
