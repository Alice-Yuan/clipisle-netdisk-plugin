# 接口探测记录（已修订）

> 历史警告：本文件早期版本把“收到业务错误”当作成功下载证据，错误宣称百度不能匿名列目录、阿里匿名取链成功，并把阿里 adrive 下载路径的 HTTP 410 空响应判为端点存在。上述结论已撤回。下文替换这些错误记录，保留其修正依据；不要引用旧版本作为平台能力保证。

记录日期：2026-11-11。本文件只输出请求类别、状态和脱敏结论，不保存真实分享 ID、提取码、文件名、账号凭证、下载 URL 或签名。

## 结论适用范围

- 路由返回 JSON 或业务错误，只能证明这次请求得到相应响应；不能单独证明认证方式、参数、返回数据或下载能力正确。
- 元数据解析成功、取得下载 URL、Range 成功与完整下载成功分别记录。
- 后续真机完成了一个约 7.3 MB 夸克匿名文件下载，但没有大文件或测速结论。百度已真实登录并列目录，原文件取链仍失败；阿里没有真实账号 token 验证。
- 本轮 Windows Dart 真实验证使用显式遵循环境代理的 IOClient。旧版“Python urllib 无任何代理”的环境断言没有复核，不再作为证据。

## 夸克：授权样例与会话修正

### 元数据与提取码

| 请求 | 结果 | 能说明什么 |
| --- | --- | --- |
| `POST /1/clouddrive/share/sharepage/token`，正确提取码 | `code=0`，取得 stoken | 该分享在请求时可访问 |
| 同端点，未提供提取码 | `code=41008` | 此样例需要提取码 |
| 同端点，错误提取码 | `code=41007` | 提取码错误映射应覆盖此码 |
| `GET /1/clouddrive/share/sharepage/detail` | `code=0`，一个文件条目 | 此样例目录可列出；不构成大目录递归验证 |
| `POST /1/clouddrive/file/download`，携带 stoken 和文件 token | `code=0`，data 为列表 | 取得了下载 URL，尚不能证明下载请求通过 |

上述主流程使用 `drive-pc.quark.cn` 与解析器的 PC 客户端 UA。目录分页/递归的边界由模拟测试覆盖。

### 下载首字节与后续手机完整下载

| 请求方式 | 结果 |
| --- | --- |
| 使用 URL、UA、Referer，但遗漏匿名会话 Cookie | Range GET 返回 HTTP 412 |
| 用 CookieJar 保留 API 下发的匿名会话 | Range GET 返回 HTTP 206，仅读 1 字节 |
| 修复后的 Dart parser：parse → resolve → GET bytes=0-0 | HTTP 206，仅读 1 字节 |
| Redmi K50 / Android 14，匿名分享经插件加入宿主下载 | 完整落盘 7,332,941 字节；ZIP 36 项 CRC 通过，进度可见 |

匿名 CookieJar 仅观察到 `__pugs`、`__sdid` 两个 Cookie 名称，没有账号登录 Cookie。最终下载所需的 Cookie 必须和生成 URL/文件 token 的会话匹配。

重新换 stoken 而继续使用旧会话取得的文件 token，曾返回 HTTP 403 / `code=41020`。实现现使用私有会话上下文；跨 client/进程或切换账号时重新列父目录刷新文件 token。子目录恢复的自动测试覆盖只保留 extra.pdir_fid 的序列化文件。

### 端点交叉核对

第三方文字中出现的 `/1/clouddrive/share/sharepage/download` 在 `drive-pc.quark.cn` 和 `drive.quark.cn` 的本轮探测均为 HTTP 404。因此没有据此替换实现中实际可用的 `/file/download`。本轮不会把某条第三方接口清单直接写成已支持能力。

`23018` 仍映射为当前下载大小/权限限制；没有真实账号大文件实测，不能推断只要登录或会员就能解除限制。

## 百度：目录与下载应分开

旧日志使用虚构分享、虚构 sign/timestamp 或 fs_id 调用 sharedownload/filemetas，得到 errno 113/-6。此类请求不能推出“任何匿名目录解析都失败”，也不能证明一个正确分享上下文的取链结果。

当前实现优先 `share/wxlist` 匿名列目录，并处理提取码、分页与子目录；结构不兼容时兼容网页分享流程。网页流程可能包括 init、verify、分享页、list，以及补齐签名上下文的请求。

当前原文件下载实现需要登录 Cookie。缺少登录凭证时 resolve 会给出登录提示；parse 不再因为缺少账号 Cookie 而提前拒绝。

后续 Redmi K50 / Android 14 已通过插件官方百度网页登录；匿名与登录后的目录均成功。真实 WX 取链返回 `9019`；网页 fallback 一次返回 `errno=0`，但响应没有 dlink，未取得可用链接，不能把成功码写成可下载。官方分享验证恢复入口已实现，19 项插件控制器测试通过；真机已打开对应官方分享页并返回，取链依然返回 9019。百度完整下载尚未通过。

## 阿里：修正端点及认证结论

旧日志把以下请求的 HTTP 410 空响应视为“正确端点已确认”：

```text
api.alipan.com/adrive/v2/file/get_share_link_download_url
```

这不足以证明路径、参数或匿名下载能力。本轮实现按主来源核对后采用：

| 用途 | 当前采用的接口 | 验证方式 |
| --- | --- | --- |
| 分享 token | `api.alipan.com/v2/share_link/get_share_token` | 代码核对与模拟测试 |
| 分享目录 | `api.alipan.com/adrive/v3/file/list` | x-share-token、next_marker 模拟测试 |
| 账号 token 刷新 | `auth.alipan.com/v2/account/token` | refresh_token 请求模拟测试 |
| 原文件下载 | `api.alipan.com/v2/file/get_share_link_download_url` | Authorization、download_url 模拟测试 |

下载同时需要账号 access_token 与分享 token。开放平台 OAuth token 和这里的账号 token 不应混用。没有真实 token 验证刷新/下载，也没有证明匿名原文件下载，因此该解析器保持库级 experimental，不在 Android 插件里公开。

仍保留 HTTP 410 的兼容错误处理，不再把它描述为已确认的唯一成因或成功证据。

## 上游主来源与证据管理

夸克流程核对 [qaiu/netdisk-fast-download 的 QkTool](https://github.com/qaiu/netdisk-fast-download/blob/main/parser/src/main/java/cn/qaiu/parser/impl/QkTool.java)。阿里下载和认证核对 [AList driver.go](https://github.com/AlistGo/alist/blob/main/drivers/aliyundrive_share/driver.go) 与 [util.go](https://github.com/AlistGo/alist/blob/main/drivers/aliyundrive_share/util.go)。这里只引用接口行为，未复制实现代码；第三方项目许可证保持独立。

真实样例仅用于已授权的本机/手机验证；早期网络 probe 临时文件已经清理。后续手机完整下载仅公开读取量、校验及成败状态，检查未发现 Cookie 或签名 URL 写入宿主任务；不提交原始响应、凭证、分享内容或带签名链接。暂停恢复、停用卸载等自动回归不能当作已经执行的手机步骤。完整验收边界见 [审查与验证记录](review-and-verification.md)。
