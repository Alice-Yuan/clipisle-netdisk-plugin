# ClipIsle 网盘插件

独立安装的 Android APK，通过 Service/Messenger 与 ClipIsle 通信，使用父目录的纯 Dart 解析库。插件提供百度网盘和夸克网盘输入、账号和文件选择；阿里云盘只保留在库中实验，不在插件公开。

公开仓库已创建：[Alice-Yuan/clipisle-netdisk-plugin](https://github.com/Alice-Yuan/clipisle-netdisk-plugin)。当前源码版本为 0.1.1，安装包与插件清单见 [v0.1.1 Release](https://github.com/Alice-Yuan/clipisle-netdisk-plugin/releases/tag/v0.1.1)。

## 宿主要求与下载流程

最低 Android 8.0（API 26）。需要实现新版行为的 API 1 宿主：按精确 host/pathPrefix 匹配输入，接收 prepareDownloads 返回的 downloads 描述符，并在真正下载开始/恢复时以 resourceId 调用 resolveDownload。旧宿主仅能发现 APK，并不代表这些协议行为都受支持。

账号登录和分享上下文保存在插件加密私有存储；下载传输由主应用执行。宿主任务保留不透明 resourceId，原始账号凭证、必要下载 Cookie 和签名 URL 不持久化。下载链接及最小必要会话可经受信 IPC 进入宿主内存，且只向原始 HTTPS origin 发送。

MIUI 曾拦截后台绑定插件服务；当前以透明激活页面预热服务后再绑定。首次宿主签名授权保留，不为每次下载另弹确认。

## 当前验证状态

| 范围 | 结果 |
| --- | --- |
| 根库自动测试 / 静态分析 | 131 项通过 / 无问题 |
| 插件控制器测试 / 静态分析 | 19 项通过 / 无问题 |
| 宿主自动测试 / 静态分析 | 1,286 项通过 / 无问题 |
| Redmi K50 / Android 14 | 签名安装、发现、启用、授权已完成 |
| 官方百度网页登录与目录 | 登录成功；匿名与已登录目录均成功 |
| 百度下载 | WX 取链 9019；网页 fallback 曾 errno=0 但无 dlink，仍未通过 |
| 夸克匿名下载 | 7,332,941 字节完整落盘；ZIP 36 项 CRC 通过，进度可见 |
| 宿主任务隐私检查 | 未发现 Cookie 或签名 URL 落入任务 |

官方百度分享访问验证恢复入口已经实现并有控制器测试覆盖；真机已打开对应官方分享页并返回，取链依然返回 9019。暂停/恢复、取消、插件停用/卸载等边界主要是自动回归结果，尚未全部实机验收。单个夸克样例成功不保证所有分享、大文件权限或会员速度。

## 构建

在 plugin 目录运行：

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

发布构建命令：

```sh
flutter build apk --release --target-platform android-arm64,android-x64
```

发布构建需要本地 android/key.properties 和独立签名密钥，均不得提交。未配置签名时 release 产物不可发布。

完整库说明见 [根目录 README](../README.md)，验收边界与当前失败项见 [审查与验证记录](../docs/review-and-verification.md)。真实分享、提取码、文件名、Cookie、下载签名不得写入公开日志或文档。
