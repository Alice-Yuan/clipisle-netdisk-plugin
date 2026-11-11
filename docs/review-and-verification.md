# 审查与验证记录

记录日期：2026-11-11。公开仓库 [Alice-Yuan/clipisle-netdisk-plugin](https://github.com/Alice-Yuan/clipisle-netdisk-plugin) 已创建。版本 v0.1.1，安装包与插件清单见 [Release](https://github.com/Alice-Yuan/clipisle-netdisk-plugin/releases/tag/v0.1.1)。

本文只记录可公开的技术结论。真实分享 URL、提取码、文件名、Cookie、账号 token 和下载签名没有写入本文或测试 fixture。

## 早期问题与本轮修正

| 问题 | 修正 | 验证范围 |
| --- | --- | --- |
| README 声称百度无 Cookie 无法解析，并在 parse 前直接拒绝 | 百度优先匿名 `share/wxlist`，支持提取码、分页、递归及网页流程兼容 | 解析器自动测试；匿名真实结果以探测记录为准 |
| 夸克只返回第一个找到文件的目录，忽略根文件旁的子目录，超过 50 条不翻页 | 遍历全部目录、跟随页码并检测重复页，保留 relativePath 与父目录 | 多页、混合根目录、同名文件 fixture |
| 夸克 API 返回 URL 后直接使用，遗漏匿名 Cookie | 每次操作保持独立 Cookie 会话，下载提供相应会话请求头 | 真实 Range 请求从 412 变为 206，只读 1 字节 |
| 夸克 resolve 重新获取 token，旧文件 token 与新访客 Cookie 不匹配 | 同 parser 复用私有上下文；新 client 或切换账号时重新列父目录刷新文件 token | 真实 Dart Range；跨 client 序列化子目录文件 fixture |
| 夸克缺少真实提取码错误码映射 | 增加 41008 缺码、41007 错码；保留已有错误兼容 | 授权样例 token 请求及模拟回归 |
| 阿里误用带 adrive 前缀的下载路径和 OAuth 刷新路径 | 使用账号刷新 `/v2/account/token` 和 `/v2/file/get_share_link_download_url` | 主来源接口核对及模拟测试 |
| 阿里下载没有 Authorization、未读取 download_url、不翻 marker | 接入账号 token，读取下载字段，分页并遍历目录 | 模拟测试；真实账号下载未验证 |
| NetdiskClient 默认创建两套 HTTP 客户端，close 不能关闭实际解析连接 | 默认解析器与 client 共用同一 HTTP transport | 根库自动回归通过 |
| 下载续传和重试缺少充分的响应/取消边界保护 | 加强 Range/验证器/长度、目标路径、取消、重定向和刷新边界 | 自动回归通过；不是全部边界的真机验收 |
| 插件恢复文件未保存 parentId | 私有资源存储保留 parentId；夸克额外支持 extra.pdir_fid | 解析器与控制器跨 client fixture |
| 旧文档将错误响应或端点可达写成已完成真实下载 | 文档区分自动测试、元数据请求、Range 请求、完整下载和手机验收 | 本文件及修订后的探测日志 |

## 验证分层

### 自动测试

本轮集成检查结果：

| 范围 | 自动测试 | 静态分析 |
| --- | --- | --- |
| 根目录 Dart 库 | 131 项通过 | 无问题 |
| 独立 Flutter 插件 | 19 项通过 | 无问题 |
| ClipIsle 宿主 | 1,286 项通过 | 无问题 |

根库执行 `dart test` / `dart analyze`，插件与宿主执行各自的 `flutter test` / `flutter analyze`。这些数字记录本轮运行结果，不是长期固定的测试总数。官方百度分享访问验证入口属于已实现且有控制器测试覆盖的功能；不能把这项覆盖写成真机验证入口已经成功走通。

测试重点包括：完整分页和目录覆盖、同名文件展示路径、错误映射、账号凭证隔离、匿名 Cookie 传播、过期文件 token 刷新，以及序列化后用新 parser 解析子目录文件。所有分享、Cookie、token 和下载 URL fixture 均为虚构数据。

### 真实网络验证

授权夸克样例完成 token、detail、download metadata，再对下载地址发送 `Range: bytes=0-0`。最终修后 Dart 解析器返回：

```text
files=1
cookie=true
rangeStatus=206
bytesRead=1
```

该早期结果仅证明首字节可下载。最初仅复制 URL 的请求返回 412；保留 API 下发的匿名 Cookie 后成功。后续真机匿名完整下载的结果单独记录在下一节，不能从这次 Range probe 推导所有分享、账号权限、会员速度或有效期上限。

Windows 环境中，真实 Dart probe 显式注入使用 `HttpClient.findProxyFromEnvironment` 的 `IOClient`。未把此环境结果写成“无代理直连”。临时脚本不含真实链接常量，链接经临时进程环境注入，执行后清理。

百度已有真实官方网页登录和目录验证，但取链仍失败；阿里没有真实账号 token 与完整下载验证。不能把登录成功、errno=0 或模拟测试成功计作原文件下载成功。

### Android 与宿主验收

设备：Redmi K50，Android 14。以下仅列已经观测到的结果：

| 真机项目 | 观测结果 |
| --- | --- |
| 插件签名安装、发现、启用、宿主授权 | 已完成 |
| 官方百度网页登录 | 已完成 |
| 百度匿名目录、登录后的目录 | 均成功 |
| 百度原文件取链 | WX 返回 9019；网页 fallback 一次返回 errno=0 但无 dlink，最终重试仍为 9019，完整下载未通过 |
| 夸克匿名完整下载 | 7,332,941 字节落盘；ZIP 36 项 CRC 全部通过 |
| 宿主下载进度 | 夸克下载中可见 |
| 任务持久化隐私 | 检查未发现 Cookie 或签名下载 URL 落入任务 |
| MIUI 后台插件绑定 | 通过透明激活预热服务后绑定修复，不逐次弹下载确认 |

官方百度分享验证入口已接入控制器；真机已打开对应官方分享页并返回，取链依然返回 9019，验证入口通过不等于下载通过。账号凭证加密保留在插件私有存储；API 1 的新版宿主按 resourceId 调用 resolveDownload，原始账号凭证不持久化到宿主任务。

下列项目主要由自动回归覆盖，尚不能写成已经完成真机验收：暂停/恢复、取消竞态、错误提取码恢复、失效凭证、跨进程重启、插件停用/卸载，以及所有 WebView Cookie 清理边界。百度实际下载仍未通过。

## 隐私与协议边界

账号 Cookie 加密保存在插件私有存储；提取码和文件解析上下文也保留在插件私有资源记录。宿主持久化任务身份使用不透明 resourceId。

必要签名 URL 和下载会话 Cookie 可以通过已授权 IPC 交给宿主下载内存；它们不应进入任务落盘 headers、mirrors、公开日志或备份。请求头仅向下载初始 HTTPS origin 发送，不应随跨 origin 跳转泄露。因此“凭证保存在插件”不等于“下载 Cookie 永远不会传给宿主”。

库使用者直接拿到 NetdiskDownloadLink 时也承担同样的请求头与日志管理责任。仅打印 URL 或过滤 Cookie 的日志并不能证明所有其他调用路径都没有敏感信息。

## 仍未完成的验证

1. 百度真实账号原文件取链与下载；当前登录与目录成功不代表下载通过。
2. 夸克真实登录账号、大文件及转存后下载；转存流程当前未实现。
3. 阿里真实账号刷新、refresh_token 轮换、过期重试及原文件下载；因此保持库级 experimental。
4. 长时间大文件下载、实际吞吐、真实服务端 Range/ETag 变化与多 IP 频控。
5. 所有平台下载 URL 的真实有效期；不能采用固定经验值作为服务端保证。

## 主来源

- [QkTool](https://github.com/qaiu/netdisk-fast-download/blob/main/parser/src/main/java/cn/qaiu/parser/impl/QkTool.java)：核对夸克接口路径和下载限制行为。
- [AList 阿里分享驱动 driver.go](https://github.com/AlistGo/alist/blob/main/drivers/aliyundrive_share/driver.go)：核对账号授权下载路径与 download_url。
- [AList 阿里分享驱动 util.go](https://github.com/AlistGo/alist/blob/main/drivers/aliyundrive_share/util.go)：核对账号刷新、x-share-token 与 marker 分页。

这些是第三方实现的主来源，不是网盘官方服务承诺。本轮仅交叉核对接口行为，未复制上游实现；本仓库 MIT 许可证不改变上游许可。

## 发布核验

v0.1.1 已公开发布一个独立签名 APK 和 `clipisle-plugin.json`。GitHub API 的资产 SHA-256 与本地签名包一致。手机当前网络从 GitHub 读取 Release 超时，桌面匿名 API 也遇到限流；本轮通过 ADB 安装同一产物完成真机验收，不将 GitHub 端到端安装记为通过。这与百度取链的 9019 是不同链路的问题。

## 仓库命名统一

插件仓库采用 `clipisle-<能力>-plugin`，本仓库为 `clipisle-netdisk-plugin`，与 `clipisle-bt-plugin` 一致。0.1.1 更新宿主安装入口、编译后插件来源及 Release 清单，继续使用原插件 ID、包名和签名。下载实现和此前百度验收限制不变。
