# 设计：TLS 后置协议嗅探路由（AppProtocol）

## 1. 目标

在 TLS 终止之后、把连接交给 HTTP server 之前，嗅探解密流的头部字节，判定应用层协议；命中用户配置的 TCP 路由时，把**解密后的明文流**转发给该路由的 TCP service，否则维持原有 HTTPS 处理路径。

## 2. 现状：连接在 Traefik 中的流转

```
listener.Accept
  └─ trackedConnection            (pkg/server/server_entrypoint_tcp.go)
      └─ tcprouter.Router.ServeTCP (pkg/server/router/tcp/router.go)
          ├─ peekConn 包装         → isPostgres / clientHelloInfo（只 Peek，不消费）
          ├─ muxerTCP     匹配（非 TLS）
          ├─ muxerHTTPS   匹配（按 SNI 选 TLS 配置）→ tcp.TLSHandler
          ├─ muxerTCPTLS  匹配（TCP-TLS 路由 / passthrough）
          └─ httpsForwarder（兜底 404）→ tcp.TLSHandler
                                          └─ tls.Server(TLSConn{...}, cfg)
                                              └─ httpForwarder.ServeTCP  → connChan
                                                  └─ http.Server.Accept → conn.serve
```

关键事实：

- 现有的 muxer 匹配全部发生在 **ClientHello 之后、握手之前**，`ConnData` 只有 `serverName` / `remoteIP` / `alpnProtos`。
- `tcp.TLSHandler.ServeTCP` 只是 `tls.Server(...)` 后立刻交给 `Next`，**握手是懒执行的**，由 `http.Server.conn.serve` 触发。
- TCP 路由的中间件链（`buildTCPHandler`）虽然位于 `TLSHandler` 内侧，但其 `Next` 被固定为该路由自己的 service，无法改投别的后端，也够不到 HTTP handler。

## 3. 整体方案

引入**第二阶段路由**：ClientHello 阶段的匹配完全不变；在 HTTPS 分支的 `tcp.TLSHandler` 与 `httpForwarder` 之间插入一个嗅探处理器 `postTLSRouter`，由它完成握手、嗅探、二次匹配。

```
tcp.TLSHandler
  └─ postTLSRouter.ServeTCP(tlsConn)          ← 新增
      ├─ tlsConn.HandshakeContext(ctx)         显式握手（原本由 net/http 执行）
      ├─ 解包取回第一阶段的 ConnData（见 §4.3）
      ├─ peekConn 包装 tlsConn，按协商到的 ALPN 分流嗅探（§4.1）
      ├─ connData.WithAppProtocol(appProto)
      ├─ muxerPostTLS.Match  → 命中：TCP service（拿到裸 peekConn）
      └─ 未命中/无法判定    → httpForwarder，按 ALPN 决定包装类型（§5.3）：
                              ALPN h2        → 裸 peekConn
                              http/1.1 / ""  → tlsStatefulConn{peekConn}
```

`postTLSRouter` 只在 `Router.SetHTTPSForwarder` 里、且该入口点存在 post-TLS 路由时才被织入。织入点是 `SetHTTPSForwarder`，所以按 SNI 建立的每一个 `hostHTTPTLSConfig` TLSHandler 与兜底 `httpsForwarder` 会一并覆盖。没有配置 post-TLS 路由的入口点，代码路径与现在**逐字节相同**。

TCP-TLS 路由（`muxerTCPTLS`）、passthrough、ACME-TLS/1、HTTP/3(QUIC) 均不参与第二阶段：第一阶段一旦命中它们，连接就归它们处理。

## 4. `AppProtocol` 匹配器

### 4.1 取值

判定按握手结果 `tls.ConnectionState().NegotiatedProtocol` 分流，两个分支互斥：

| 协商到的 ALPN | 判定 | 结果 |
| --- | --- | --- |
| `h2` | 前 24 字节 == `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n` | `h2` |
| `h2` | 否则 | `unknown` |
| `http/1.1` 或 `""` | 形如 `<token>{1,32} SP <VCHAR>` | `http/1.1` |
| `http/1.1` 或 `""` | 否则 | `unknown` |
| 其它 | 不嗅探 | `unknown` |

其它取值在规则解析期报错（严格校验，不做大小写以外的归一化——`rules.Tree.ParseMatchers` 已统一转小写）。

### 4.1.0 为什么按协商到的 ALPN 分流

协商结果对连接**是有约束力的**——未经嗅探的连接就是这么走的（`net/http` `conn.serve`）：

| `NegotiatedProtocol` | `net/http` 的行为 |
| --- | --- |
| `h2` | `TLSNextProto["h2"]` → http2 server，要求 preface，否则 `readPreface` 失败并关闭 |
| `http/1.1` / `""` | 不是 `validNextProto`，落到 HTTP/1.x 分支；因 `c.tlsState != nil`，preface 检测被跳过 |

对两种载荷都试会让嗅探路径**比未嗅探路径更宽松**，等于"配置了 post-TLS 路由就改变了非匹配流量的行为"——这违背了这个特性的边界（§3）。分流后两条路径对齐。

分流还带来一个可操作的结论：**协商到 h2 时 `unknown` 的判定是精确的**，载荷只要不等于那 24 字节即可，误判概率 ~2⁻¹⁹²，而 token 规则是 0.062%（§4.1.3）。浏览器本来就协商 h2，所以让伪装客户端也协商 h2 既是更准的配置、也是更好的伪装。

一个必须知道的前提：`negotiateALPN`（`crypto/tls/handshake_server.go:334`）是**服务端顺序优先**的，Traefik 默认 `ALPNProtocols = ["h2", "http/1.1", "acme-tls/1"]`（`pkg/tls/tlsmanager.go:36`）。因此客户端只要在列表里带上 `h2` 就一定协商到 `h2`，与客户端自己的顺序无关。另外该函数有个 `http11fallback` 特例：服务端只配 `h2`、客户端只给 `http/1.1` 时返回 `""` 而非报错，所以 `""` 不等于"客户端没发 ALPN"，把它与 `http/1.1` 归为一类才是对的。

### 4.1.1 为什么 HTTP/1 用 token 规则而不是方法白名单

这个特性必须守住的不变量是：

> `AppProtocol` 判为 `unknown` ⟹ Traefik 自己的 HTTP server 本来也会拒绝这个请求

判错的两个方向代价极不对称。判错成 `unknown` 会把**合法的 HTTP 请求静默投递到 fallback 后端**，是永久性、静默的破坏；判错成 `http/1.1` 只是让 fallback 载荷收到一个 400 并被关闭，客户端重试即可，且是自限的。

硬编码方法白名单守不住这条不变量。`net/http` 的判定是（`net/http/request.go:844`）：

```go
func validMethod(method string) bool { return isToken(method) }   // extension-method = token
```

即 RFC 9110 允许的任意 token 都是合法方法。白名单会漏掉正在标准化的 `QUERY`（[draft-ietf-httpbis-safe-method-w-body](https://datatracker.ietf.org/doc/draft-ietf-httpbis-safe-method-w-body/)，截至 2026-08 仍为 Internet-Draft）、WebDAV 的 `PROPFIND` / `PROPPATCH` / `MKCOL` / `COPY` / `MOVE` / `LOCK` / `UNLOCK`、CalDAV 的 `REPORT` / `MKCALENDAR`，以及任何自定义方法。补条目只是把下次踩坑推迟。

采用的规则是 Go 接受一条请求行的**必要条件**，逐条对应 `parseRequestLine`（`request.go:1027`，`strings.Cut` 两次切空格）与 `validMethod`：

| 规则 | 对应的 Go 行为 |
| --- | --- |
| 首段全为 tchar（``!#$%&'*+-.^_`\|~`` + DIGIT + ALPHA） | `validMethod` → `isToken` → `httpguts.IsTokenRune` |
| 首段长度 1..32 | 见下方说明 |
| 其后紧跟 1 个 SP | `parseRequestLine` 的第一次 `Cut` |
| SP 之后 1 个 VCHAR（0x21–0x7E） | request-target 非空且非 CTL，否则 Go 后续解析必失败 |

长度上限 32 是唯一偏离标准的地方：RFC 不限制方法名长度，但 IANA 已注册的最长方法是 `UPDATEREDIRECTREF`（17 字符）。不设上限就无法在有限字节内判定。超过 32 字符的方法名不存在于现实中，这一点在文档中写明。

### 4.1.2 误判为 `http/1.1` 的概率

对首字节均匀随机的载荷，token 规则的误命中率约为

```
Σ(i=1..32) P(tchar)^i × P(SP) × P(VCHAR) = 0.4302 × 1/256 × 94/256 ≈ 0.062%
```

实际部署中 fallback 协议的头部通常是确定性的（版本字节、长度前缀），要么必然不匹配、要么必然匹配——用户可以拿 §4.1.1 的规则直接核对自己的协议头。因此文档给出的是**规则本身**而非概率保证，并附上"让客户端协商 h2 可使判定精确"这条建议（§4.1.0）。

**无法判定**是第四种运行时状态，不属于取值域：在嗅探超时窗口内读不到足以判定的字节（含 EOF、读错误）时，连接直接走原有 HTTPS 路径，不参与第二阶段匹配。这样浏览器的预连接（建好 TLS 但不发数据）不会被误投到 fallback 后端。

### 4.2 嗅探算法

两个分支都照搬 `isPostgres` 的增量 Peek 写法：每轮 `Peek(i)` 多要一个字节，一旦判定成立或候选判死立即返回，避免为了凑够字节数而阻塞。

**h2 分支**（协商到 `h2`）——逐字节比对 preface 前缀，最多 24 字节：

```
for i := 1; i <= len(preface); i++ {
    b := peek(i)                        // 出错 → 无法判定
    if b[i-1] != preface[i-1] { return unknown }
}
return h2
```

**HTTP/1 分支**（协商到 `http/1.1` 或 `""`）——方法名 + SP + target 首字节，最多 34 字节：

```
for i := 1; ; i++ {
    b := peek(i)                        // 出错 → 无法判定
    c := b[i-1]
    switch {
    case c == ' ' && i > 1:             // 方法名结束
        t := peek(i + 1)                // 出错 → 无法判定
        if isVCHAR(t[i]) { return http/1.1 }
        return unknown
    case isTchar(c) && i <= maxMethodLen:
        continue
    default:
        return unknown
    }
}
```

分流之后不再需要 h2 与 HTTP/1 的优先级仲裁：`PRI * HTTP/2.0...` 在 `http/1.1` 分支下被判为 `http/1.1`，这恰好与 `net/http` 的行为一致（它会把该行按 HTTP/1.x 请求行解析，随后因版本不受支持而拒绝）。普通 `GET /...` 在第 5 字节得出结论。

嗅探读取的超时是硬编码常量 `appProtoSniffTimeout = 500 * time.Millisecond`。TLS 握手使用单独的超时，取自入口点的 `transport.respondingTimeouts.readTimeout`（与 `net/http` 的 `tlsHandshakeTimeout()` 语义对齐；为 0 时不设 deadline）。两个 deadline 在交棒给下游之前都会被清空。

### 4.3 匹配器组合：复用第一阶段的 `ConnData`

现有的全部 TCP 匹配器（`HostSNI`、`HostSNIRegexp`、`ClientIP`、`ALPN`）都可以与 `AppProtocol` 自由组合，`&&` / `||` / `!` 照常。

做法是第二阶段**不重新构造 `ConnData`**，而是取回第一阶段那一份，只补上 `appProto`：

```go
connData = clientHelloConnData.WithAppProtocol(appProto)
```

这保证了同一个匹配器在两个阶段按构造就是同一套语义。如果在第二阶段重新构造，`ALPN` 会退化成只能匹配 `tls.ConnectionState().NegotiatedProtocol` 一个值，而第一阶段匹配的是 ClientHello 里客户端**提供的协议列表**（`hello.SupportedProtos`）——同名匹配器两种含义是明确的陷阱。`HostSNI` 同理：第一阶段那份已经过 `types.CanonicalDomain` 归一化，直接复用比从 `ConnectionState().ServerName` 重新推导更可靠。

取回的路径是两跳解包，全部在 Traefik 自己控制的包装链内：

```
tlsConn.NetConn()  →  tcp.TLSConn{WriteCloser: peekConn(阶段一)}  →  peekConn.clientHelloConnData()
```

`Router.ServeTCP` 在构造出 `ConnData` 后把它存到阶段一的 `peekConn` 上；`tcp.TLSHandler` 是 HTTPS 分支上唯一的中间包装层，`server_entrypoint_tcp.go` 的 `ConnContext` 现在就是用同样的 `NetConn().(tcp.TLSConn)` 解包取 `TLSOptionsName` 的。第二跳断言的是同包内的一个未导出接口 `connDataCarrier`（而非具体类型），未来插入的包装层只要转发该方法即可。解包失败视为不变量被破坏：记 error 日志并关闭连接，不做静默回退。

`AppProtocol` 仅支持 v3 规则语法。v2 解析器不认识它，会自然报"未知匹配器"。

## 5. HTTP/2 的保全

### 5.1 问题

`net/http` 的 `conn.serve` 里：

```go
if tlsConn, ok := c.rwc.(*tls.Conn); ok {
    ...
    if proto := c.tlsState.NegotiatedProtocol; validNextProto(proto) {
        if fn := c.server.TLSNextProto[proto]; fn != nil { fn(c.server, tlsConn, h); }
        return
    }
}
```

嗅探必然消费明文字节，回放只能靠 wrapper，`*tls.Conn` 断言随之失效，原生 h2-over-TLS 分支不再触发。`crypto/tls` 没有任何把明文塞回 `tls.Conn` 内部缓冲的导出手段。

### 5.2 解法：借道 `unencrypted_http2`

Go 1.24 为 h2c 增加了一条并行通道，全部是导出 API：

```go
// net/http/server.go
if c.tlsState == nil && protos.UnencryptedHTTP2() {
    if c.maybeServeUnencryptedHTTP2(ctx) { return }   // Peek 24 字节判定 preface
}
// maybeServeUnencryptedHTTP2:
fn := c.server.TLSNextProto["unencrypted_http2"]
fn(c.server, unencryptedTLSConn(c.rwc), unencryptedHTTP2Request{ctx, c.rwc, ...})
// h2_bundle.go: 解包出原始 net.Conn，以 SawClientPreface: true 调用 conf.ServeConn
```

于是：在 HTTPS 侧的 `http.Server` 上打开 `Protocols.SetUnencryptedHTTP2(true)`，把嗅探后的回放 wrapper 交给它，`net/http` 会重新 Peek 到 preface（由 wrapper 回放）并转交内建 http2 实现。`http.Server.HTTP2Config`（MaxConcurrentStreams、header table size）、`ConnContext`、`ConnState` 全部沿用，不需要引入 x/net/http2，也不需要自己映射任何 HTTP/2 参数。

对**未被嗅探**的连接这个开关是空操作：真 `*tls.Conn` 会在前面就把 `c.tlsState` 填好，`c.tlsState == nil` 的门永远进不去。因此可以对 HTTPS server 无条件开启。明文 HTTP 入口点的 h2c 开关维持原样，仍由 `withH2c` 控制。

### 5.3 两个 wrapper 类型：把非标准机制限制在 h2 一条路上

`conn.serve` 里恢复 `c.tlsState` 的路径是：

```go
if c.tlsState == nil {
    if tc, ok := c.rwc.(connectionStater); ok { c.tlsState = ...; }   // ConnectionState() tls.ConnectionState
}
if c.tlsState == nil && protos.UnencryptedHTTP2() { ... }
```

两者互斥：wrapper 一旦实现 `ConnectionState()`，`c.tlsState` 非空，preface 检测就被跳过。既然 §4.1.0 已经按协商到的 ALPN 分流，就按分支选择交给 `http.Server` 的包装类型：

| 协商到的 ALPN | 交给 `http.Server` 的类型 | `net/http` 的走向 | `Request.TLS` |
| --- | --- | --- | --- |
| `http/1.1` / `""` | 实现 `ConnectionState()` | `c.tlsState` 从真实状态填好 → HTTP/1.x 分支，preface 检测被跳过 | 原生填好 |
| `h2` | **不**实现 `ConnectionState()` | `c.tlsState == nil` → `unencrypted_http2` → 内建 http2 | 需还原（见下） |

HTTP/1.1 那条路因此与未嗅探路径**完全一致**：同样的分支、同样的 `r.TLS`、同样不做 preface 检测，`unencrypted_http2` 这个非标准机制根本不参与。它只服务 h2 一条路，Go 版本升级的风险面随之收窄。

h2 那条路的 `Request.TLS` 需要 Traefik 自己还原（`unencryptedHTTP2Request` 不会从真实状态填它）：

1. wrapper 用一个 `net/http` 看不见的方法名暴露状态（`TLSState() tls.ConnectionState`）。
2. `newHTTPServer` 里已有的 `ConnContext` 增加分支，把 `tls.ConnectionState` 与 `TLSOptionsName` 写进连接上下文。
3. 在 HTTPS server 的 handler 链最外层加一个还原器，从请求上下文取出状态并**无条件覆盖** `r.TLS`（http2 可能已填入一个空的 `tls.ConnectionState`）。

上下文能传到 h2 的每个 stream：`unencryptedHTTP2Request` 实现了 `BaseContext()`，连接上下文会成为各 stream 请求上下文的父级。

现有 `ConnContext` 里 `c.(*tls.Conn) → NetConn().(tcp.TLSConn)` 取 `TLSOptionsName` 的逻辑保留；两个 wrapper 类型各加一个分支取同一个值。

### 5.4 残留的行为差异

协商到 `h2`、载荷却不是 preface、且没有任何 post-TLS 路由匹配时，连接会被交给 `http.Server`：`unencrypted_http2` 找不到 preface，落到 HTTP/1.x 分支，于是一条 `GET / HTTP/1.1` 会被正常服务；未嗅探路径下 http2 server 会因 `readPreface` 失败而直接关闭。

这是唯一的差异，方向是更宽松，且只出现在"客户端自己的载荷与它协商的 ALPN 相矛盾"这种情况。不为它加特例分支——保持"未命中 → 走原有 HTTPS 路径"这一条统一规则比消除这个差异更值得。文档中写明。

## 6. 回放 wrapper：直接复用 `peekConn`

`pkg/server/router/tcp/router.go` 里已有的 `peekConn` 正好满足全部要求：

- `Peek(n)` 走 `bufio.Reader.Peek`，不消费；后续 `Read` 从同一个 `bufio.Reader` 读，天然完成回放。
- 内嵌的是 `tcp.WriteCloser` **接口**，`*tls.Conn` 的 `ConnectionState()` 不会被提升——这正是 §5.3 里 h2 分支所需要的"看不见 `connectionStater`"。
- `Write` / `Close` / `CloseWrite` / `SetDeadline` / `RemoteAddr` 直落 `*tls.Conn`，转发给 `tcp.Proxy` 的双向 `io.Copy` 与半关闭语义正确。

需要新增的是两组成员：

- 携带 `tls.ConnectionState` 的字段与 `TLSState()` 方法（§5.3），用于第二阶段的 peekConn。
- 携带第一阶段 `ConnData` 的字段与 `clientHelloConnData()` 方法（§4.3），用于第一阶段的 peekConn。

同一个类型在两个阶段各用一半字段。`bufio.Reader.Peek` 的 `fill()` 只做一次底层 `Read` 并在够数时立刻返回，不会为填满 4096 字节而额外阻塞。

HTTP/1.1 分支要交给 `http.Server` 的是一个**额外包一层**的类型，它把状态以 `net/http` 认得的名字暴露出来：

```go
// tlsStatefulConn 让 net/http 把 Request.TLS 填对并走原生 HTTP/1.x 分支。
// 只用于协商到 http/1.1 或无 ALPN 的连接；h2 分支必须用裸的 peekConn（§5.3）。
type tlsStatefulConn struct{ *peekConn }

func (c tlsStatefulConn) ConnectionState() tls.ConnectionState { return c.TLSState() }
```

转发给 fallback TCP service 时两条分支都用裸的 `peekConn`——`tcp.Proxy` 只需要 `tcp.WriteCloser`。

## 7. 配置面

不新增任何动态或静态配置字段。特性完全通过新匹配器暴露：

```yaml
tcp:
  routers:
    camouflage-fallback:
      entryPoints: [websecure]
      rule: "HostSNI(`example.com`) && AppProtocol(`unknown`)"
      service: inner-proxy
      tls: {}
  services:
    inner-proxy:
      loadBalancer:
        servers:
          - address: "127.0.0.1:10000"
```

post-TLS 路由的约束（配置期校验，违反则该路由标记为错误并跳过）：

- 必须设置 `tls`（承接的是解密后的流），且 `tls.passthrough` 必须为 false。
- **不得设置 `tls.options`**。TLS 配置由 HTTPS 路径决定：有同 SNI 的 HTTP 路由时用它解析出的 TLS options，否则用入口点默认配置。证书仍按 SNI 从证书库正常选取。这样避免了把 TCP 路由塞进 HTTP 路由的 TLS options 冲突消解器（`hostHTTPTLSConfig` 是"每 SNI 一份配置"的映射，两类路由竞争同一个键会静默覆盖）。

Kubernetes `IngressRouteTCP` 的 `match` 是自由字符串，CRD 无需改动。

## 8. 优先级与冲突

post-TLS 路由存放在独立的 `muxerPostTLS` 里，只与彼此竞争，排序沿用现有的"规则长度 + provider 优先级"，`HostSNI(*)` 的 catchAll 特例同样适用。它们不参与 `muxerHTTPS` / `muxerTCPTLS` 的第一阶段竞争，因此不会抢走普通 HTTPS 流量。

第一阶段命中 TCP-TLS 路由（含 passthrough）时第二阶段不执行 —— 这是明确且可预期的：TCP-TLS 路由本来就把整条连接判给了自己。

## 9. 不引入第三方库

全部基于标准库与 Traefik 既有依赖。`unencrypted_http2` 通道使用的 `http.Server.Protocols` / `http.Server.TLSNextProto` 均为 Go 标准库导出 API。协议嗅探是几十字节的前缀比对，不需要引入 sniffing 库。

token 字符集判定复用 `golang.org/x/net/http/httpguts.IsTokenRune`——`net/http` 的 `isToken` 转发到同一个包，复用它可保证与 HTTP server 的判定不漂移。该依赖 Traefik 已在使用（`pkg/middlewares/forwardedheaders`、`pkg/middlewares/ingressnginx/snippet`），`golang.org/x/net` 已是 `go.mod` 的直接依赖。

## 10. 已知边界

- 判定所需字节未在 500ms 内到达时按"无法判定"处理，走 HTTPS 路径。服务端先说话的 fallback 协议不被支持。
- HTTP/3（QUIC）入口点不参与，该特性只作用于 TCP 入口点。
- 协商到 `h2` 的连接，`Request.TLS` 由 Traefik 从真实 `tls.ConnectionState` 还原（§5.3）；协商到 `http/1.1` / `""` 的连接由 `net/http` 原生填写。两者内容一致。
- §5.4 的残留行为差异：协商到 `h2`、载荷非 preface、且无路由匹配时，连接会被按 HTTP/1.x 服务而非直接关闭。
- 载荷首字节均匀随机时，`http/1.1` 分支约有 0.062% 的误命中率（§4.1.2）；协商到 `h2` 时该分支不参与，判定精确。
