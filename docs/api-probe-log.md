# 接口实测记录

本文记录三个平台接口的实际探测结果，作为代码实现与 README 结论的依据。
探测日期：2026-11-11。探测环境：Windows x64，Python urllib 直连，无任何代理。

## 一、阿里云盘：路由枚举

同一组请求只换 host 与 path，用来确定端点归属。判定标准：返回 `{"message":"uri(...) not exist"}`
视为**路由不存在**，返回业务错误（`NotFound.ShareLink` / `ShareLinkTokenInvalid` / 410）视为**路由存在**。

| host | path | 状态码 | 响应 | 判定 |
|---|---|---|---|---|
| api.alipan.com | `/v2/share_link/get_share_token` | 404 | `NotFound.ShareLink` | **存在** |
| api.alipan.com | `/adrive/v2/share_link/get_share_token` | 404 | `uri(...) not exist` | 不存在 |
| api.alipan.com | `/adrive/v1/share_link/get_share_token` | 404 | `uri(...) not exist` | 不存在 |
| api.alipan.com | `/adrive/v3/share_link/get_share_token` | 404 | `uri(...) not exist` | 不存在 |
| api.alipan.com | `/adrive/v3/file/list` | 401 | `ShareLinkTokenInvalid` | **存在** |
| api.alipan.com | `/adrive/v2/file/list_by_anonymous` | 404 | `uri(...) not exist` | 不存在 |
| api.alipan.com | `/adrive/v3/share_link/get_share_by_anonymous` | 404 | `NotFound.ShareLink` | **存在** |
| api.alipan.com | `/adrive/v2/share_link/get_share_by_anonymous` | 404 | `NotFound.ShareLink` | **存在** |
| api.alipan.com | `/adrive/v2/file/get_share_link_download_url` | 410 | 空 body | **存在** |
| api.alipan.com | `/adrive/v3/file/get_share_link_download_url` | 404 | `uri(...) not exist` | 不存在 |
| openapi.alipan.com | 上述所有 `/adrive/*` 与 `/v*/*` | 404 | Spring `{"status":404,"error":"Not Found"}` | 全部不存在 |

结论：
1. 业务接口挂在 `api.alipan.com`，**不是** `openapi.alipan.com`；
2. `share_token` 在**根路径** `/v2/share_link/get_share_token`，不带 `/adrive` 前缀；
3. 其余业务在 `/adrive/v2|v3/...`；
4. `api.aliyundrive.com` 与 `api.alipan.com` 行为一致（旧域名仍可用）。

`get_share_link_download_url` 返回 **410 且无 body**：参数不匹配或 token 无效时是这样，
不是常规 JSON 错误。代码里 `AliyunParser.resolve` 专门判了 `res.status == 410`。

## 二、百度网盘：登录必要性

这一条是整个仓库最重要的结论——百度**没有**免登录直链路径。

```
POST https://pan.baidu.com/api/sharedownload
     ?channel=chunlei&clienttype=0&web=1&app_id=250528&sign=X&timestamp=Y
     form: encrypt=0&product=share&uk=1&primaryid=1&fid_list=[1]
     Referer: https://pan.baidu.com/s/1abc

→ 200 {"errno":113,"request_id":380514744410851778,
       "server_time":1794384131,"show_msg":"验证码签名错误"}
```

```
GET https://pan.baidu.com/rest/2.0/xpan/multimedia?method=filemetas&dlink=1&fsids=[1]
    Referer: https://pan.baidu.com/

→ 400 {"errmsg":"Invalid Bduss","errno":-6,"request_id":380514819188937334}
```

两个接口是社区方案里最常被引用的"免登录"路径，实测都需要登录态。
`errno 113` 的语义是签名/登录态无效，`errno -6` 是 BDUSS 缺失。

静态入口本身可达：

```
GET https://pan.baidu.com/share/tplconfig
    ?fields=sign,timestamp&channel=chunlei&web=1&app_id=250528&clienttype=0&view_mode=1

→ 200 {"errno":-12,"request_id":380486997437478305,"show_msg":"啊哦，链接出错了"}
```

`errno -12` 说明路由存在、只是参数不对（缺 surl 上下文），说明这条能用。
但这只给 `sign`/`timestamp`，不给 `dlink`，所以没有登录态照样出不来直链。

分享页探测：

```
GET https://pan.baidu.com/s/1testtesttest
→ 404 "页面不存在"

POST https://pan.baidu.com/share/verify?surl=testtest&t=1&channel=chunlei&web=1&app_id=250528&clienttype=0
     form: pwd=1234
→ 200 {"errno":105,"err_msg":"","request_id":380505708748123710}
```

`errno 105` = 提取码错误，说明链路活着、参数校验在工作。

代码里 `BaiduParser.parse()` 在 `credential.isEmpty` 时直接抛 `loginRequired`，
**不发任何请求**——既然 100% 会失败，就没必要浪费一次往返和被频控的机会。

## 三、夸克网盘：链路存活

```
POST https://drive-pc.quark.cn/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc
     body: {"pwd_id":"","passcode":""}
→ 404 {"status":404,"code":41006,"message":"分享不存在"}

POST .../token  body: {"pwd_id":"<16位真实id>","passcode":"1234"}
→ 返回 data.stoken
```

`41006` 是"分享不存在"的稳定错误码，用来验证路由存在且校验逻辑生效。

```
GET https://drive-pc.quark.cn/1/clouddrive/share/sharepage/detail
    ?pr=ucpro&fr=pc&pwd_id=test&stoken=x&pdir_fid=0&force=0
    &_page=1&_size=50&_fetch_banner=0&_fetch_share=1&_fetch_total=1
→ 400 {"status":400,"code":14001,"message":"Bad Parameter: [分享链接不存在]"}
```

`14001` 是参数错误（stoken 假），路由存在。

夸克的 UA 必须是 PC 客户端串：

```
Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko)
quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100
Safari/537.36 Channel/pckk_other_ch
```

用普通浏览器 UA 会被判成网页端，直链接口的行为不同。

## 四、交叉验证：参考项目的实现

从 `qaiu/netdisk-fast-download` 的 `parser/src/main/java/cn/qaiu/parser/impl/QkTool.java`
读到的夸克链路，与本仓库实测一致：

```java
TOKEN_URL    = "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/token";
DETAIL_URL   = "https://drive-pc.quark.cn/1/clouddrive/share/sharepage/detail";
DOWNLOAD_URL = "https://drive-pc.quark.cn/1/clouddrive/file/download";
```

它的 `23018` 处理逻辑（`needsTransferFallback` 判 `size limit` / `download file size limit`）
也被采纳进本仓库的错误映射——这是免登录大小上限的稳定症状。

该仓库**没有百度解析器**：对 30+ 个 Java 文件、JS 解析器、配置做 `baidu|pan.baidu|yunpan.baidu`
全量搜索，零命中。所以本仓库的百度实现是按官方接口从零写的，没有可对照的实现。

它的阿里云盘痕迹只留在测试文件里（`JsHttpClientTest.java` 里几处注释提到
`auth.aliyundrive.com/v2/account/token` 与 `alipan.js`），没有生产代码。

## 五、未验证的部分

以下内容**没有**实测，README 里也没写成已支持：

1. 真实分享的完整下载（接口通 ≠ 能下下来，需要用户提供真实链接）；
2. 百度带 Cookie 的完整链路（本机无百度账号 Cookie）；
3. 夸克带 Cookie 的大文件直链（同上）；
4. 阿里云盘 `refresh_token` 换 `access_token`（本机无 token）；
5. 提取码分享的全流程（需要真实带提取码的分享）；
6. 各平台直链的真实有效期（代码里写的是经验值：夸克 1h / 百度 4h / 阿里 4h）；
7. 限速、并发限制、IP 频控阈值。

要补齐这些，需要在有真实凭证的环境里跑一遍。代码结构已经把凭证做成了参数，
`NetdiskCredential` 传进去即可，不需要改实现。
