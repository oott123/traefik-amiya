# 设计：PROXY protocol 0xF3 TLV → X-Proxy-Meta

上游基线：`3f3466a3c4a5d48d7068635f084d0f403c7039d2`。补丁集 `proxy-tlv-meta`，叠放在 `appproto-fallback` 之后。

## 1. 问题

`entryPoints.<name>.proxyProtocol` 启用后，`pkg/server/server_entrypoint_tcp.go:buildProxyProtocolListener` 用 `proxyproto.Listener` 包住原始 listener，PROXY protocol header 被解析并保存在 `*proxyproto.Conn` 上。Traefik 只消费了其中的地址信息（`Conn.RemoteAddr()` 被改写，进而喂给 `X-Forwarded-For`），**TLV 完全没有出口**：既没有进 request context，也没有任何 HTTP 层可以读到它的接口。

本设计把 `0xF3` 这一个 TLV 的 value 变成请求头 `X-Proxy-Meta`，在 HTTP router 匹配之前注入。

## 2. 数据通路

TLV 是连接级数据，`X-Proxy-Meta` 是请求级产物，两者之间只有一个官方通道：`http.Server.ConnContext`。Traefik 已经有 `multipleConnContext`（`pkg/server/conncontext.go`）用于往连接的 base context 上叠加值，request context 继承自它。

```
proxyproto.Listener.Accept()
  → *proxyproto.Conn（header + TLV 已解析）
    → …包装层…
      → http.Server.ConnContext(ctx, conn)      ← 阶段一：剥包装、取 TLV、存 context
        → Request.Context()
          → proxyProtocolMeta handler           ← 阶段二：剥离伪造头、注入 X-Proxy-Meta
            → HTTP router / 中间件 / 后端
```

一条连接上的所有请求共享同一份 TLV，对 HTTP/1.1 keep-alive 和 h2 多路复用都是正确语义：TLV 描述的是连接，不是单个请求。

## 3. 阶段一：从包装层里挖出 *proxyproto.Conn

`ConnContext` 拿到的 `net.Conn` 是 net/http 那一侧的连接，与 listener 返回的 `*proxyproto.Conn` 之间隔着若干包装层。最深的一条是 post-TLS 嗅探路径（`appproto-fallback` 引入），共 7 跳：

| 层 | 类型 | 下一跳取法 |
| --- | --- | --- |
| 1 | `tcprouter.TLSStatefulConn` | 提升的 `NetConn()` |
| 2 | `*tcprouter.PeekConn`（post-TLS 阶段） | `NetConn()` |
| 3 | `*tls.Conn` | `NetConn()` |
| 4 | `tcp.TLSConn`（值类型，无 `NetConn()`） | 字段 `.WriteCloser` |
| 5 | `*tcprouter.PeekConn`（ClientHello 阶段） | `NetConn()` |
| 6 | `*trackedConnection` | 嵌入字段 `.WriteCloser` |
| 7 | `*writeCloserWrapper` | 嵌入字段 `.Conn` |
| 终 | `*proxyproto.Conn` | — |

明文 HTTP 路径只经过 5→7，常规 HTTPS 路径经过 3→7。

实现为 `proxyProtocolConn(net.Conn) *proxyproto.Conn`：一个逐层剥离的循环，type switch 里具体类型的 case 在 `interface{ NetConn() net.Conn }` 之前，未知类型直接返回 `nil`。`*tls.Conn`、两种 `PeekConn` 都由那个接口 case 统一覆盖；`tcp.TLSConn` 没有 `NetConn()`，必须单列。循环带一个固定上限（16 跳），防止某个包装层返回自身导致死循环。

`Conn.ProxyHeader()` 内部是 `sync.Once` 保护的 `ensureHeaderProcessed()`。在 `ConnContext` 被调用时，PROXY header 早已在 TCP router peek ClientHello 时读完，所以这里不会产生额外阻塞。

## 4. 阶段二：注入

`proxyProtocolMeta` 是一个普通的 `alice.Constructor`，挂在 `newHTTPServer` 里 `httpSwitcher` 之前的 alice 链首。它做两件事，顺序固定：

1. **无条件** `req.Header.Del("X-Proxy-Meta")`。不看 entrypoint 有没有开 proxyProtocol，也不看 context 里有没有值。这是这个头的可信性的唯一来源。
2. 如果 context 里有值，逐个 `req.Header.Add("X-Proxy-Meta", v)`。

挂在 `httpSwitcher` 之前意味着 HTTP router 的 `Header(...)` / `HeaderRegexp(...)` 规则可以直接对 `X-Proxy-Meta` 匹配。

## 5. 校验规则

TLV 从 `Header.TLVs()` 拿到（`SplitTLVs` 会把 `PP2_TYPE_NOOP` 的 value 置空，但仍保留条目；因为只匹配 `0xF3`，这与本设计无关）。对每个 `Type == 0xF3` 的 TLV：

- `len(Value) == 0` → 丢弃。
- 任一字节 `< 0x20` 或 `> 0x7E` → 丢弃这一条。

判断逐条独立：三个 `0xF3` 里第二条非法，注入的就是第一和第三条的值。全部非法或一条都没有时，context 里不留值，`X-Proxy-Meta` 只被剥离、不被注入。

选可打印 ASCII 而不是全部 7-bit ASCII，是因为 `0x20`–`0x7E` 同时满足两个约束：它落在 RFC 9110 的 `field-value` 允许集合内，且天然排除了 CR/LF，不可能出现头注入。

## 6. 可信性

不引入新配置项。`0xF3` TLV 的可信性完全由 entrypoint 已有的 `proxyProtocol.trustedIPs` / `proxyProtocol.insecure` 决定，机制来自 go-proxyproto 的 policy：

- 上游 IP 在 `trustedIPs` 内 → policy `USE` → `readHeader()` 把 header 存到 `p.header` → `ProxyHeader()` 返回它 → TLV 生效。
- 上游 IP 不在名单内 → policy `IGNORE` → `readHeader()` **不给 `p.header` 赋值** → `ProxyHeader()` 返回 `nil` → 不注入。

也就是说不可信来源的 TLV 自动失效，和 `X-Forwarded-For` 在同一套信任模型下，不需要第二处判断。entrypoint 未启用 proxyProtocol 时连接根本不是 `*proxyproto.Conn`，剥包装到最后返回 `nil`，同样不注入。

## 7. 协议覆盖

| 协议 | 剥离 | 注入 |
| --- | --- | --- |
| HTTP/1.x（明文） | 是 | 是 |
| HTTPS（http/1.1） | 是 | 是 |
| h2（HTTPS ALPN） | 是 | 是 |
| h2c | 是 | 是 |
| h2（post-TLS 嗅探后经 unencrypted_http2 通道） | 是 | 是 |
| HTTP/3 | 是 | 否 |

HTTP/3 复用 httpsServer 的 handler（`server_entrypoint_tcp_http3.go:68`），所以剥离照常发生；QUIC 上没有 PROXY protocol，`ConnContext` 那条链取不到 `*proxyproto.Conn`，不会注入。语义一致：后端见到 `X-Proxy-Meta` 就一定来自 TLV。

## 8. 代码落点

新增一个文件，把连接层与 HTTP 层的逻辑都收在里面，对既有文件只留两处单行改动，减少与 `appproto-fallback` 补丁的上下文耦合：

```
pkg/server/proxy_protocol_meta.go        # 常量、context key、proxyProtocolConn、
                                         # addProxyProtocolMetaInContext、proxyProtocolMeta
pkg/server/proxy_protocol_meta_test.go
```

`pkg/server/server_entrypoint_tcp.go` 的两处改动：

- `connContext.AddConnContextFunc(addProxyProtocolMetaInContext)`，加在已有那个匿名 `AddConnContextFunc` 之后。
- alice 链改为 `alice.New(proxyProtocolMeta, requestdecorator.WrapHandler(reqDecorator)).Then(httpSwitcher)`。

不引入第三方库：`github.com/pires/go-proxyproto` 已是直接依赖（`go.mod`）。

## 9. 补丁集布局改造

`patches/` 从单一序列改成按功能分目录，应用顺序由 `patches/SERIES` 声明：

```
patches/SERIES
patches/appproto-fallback/0001-….patch … 0008-….patch
patches/proxy-tlv-meta/0001-….patch …
```

`SERIES` 一行一个 `<set 名> <commit 数>`：

```
appproto-fallback 8
proxy-tlv-meta 4
```

- `scripts/apply.sh` 按 `SERIES` 顺序逐目录 `git am`。
- `scripts/export.sh` 用 `SERIES` 里的 commit 数把 `UPSTREAM..HEAD` 线性切段，逐段 `git format-patch` 到对应目录。切段前校验 `SERIES` 的总数与实际 commit 数相等，不等则报错要求先更新 `SERIES`——数字是手工维护的，这个校验是防忘的闸门。

两个 set 在同一分支上线性叠放，因此**必须整体按序应用**，单独 `git am patches/proxy-tlv-meta/*.patch` 到基线不保证成功。分目录的目的是把两个功能的补丁在仓库里分开、各自独立编号和阅读。
