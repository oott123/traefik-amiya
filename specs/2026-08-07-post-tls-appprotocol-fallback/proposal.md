# 需求：TLS 解密后按应用层协议特征回退到 TCP 后端

## 原始需求

为 traefik（代码在 `.references` 下）加入一个新功能，使得用户可以配置一种特殊的 TCP 后端（fallback）规则。当 TLS 连接进入、解密后，如果检测到 payload 不是 HTTP1/2 协议，则将流量转发到该后端。类似当前的 ALPN(`h2`) 这样的规则，只是匹配内容为解密后的协议特征。

先看看能不能通过插件实现；不行的话就改源码。

## 调研结论：插件无法实现

1. `pkg/plugins/types.go` 只定义了 `middleware`（HTTP）与 `provider` 两种插件类型，没有 TCP 层插件。
2. TCP 中间件的构造函数 `pkg/server/middleware/tcp/middlewares.go:buildConstructor` 硬编码了 InFlightConn / IPAllowList / IPWhiteList 三种，没有任何插件挂载点。
3. 即使用 HTTP 插件也无效：非 HTTP 字节流会先被 `net/http` 解析失败并以 400 关闭连接，中间件根本不会被调用。

因此改源码。

## 澄清后的决策

| 决策点 | 结论 |
| --- | --- |
| 交付形态 | patch 补丁集：本仓库维护 patch 文件 + 应用脚本，针对上游固定 commit 打补丁构建 |
| 上游基线 | `3f3466a3c4a5d48d7068635f084d0f403c7039d2`（`v3.7.10-31-g3f3466a3c`，2026-08-04），Go 1.26 |
| 匹配器命名 | `AppProtocol`，取值 `http/1.1` \| `h2` \| `unknown` |
| HTTP/2 | 必须继续支持。不接受"ALPN=h2 的连接跳过嗅探"这种妥协，也不接受绕开 `http.Server` 自行调用 x/net/http2 |
| 嗅探超时 | 硬编码常量，不暴露配置 |
| 匹配器组合 | 一条路由可以同时依赖 `ALPN` 与 `AppProtocol`，现有 TCP 匹配器全部可与新匹配器自由组合 |
| HTTP/1 判定 | 不用方法白名单，用 RFC 9110 的 `extension-method = token`，与 `net/http` 的 `validMethod` 对齐，覆盖 `QUERY` / WebDAV / 自定义方法 |
| 嗅探分流 | 按握手协商到的 ALPN 分流：`h2` 只认 preface，`http/1.1` / `""` 只跑 token 规则 |

## HTTP/2 约束与解法

`net/http` 只有在 `conn.rwc` 是真正的 `*tls.Conn` 时才会走 ALPN h2 分支；一旦从解密流里读走字节做嗅探，就必须包一层回放 wrapper，该断言随之失效。

解法是复用 Go 1.24+ 为 h2c 引入的 `unencrypted_http2` 通道：在 HTTPS 侧的 `http.Server` 上打开 `Protocols.SetUnencryptedHTTP2(true)`，嗅探后把回放 wrapper（明文流）交给它，`net/http` 会自行识别 h2 preface 并转交给内建的 http2 实现，`http.Server.HTTP2Config`、`ConnState`、`ConnContext` 全部照常生效。对未被嗅探的连接（未配置 fallback 路由的入口点）该开关是空操作，因为真 `*tls.Conn` 永远不会走到那个分支。

按协商到的 ALPN 分流之后，这条非标准通道只服务协商到 `h2` 的连接；协商到 `http/1.1` 或无 ALPN 的连接改用一个实现了 `ConnectionState()` 的 wrapper，走 `net/http` 原生的 HTTP/1.x 分支，`Request.TLS` 也由它原生填好。只有 h2 那条路的 `Request.TLS` 需要 Traefik 从连接上下文恢复。详见 `design.md` §5。

## 实现落地后的补充说明

以下是执行过程中相对 `design.md` / `api.md` 的偏离，均已在代码中体现：

| 项 | 说明 |
| --- | --- |
| `AppProto*` 常量的归属 | 取值域常量定义在 `pkg/muxer/tcp`（匹配器所在包，依赖方向要求），`pkg/server/router/tcp/appproto.go` 里以别名转发，避免两处字面量漂移 |
| 嗅探超时的实现 | 用 `SetDeadline`（读写一起）而非仅读 deadline，与 `Router.ServeTCP` 现有写法一致 |
| post-TLS 校验的相对顺序 | 新校验位于既有 `maxUserPriority` 检查之后。因此 ``HostSNI(`x`) && AppProtocol(`unknown`)`` 且未设 `tls` 时，报的是既有的 "has HostSNI matcher, but no TLS on router"；只有不含 `HostSNI` 的规则才会看到 `AppProtocol matcher requires TLS termination on the router` |
| 文档中的判定表 | 改为无序列表而非表格，避免 `go generate` 给它生成 `opt-h2` / `opt-h2-2` 这类无意义锚点 |
| 集成测试 fixture | 新建 compose 工程 `appproto`（whoami + whoamitcp）与 `fixtures/appproto/appproto.test.cert`，SNI 为 `appproto.test` |

### 环境记录

- 上游工作副本的 `GOPROXY` 默认为 `goproxy.io`，它对 `github.com/liquidweb/liquidweb-cli@v0.7.0` 返回的字节与 `go.sum`/`sum.golang.org` 不一致（校验和不匹配）。用 `GOPROXY=https://proxy.golang.org,...` 重新下载即可，与本改动无关。
- `pkg/proxy/fast` 的 `TestNoContentLength` 在基线 commit 上就失败，与本改动无关（已在 `3f3466a3c` 上复现确认）。
- 本机无 Docker，`make test-integration` 未执行；`integration/appproto_test.go` 只做了编译校验。
