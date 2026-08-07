# 执行计划

上游基线：`3f3466a3c4a5d48d7068635f084d0f403c7039d2`（`v3.7.10-31-g3f3466a3c`）。
交付形态：本仓库维护 patch 补丁集，`.references/traefik` 作为工作副本，改完后导出 patch。

---

## 步骤 0：仓库骨架

新建：

```
patches/                       # 按序号命名的 patch 文件
scripts/setup.sh               # clone/更新上游到 .references/traefik 并 checkout 固定 commit
scripts/apply.sh               # git am patches/*.patch
scripts/export.sh              # 从 .references/traefik 导出 patch 回 patches/
scripts/build.sh               # 在 .references/traefik 里 make binary
UPSTREAM                       # 单行：3f3466a3c4a5d48d7068635f084d0f403c7039d2
README.md                      # 用法说明
```

`.references` 已在 `.gitignore` 中，工作副本不入库。

在 `.references/traefik` 里 `git checkout -b appproto-fallback` 作为开发分支，每个功能步骤一个 commit，末尾用 `scripts/export.sh` 导出。

---

## 步骤 1：muxer 层 —— `AppProtocol` 匹配器

**`pkg/muxer/tcp/mux.go`**

1. `ConnData` 增加 `appProto string` 字段，并新增 `WithAppProtocol(appProto string) ConnData` 返回补齐该字段的副本。`NewConnData` 签名不变，因此 router.go / postgres.go / 既有测试的调用点都不需要改。
2. 新增 `(*Muxer) HasAppProtocolMatcher(rule, syntax string) (bool, error)`：按 syntax 选 `m.parser` / `m.parserV2`，`buildTree().ParseMatchers([]string{"AppProtocol"})` 非空即为 true。实现为 `*Muxer` 的方法以复用它持有的 parser；`ParseHostSNI` 那种自建 parser 的写法在这里不合适（v2 parser 不认识 `AppProtocol`，自建 parser 会掩盖"v2 语法下应当报错"这一行为）。

**`pkg/muxer/tcp/matcher.go`**

3. `tcpFuncs` 增加 `"AppProtocol": expect1Parameter(appProtocol)`。
4. 实现 `appProtocol(tree *matchersTree, protos ...string) error`：
   - 校验取值 ∈ {`http/1.1`, `h2`, `unknown`}，否则返回
     `fmt.Errorf("invalid value for AppProtocol matcher, %q is not a valid application protocol", proto)`。
   - `tree.matcher = func(meta ConnData) bool { return meta.appProto == proto }`。
5. `tcpFuncsV2` 不动。

**测试** `pkg/muxer/tcp/matcher_test.go`、`mux_test.go`：新增 `AppProtocol` 的取值校验用例（合法 3 个 / 非法若干）、匹配用例、与 `HostSNI` / `ClientIP` / `ALPN` / `!` 组合的用例、`WithAppProtocol` 用例、`HasAppProtocolMatcher` 用例（含 v2 语法下 `AppProtocol` 报错）。

---

## 步骤 2：协议嗅探

**新建 `pkg/server/router/tcp/appproto.go`**

```go
const (
    AppProtoHTTP1   = "http/1.1"
    AppProtoH2      = "h2"
    AppProtoUnknown = "unknown"

    appProtoSniffTimeout = 500 * time.Millisecond
)

// maxMethodLen 是方法名的字节上限。RFC 9110 不限制方法名长度，但不设上限
// 就无法在有限字节内判定；IANA 已注册的最长方法 UPDATEREDIRECTREF 为 17 字符。
const maxMethodLen = 32

var http2Preface = []byte("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")

// sniffAppProtocol 按握手协商到的 ALPN 分流探测应用层协议，不消费连接字节。
// 返回 error 表示无法判定（超时 / EOF / 读错误）。
func sniffAppProtocol(conn *peekConn, negotiatedProto string) (string, error)
```

**不使用方法白名单**（理由见 design.md §4.1.1）。HTTP/1 的判定是 `net/http` 接受一条请求行的必要条件：`<token>{1,maxMethodLen} SP <VCHAR>`。token 判定直接复用 `golang.org/x/net/http/httpguts.IsTokenRune`——`net/http` 的 `isToken` 就是转发到同一个包（`net/http/http.go:123`），复用它可避免自建字符表与标准库漂移。Traefik 已在 `pkg/middlewares/forwardedheaders` 等处 import `httpguts`，`golang.org/x/net` 已是直接依赖，不新增依赖。

按 design.md §4.1 分流为两个独立的增量 Peek 循环，互斥、无优先级仲裁：

- `negotiatedProto == "h2"` → 只比对 preface 前缀，最多 24 字节。
- `negotiatedProto == "http/1.1"` 或 `""` → 只跑 token 规则，最多 34 字节。
- 其它取值 → 直接返回 `unknown`，不读连接。

在函数注释里写明分流的依据（§4.1.0）：协商结果对连接有约束力，对两种载荷都试会让嗅探路径比未嗅探路径更宽松。

**测试 `pkg/server/router/tcp/appproto_test.go`**：表驱动覆盖

每条用例都带上 `negotiatedProto` 维度。

`negotiatedProto = "http/1.1"` / `""`：

- 经典方法：`GET` / `HEAD` / `POST` / `PUT` / `DELETE` / `CONNECT` / `OPTIONS` / `TRACE` / `PATCH`
- **列表法会漏掉的方法**：`QUERY`、`PROPFIND`、`PROPPATCH`、`MKCOL`、`COPY`、`MOVE`、`LOCK`、`UNLOCK`、`REPORT`、`MKCALENDAR`，以及一个自定义 token 方法（如 `X-FOO`）——这组用例是"不得退回白名单"的哨兵
- 请求目标形态：origin-form `/`、asterisk-form `OPTIONS *`、absolute-form `GET http://...`、authority-form `CONNECT host:443`
- `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n` → 判 `http/1.1`（分流后没有 h2 优先级，与 `net/http` 把它当 HTTP/1.x 请求行解析一致）
- 边界：方法名恰好 32 / 33 字符；`GET` 后跟两个空格（target 为空 → `unknown`）；`GET` 后跟 CTL；方法名含非 tchar（如 `GE(T /`）
- 二进制载荷：首字节 `0x00`、`0x05`、56 字节 hex 后接 CRLF（Trojan 式头部）
- 无法判定：只发 1~3 字节后静默（超时）、握手后立刻 EOF、`GE` 停顿后再补 `T /...`

`negotiatedProto = "h2"`：

- 完整 preface → `h2`
- `GET / HTTP/1.1` → `unknown`（token 规则在此分支不生效，这是分流的哨兵）
- preface 前 23 字节后截断静默 → 无法判定
- 首字节非 `P` → `unknown`，且只 peek 了 1 字节

`negotiatedProto = "acme-tls/1"` 等其它取值 → `unknown`，且不读连接。

---

## 步骤 3：`peekConn` 携带跨阶段数据

**`pkg/server/router/tcp/router.go`**

1. `peekConn` 增加 `tlsState *tls.ConnectionState` 字段与 `TLSState() tls.ConnectionState` 方法。方法名不得叫 `ConnectionState`（见 design.md §5.3），在该方法上写注释记录原因。
   同时新增 `tlsStatefulConn struct{ *peekConn }` 及其 `ConnectionState() tls.ConnectionState`，供协商到 `http/1.1` / `""` 的连接交给 `http.Server` 时使用。两个类型的注释里互相指明"哪条分支用哪个、为什么不能混用"。
2. `peekConn` 增加 `connData *tcpmuxer.ConnData` 字段、未导出接口 `connDataCarrier` 与方法
   `clientHelloConnData() (tcpmuxer.ConnData, bool)`，供第一阶段把 ClientHello 阶段的匹配数据带给第二阶段。
3. 新增构造 `newTLSPeekConn(conn tcp.WriteCloser, state tls.ConnectionState) *peekConn`。
4. `Router.ServeTCP` 在 `tcpmuxer.NewConnData(...)` 成功后（约 174 行）把结果存回 `pConn`。仅此一处赋值；非 TLS 分支与 postgres 分支不受影响。

---

## 步骤 4：第二阶段路由器

**`pkg/server/router/tcp/router.go`**

1. `Router` 增加 `muxerPostTLS tcpmuxer.Muxer`、`tlsHandshakeTimeout time.Duration`；`NewRouter` 里多建一个 muxer。
2. 新增 `AddPostTLSRoute(rule, syntax string, priority int, providerName string, target tcp.Handler) error`
   → `r.muxerPostTLS.AddRoute(...)`。
3. 新增 `postTLSRouter` 处理器：

```go
type postTLSRouter struct {
    router  *Router
    next    tcp.Handler   // httpForwarder
}

func (p *postTLSRouter) ServeTCP(conn tcp.WriteCloser)
```

流程：
- `tlsConn, ok := conn.(*tls.Conn)`；断言失败记 error 日志并关闭（构造侧保证不会发生）。
- 解包取回第一阶段 `ConnData`：`tlsConn.NetConn().(tcp.TLSConn)` → `.WriteCloser.(connDataCarrier)` → `clientHelloConnData()`。任一步失败视为不变量被破坏，记 error 日志并关闭，不做静默回退。
- 设握手 deadline（`r.tlsHandshakeTimeout > 0` 时），`tlsConn.HandshakeContext(context.Background())`；失败按 `Router.ServeTCP` 现有降噪策略（`io.EOF` / `*net.OpError` timeout 走 debug）记日志并关闭。
- `state := tlsConn.ConnectionState()`；`pConn := newTLSPeekConn(tlsConn, state)`。
- 设 `appProtoSniffTimeout` 读 deadline，`sniffAppProtocol(pConn, state.NegotiatedProtocol)`；无论成败随后 `SetDeadline(time.Time{})` 清空。
- 无法判定 → 交给 `p.next`（按下面的包装规则）并 return。
- `handler, _ := p.router.muxerPostTLS.Match(clientHelloConnData.WithAppProtocol(appProto))`；命中则 debug 日志 + `handler.ServeTCP(pConn)`（fallback service 拿裸 `pConn`）。
- 未命中/无法判定时交给 `p.next`，包装类型按协商结果选（design.md §5.3）：
  `state.NegotiatedProtocol == "h2"` → 裸 `pConn`；否则 → `tlsStatefulConn{pConn}`。
  这一处 if 决定了 `net/http` 走 `unencrypted_http2` 还是原生 HTTP/1.x 分支，写注释说明。

4. `SetHTTPSForwarder` 签名改为 `(handler tcp.Handler, tlsHandshakeTimeout time.Duration)`：
   - 存下 `r.tlsHandshakeTimeout`。
   - 若 `r.muxerPostTLS.HasRoutes()`，则 `handler = &postTLSRouter{router: r, next: handler}`，之后原样用于 `hostHTTPTLSConfig` 循环里的 `tcp.TLSHandler` 与 `r.httpsForwarder`。

`Router.ServeTCP`、`servePostgres`、`HTTP3TLSConfigMatcherFunc` 不改（第一阶段行为不变）。

**测试 `pkg/server/router/tcp/router_test.go`**：

- 「HTTP/1.1 请求命中 HTTPS 路径」「非 HTTP 载荷命中 fallback service」「协商到 h2 且载荷为 preface 时不命中 `AppProtocol(unknown)`」「协商到 h2 但载荷是 `GET /` 时命中 `AppProtocol(unknown)`」「无 post-TLS 路由时 handler 链不被包装」。
- **跨阶段数据传递哨兵**：规则 ``ALPN(`h2`) && AppProtocol(`unknown`)``，客户端 ClientHello 提供 `[h2, http/1.1]`，服务端 TLS options 配 `alpnProtocols: ["http/1.1"]` 使其协商到 `http/1.1`，发送非 HTTP 载荷，断言命中。
  服务端只配 `http/1.1` 是这条用例的**必要条件**：`crypto/tls` 的 `negotiateALPN` 是服务端顺序优先，Traefik 默认列表以 `h2` 开头，客户端只要提供 `h2` 就必然协商到 `h2`，那样就构造不出"提供了 h2 但没协商到 h2"的场景。
  该用例锁住"第二阶段复用第一阶段 ConnData"（`ALPN` 匹配的是提供列表而非协商结果）；若有人改回在第二阶段重新构造 `ConnData`，它会立刻失败。

---

## 步骤 5：Manager 分流与校验

**`pkg/server/router/tcp/manager.go`** — `addTCPHandlers` 内，在现有 `ParseHostSNI` 校验之后、`TLS == nil` 分支之前插入分类：

1. `isPostTLS, err := router.muxerPostTLS.HasAppProtocolMatcher(routerConfig.Rule, routerConfig.RuleSyntax)`；解析错误按现有模式 `AddError(err, true)` + 跳过。
2. `isPostTLS` 为真时依次校验（任一失败即 `AddError(..., true)` 并 `continue`）：
   - `routerConfig.TLS == nil` → `AppProtocol matcher requires TLS termination on the router`
   - `routerConfig.TLS.Passthrough` → `AppProtocol matcher cannot be used with TLS passthrough`
   - `routerConfig.TLS.Options != ""` → `TLS options cannot be set on a router using the AppProtocol matcher, they are inherited from the entryPoint HTTPS configuration`
3. 通过后：`handler, err := m.buildTCPHandler(ctxRouter, routerConfig)`（**不**包 `tcp.TLSHandler`），
   `router.AddPostTLSRoute(routerConfig.Rule, routerConfig.RuleSyntax, routerConfig.Priority, providerName(routerName), handler)`，然后 `continue`。

注意：这一步必须早于既有的 `HostSNI + TLS == nil` 校验之后、但早于 `muxerTCP`/`muxerTCPTLS` 的注册，避免 post-TLS 路由被注册进第一阶段 muxer。

**测试 `pkg/server/router/tcp/manager_test.go`**：三条校验各一个用例，外加正常注册用例、以及"post-TLS 路由不得出现在 `muxerTCP` / `muxerTCPTLS` 中"的断言。

---

## 步骤 6：HTTP server 侧改造

**`pkg/server/server_entrypoint_tcp.go`**

1. `newHTTPServer` 保留 `withH2c bool`，新增 `tlsTerminated bool`，改为
   `protocols.SetUnencryptedHTTP2(withH2c || tlsTerminated)`。调用点：明文 server 传 `(true, false)`，
   HTTPS server 传 `(false, true)`，并在 HTTPS 调用处写注释说明原因（承接 post-TLS 嗅探后的明文回放连接）。
2. `ConnContext` 里现有的 `*tls.Conn` 分支之后增加一个分支，覆盖两种嗅探后的包装类型：

```go
// 两条分支都要取 TLSOptionsName；只有 h2 分支（裸 PeekConn）需要把 ConnectionState
// 放进上下文，因为它的 Request.TLS 得由 restoreTLSState 还原。
if pc, ok := tcprouter.AsPeekConn(c); ok {
    if _, isStateful := c.(tcprouter.TLSStatefulConn); !isStateful {
        ctx = tcprouter.AddTLSConnectionStateInContext(ctx, pc.TLSState())
    }
    if tlsConnWithOptionsName, ok := pc.NetConn().(tcp.TLSConn); ok {
        return tcp.AddTLSOptionsNameInContext(ctx, tlsConnWithOptionsName.TLSOptionsName)
    }
}
```

这要求把 `peekConn` / `tlsStatefulConn` 导出为 `PeekConn` / `TLSStatefulConn`，提供 `AsPeekConn(net.Conn) (*PeekConn, bool)` 统一解包，并给 `PeekConn` 加 `NetConn() net.Conn`（返回内嵌的 `tcp.WriteCloser`；注意此处内嵌的是 `*tls.Conn`，取 `TLSOptionsName` 还需再解一层 `NetConn()`）。上下文 key 与读写函数放在 `pkg/server/router/tcp`。

3. `handler` 链最外层（`normalizePath`/`denyFragment` 之后、赋给 `serverHTTP.Handler` 之前）在 `tlsTerminated` 为真时包一层还原器：

```go
func restoreTLSState(next http.Handler) http.Handler {
    return http.HandlerFunc(func(rw http.ResponseWriter, req *http.Request) {
        if state, ok := tcprouter.GetTLSConnectionState(req.Context()); ok {
            req.TLS = state
        }
        next.ServeHTTP(rw, req)
    })
}
```

无条件覆盖 `req.TLS`（不是"仅当为 nil"）：`unencryptedHTTP2Request` 路径下 http2 可能已填入空的 `tls.ConnectionState`。协商到 `http/1.1` / `""` 的连接不会进这个分支——`TLSStatefulConn` 让 `net/http` 原生把 `req.TLS` 填好，上下文里没有值，还原器是空操作。

4. `NewTCPEntryPoint`（约 215 行）与 `SwitchRouter`（约 370 行）里的 `rt.SetHTTPSForwarder(...)` 增加第二参数
   `time.Duration(config.Transport.RespondingTimeouts.ReadTimeout)` / `time.Duration(e.transportConfiguration.RespondingTimeouts.ReadTimeout)`。

**测试**：`pkg/server/server_entrypoint_tcp_test.go` 增加端到端用例，构造带 post-TLS 路由的入口点，分别发起：

| 客户端 | 断言 |
| --- | --- |
| HTTP/1.1（ALPN `http/1.1`） | 走 HTTP handler，`r.ProtoMajor == 1`，`r.TLS != nil` 且字段来自真实握手（校验 `ServerName` / `NegotiatedProtocol` / `Version`） |
| HTTP/2（`http.Transport` + ALPN h2） | 走 HTTP handler，`r.ProtoMajor == 2`，`r.TLS != nil` 且字段同上 |
| ALPN `http/1.1` + 原始二进制载荷 | 到达 fallback service，收到的首字节与发送一致（验证回放） |
| ALPN `h2` + 原始二进制载荷 | 到达 fallback service |

第二行是 `unencrypted_http2` 通道的回归哨兵，第一行是 `TLSStatefulConn` 原生分支的哨兵；两者都要断言 `r.TLS` 的具体字段而非仅非 nil。

---

## 步骤 7：集成测试

`integration/` 下新增 `appproto_test.go` + `integration/fixtures/appproto/simple.toml`：

- 起一个 echo TCP 后端与一个 whoami HTTP 后端。
- 用例 1：`curl --http1.1 https://...` → whoami 响应，`X-Forwarded-Proto: https`（`r.TLS` 由 `TLSStatefulConn` 原生填好）。
- 用例 2：`curl --http2 https://...` → whoami 响应，HTTP/2，`X-Forwarded-Proto: https`（`r.TLS` 由 `restoreTLSState` 还原）。
- 用例 3：ALPN `http/1.1`，握手后直接写入 `"hello\n"` → 收到 echo 后端的回显。
- 用例 4：ALPN `h2`，握手后直接写入 `"hello\n"` → 收到 echo 后端的回显（h2 分支的 `unknown` 判定）。
- 用例 5：`curl -X PROPFIND --http1.1 https://...` → whoami 响应，**不**落到 echo 后端（token 规则的集成级哨兵）。
- 用例 6：TLS 握手后不发数据，600ms 后发合法 HTTP 请求 → 走 HTTP 路径（验证"无法判定"回退）。

按 `integration/integration_test.go` 的 `testify/suite` 惯例注册。

---

## 步骤 8：文档

- `docs/content/reference/routing-configuration/tcp/routing/rules-and-priority.md`：在 matcher 表格中加入 `AppProtocol`，说明
  - 按协商到的 ALPN 分流的判定表，以及"让客户端协商 h2 可使判定精确"这条建议（含服务端顺序优先、默认列表以 `h2` 开头这个前提）；
  - `http/1.1` 分支的判定规则 `<token>{1,32} SP <VCHAR>`，明确它覆盖 `QUERY` / WebDAV / 自定义方法而非固定白名单；
  - `unknown` 的单向保证：判为 `unknown` 则 HTTP server 本来也会拒绝，反向不成立；
  - 500ms 超时回退、`tls.options` 不可设置；
  - design.md §5.4 的残留行为差异。
- 同目录/相关页补一个完整的 fallback 配置示例（file / CRD / label 三种，取自 api.md §1）。
- 若 `docs/content/reference/dynamic-configuration/*` 有 TCP 路由规则的枚举说明，同步更新。

`make docs-serve` 本地预览确认。

---

## 步骤 9：校验与导出

```bash
make generate            # 确认无生成物变更（本改动不涉及 deepcopy / CRD）
make fmt
make lint
make validate-files
make test-unit
make test-integration TESTFLAGS="-run TestAppProto"
```

全绿后 `scripts/export.sh` 导出 patch 到 `patches/`，README 记录基线 commit 与应用方式。

---

## 变更文件清单

| 文件 | 变更 |
| --- | --- |
| `pkg/muxer/tcp/mux.go` | `ConnData.appProto`；`WithAppProtocol`；`HasAppProtocolMatcher` |
| `pkg/muxer/tcp/matcher.go` | `AppProtocol` 匹配器 |
| `pkg/server/router/tcp/appproto.go` | 新增，嗅探实现 |
| `pkg/server/router/tcp/router.go` | `muxerPostTLS`、`AddPostTLSRoute`、`postTLSRouter`、`PeekConn` / `TLSStatefulConn` 导出与 `TLSState` / `clientHelloConnData` / `AsPeekConn`、`SetHTTPSForwarder` 签名、TLS 状态上下文 |
| `pkg/server/router/tcp/manager.go` | post-TLS 路由分类与校验 |
| `pkg/server/server_entrypoint_tcp.go` | `unencryptedHTTP2` / `tlsTerminated` 参数、`ConnContext` 分支、`restoreTLSState`、`SetHTTPSForwarder` 调用点 |
| `integration/appproto_test.go` + fixture | 新增 |
| `docs/content/reference/routing-configuration/tcp/routing/rules-and-priority.md` | 新匹配器文档 |
| 各 `*_test.go` | 单元测试 |

## 风险点

1. **`unencrypted_http2` 依赖 Go 标准库行为**：`http.Server.Protocols` + `TLSNextProto["unencrypted_http2"]` 是导出 API，但"h2 preface 检测被 `c.tlsState == nil` 门控"是 `net/http` 内部实现细节。风险面已被 §5.3 的分流收窄到只有协商到 `h2` 的连接；步骤 6 的端到端测试必须覆盖 HTTP/2，Go 版本升级时该测试是回归哨兵。
2. **`PeekConn` 不得实现 `ConnectionState() tls.ConnectionState`**：一旦加上，h2 分支会静默降级到 HTTP/1.1。需要这个方法的场景由独立的 `TLSStatefulConn` 承担，两个类型的注释互相指明。
3. **握手时机前移**：TLS 握手从 `net/http` 挪到 `postTLSRouter`，握手失败的日志与超时行为变化仅限配置了 post-TLS 路由的入口点，需在步骤 4 的测试中确认降噪策略与 `Router.ServeTCP` 一致。
4. **跨阶段解包的不变量**：`tlsConn.NetConn().(tcp.TLSConn).WriteCloser.(connDataCarrier)` 依赖"HTTPS 分支上 `tcp.TLSHandler` 是唯一中间包装层"。断言的是接口而非具体类型，未来插入的包装层转发 `clientHelloConnData()` 即可；步骤 4 的 `ALPN(\`h2\`) && AppProtocol(\`unknown\`)` 用例是这条不变量的哨兵。
