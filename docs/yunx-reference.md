# YunX 对照与网盘插件 0.1.2

日期：2026-11-11。插件仓库：[clipisle-netdisk-plugin](https://github.com/Alice-Yuan/clipisle-netdisk-plugin)。本文补充上一轮网盘接入验收，记录实际实现、复现范围与仍未通过的项目。

## YunX 的实现与实机对照

检查了 [YunX](https://github.com/CYQawa/YunX) 的 `2381a52960cf6e49c998e79630df9cd97007130d` 提交及官方 [v1.3.1](https://github.com/CYQawa/YunX/releases/tag/v1.3.1)。APK 包名 `com.yunx.app`，versionCode 15，SHA-256 为 `5b729d97e3e038dcc1607c0be0594e2a932db1de52799f02b3bdf059c778a253`，与官方资产信息一致。

- 百度目录使用分享验证与 `xpan/share` JSON 接口。
- 百度下载路径使用账号 Cookie、获取 bdstoken、临时转存、获取个人文件下载地址、清理转存文件。
- 源码中的游客下载平台列表不包含百度；官方 APK 的相关分支也相同。
- 在 Redmi K50 / Android 14 上新装官方 v1.3.1，全程没有登录账号。对用户指定的同一分享，能列出一个文件；点击文件的「下载」后显示「下载需要先登录百度网盘（未登录仅能浏览文件列表）」，没有开始下载。
- 对照测试后已卸载本次临时安装的 YunX，保留 ClipIsle 与原有账号、任务。

这只说明本次官方版本、全新安装状态、同一分享的复现结果，未复现用户此前成功免登录下载的过程，不能扩大成对所有版本或使用状态的结论。

参考源：

- [BaiduResolveRepository.kt](https://github.com/CYQawa/YunX/blob/2381a52960cf6e49c998e79630df9cd97007130d/app/src/main/kotlin/com/yunx/app/data/repository/BaiduResolveRepository.kt)
- [ResolveViewModel.kt](https://github.com/CYQawa/YunX/blob/2381a52960cf6e49c998e79630df9cd97007130d/app/src/main/kotlin/com/yunx/app/ui/viewmodel/ResolveViewModel.kt)
- [QuarkResolveRepository.kt](https://github.com/CYQawa/YunX/blob/2381a52960cf6e49c998e79630df9cd97007130d/app/src/main/kotlin/com/yunx/app/data/repository/QuarkResolveRepository.kt)

本轮独立实现协议适配与测试，没有复制 YunX 的 AGPL 源码，也没有引入其硬编码设备签名或临时转存及清理流程。

## 已实现

### 百度：先尝试访客，再考虑已有账号

1. 移除加入下载队列前的强制登录检查。选择文件后仍由宿主统一排队，插件按需获取下载地址。
2. 每次解析、取链先用独立匿名会话。成功时不读取和发送已保存的账号 Cookie。
3. 只有登录要求、凭据失效、访问验证或当前方式受限时，才检查本机已有有效 BDUSS，最多再尝试一次。有账号不代表保证成功；没有账号不自动弹登录页。网络、密码错误不触发账号重试。
4. `9019` 统一归为访问验证，不能仅因缺少账号 Cookie 就判定为必须登录。
5. WX 的 `tplconfig` 签名阶段或 `sharedownload` 取链阶段返回 `9019`，均允许一次官方网页会话回退。原代码只覆盖后者，签名阶段失败会跳过备用流程。网页再次失败直接返回，不递归重试。
6. 网页返回无法识别的 HTML 时，允许一次 `xpan/share` JSON 获取分享上下文，严格检查分享 ID、用户 ID、文件列表；仍使用网页签名，不混用 WX 签名。
7. 当前分享重新获取 BDCLND；不把旧分享 Cookie 带入新分享。有 BDUSS 且网页缺 bdstoken 时，只读请求一次 token。

### 夸克：账号 Cookie 更新与并发保护

- 服务端更新 `__pus`、`__puus`、`ctoken` 后，成功操作最多通知一次凭据更新；新游客和设备 Cookie 不写入账号存储。
- 匿名会话不产生账号回写。空值、有效 `Max-Age<=0` 或过期 `Expires` 正确删除 Cookie；合法 Max-Age 优先于 Expires。
- Android 加密存储新增原子比较并写入。Activity 与 Service 共用锁，只有当前值仍等于请求开始时的值才保存更新，避免旧请求覆盖新登录或让已退出账号重新出现。
- 未提供原子存储的库调用方继续使用操作内 Cookie，不用非原子的读写模拟。
- 设置页根据真实 BDUSS / `__puus` 是否非空显示登录状态，不再把任意 Cookie 当作已登录。

## 验收

- Dart 解析库：168 项测试通过，静态分析无问题。
- Android 插件 Flutter 层：46 项测试通过，静态分析无问题。覆盖匿名优先、已有账号只重试一次、没有账号不弹登录、密码及网络错误不重试、退出与更新凭据竞争、Cookie 删除和匿名会话隔离。
- Release APK 构建成功，版本 0.1.2 / versionCode 3；签名、编译后插件声明与发布清单检查通过。已安装到 Redmi K50，保留原账号与任务。
- 桌面匿名真实请求：同一百度分享列目录成功。修复前在 `tplconfig` 返回 9019 即退出；修复后确实进入网页流程，但 `websharedownload` 返回 `errno=0`、字符串类型 `list`，未返回可用下载地址，归为当前下载方式受限。因此未取得文件数据，不能记作下载成功。
- 手机百度重试：新插件返回 `sizeLimitExceeded`，日志为 `websharedownload errno=0 listType=string`，任务没有接收到文件字节；真实百度下载仍未通过。原有账号保留，没有以重新登录作为验收前提。
- 手机夸克：0.1.2 新任务于 19:41:34 创建、19:41:54 完成，过程中观察到正在接收数据；完整下载 7,332,941 字节，ZIP 36 项 CRC 全通过，SHA-256 为 `616539943e56b44cd1fa54a53b833cd65eae377d22eb89885ac4af078828df6e`。此前测试文件保留，仅移除我们创建的旧索引后重新下载，未把重复任务去重或旧文件复用计作成功。
- 宿主持久化的这些任务使用不透明资源 URL，未保存下载请求 Cookie 或签名直链。本轮没有修改宿主运行代码。
- 原生存储锁与 CAS 经过代码审查、编译验证；Flutter 用例使用模拟存储验证竞争语义，没有将其写成真机并发压测通过。

真实分享、提取码、文件名、Cookie、签名和下载内容仅用于本地验收，不纳入文档、源码或 Release。
