# 接口约定

## 1. 用户面：`AppProtocol` 规则匹配器

### 语法

```
AppProtocol(`<value>`)
```

`<value>` ∈ { `http/1.1`, `h2`, `unknown` }。其它取值在规则解析期返回错误，路由被标记为 error 并跳过。

只在 TCP 路由（`tcp.routers[*].rule`）中可用，只支持 v3 规则语法。

### 语义

对 TLS 终止后的明文流做头部前缀嗅探，匹配探测出的应用层协议：

判定按握手协商到的 ALPN 分流，两个分支互斥：

| 协商到的 ALPN | 载荷 | 结果 |
| --- | --- | --- |
| `h2` | 前 24 字节为 `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n` | `h2` |
| `h2` | 否则 | `unknown` |
| `http/1.1` 或空 | 形如 `<token>{1,32} SP <VCHAR>` | `http/1.1` |
| `http/1.1` 或空 | 否则 | `unknown` |
| 其它 | 不嗅探 | `unknown` |

**协商到 `h2` 时判定是精确的**：载荷只要不等于那 24 字节就是 `unknown`。若希望 fallback 判定完全确定，让客户端在 ALPN 里带上 `h2`。注意 `crypto/tls` 的协商是服务端顺序优先，Traefik 默认列表为 `["h2", "http/1.1", "acme-tls/1"]`，所以客户端只要提供了 `h2` 就一定协商到 `h2`，与客户端自己的顺序无关。

`http/1.1` 的判定不使用方法白名单，而是 RFC 9110 的 `extension-method = token`，与 `net/http` 的 `validMethod` 一致。因此 `GET` / `POST` 之外，`QUERY`、WebDAV 的 `PROPFIND` / `MKCOL` / `COPY` / `MOVE` / `LOCK`、CalDAV 的 `REPORT`，以及任何自定义方法都会被正确识别为 HTTP，不会被投递到 fallback 后端。

- token 字符集：``!#$%&'*+-.^_`|~`` + `0-9` + `A-Z` + `a-z`
- VCHAR：`0x21`–`0x7E`
- 方法名长度上限 32（IANA 已注册的最长方法 `UPDATEREDIRECTREF` 为 17 字符）

判为 `unknown` 意味着 Traefik 的 HTTP server 本来也会拒绝这条请求行。反向不成立：某些二进制载荷可能被判为 `http/1.1`，此时 HTTP server 返回 400 并关闭连接。配置 fallback 后端前，用规则核对该协议的头部字节。

**已知行为差异**：协商到 `h2`、载荷不是 preface、且没有任何 post-TLS 路由匹配时，连接会被按 HTTP/1.x 解析并可能被正常服务；未配置 post-TLS 路由的入口点上，这种连接会被 HTTP/2 服务端直接关闭。差异只出现在客户端载荷与其自身 ALPN 相矛盾的情况。

500ms 内读不到足以判定的字节时（含 EOF、读错误），连接不参与 post-TLS 匹配，直接进入常规 HTTPS 处理路径。

### 组合

`HostSNI`、`HostSNIRegexp`、`ClientIP`、`ALPN` 均可与 `AppProtocol` 自由组合，语义与它们在普通 TCP 路由中完全一致（第二阶段复用第一阶段的 `ConnData`）。特别地，`ALPN` 匹配的仍然是客户端在 ClientHello 中**提供的协议列表**，不是协商结果。

```
# 客户端声称 h2，实际发的却不是 h2 —— 投给 fallback
rule: HostSNI(`example.com`) && ALPN(`h2`) && AppProtocol(`unknown`)
```

含 `AppProtocol` 的路由（下称 post-TLS 路由）的约束：

| 字段 | 要求 | 违反时的错误 |
| --- | --- | --- |
| `tls` | 必须存在 | `AppProtocol matcher requires TLS termination on the router` |
| `tls.passthrough` | 必须为 false | `AppProtocol matcher cannot be used with TLS passthrough` |
| `tls.options` | 必须为空 | `TLS options cannot be set on a router using the AppProtocol matcher, they are inherited from the entryPoint HTTPS configuration` |
| `ruleSyntax` | 必须为 v3 | 由 v2 解析器返回未知匹配器错误 |

### 配置示例

File provider：

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

http:
  routers:
    site:
      entryPoints: [websecure]
      rule: "Host(`example.com`)"
      service: site
      tls: {}
```

Kubernetes CRD（`match` 为自由字符串，CRD 无变更）：

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: camouflage-fallback
spec:
  entryPoints: [websecure]
  routes:
    - match: HostSNI(`example.com`) && AppProtocol(`unknown`)
      services:
        - name: inner-proxy
          port: 10000
  tls: {}
```

Docker labels：

```
traefik.tcp.routers.fallback.rule=HostSNI(`example.com`) && AppProtocol(`unknown`)
traefik.tcp.routers.fallback.tls=true
traefik.tcp.routers.fallback.service=inner-proxy
```

## 2. 内部 Go 接口变更

### `pkg/muxer/tcp`

```go
// ConnData 新增字段
type ConnData struct {
    serverName string
    remoteIP   string
    alpnProtos []string
    appProto   string // 新增：TLS 解密后探测到的应用层协议，第一阶段为空
}

// 新增：返回补上 appProto 的副本，供第二阶段复用第一阶段的 ConnData。
// NewConnData 签名不变。
func (c ConnData) WithAppProtocol(appProto string) ConnData

// 新增：判断规则中是否使用了 AppProtocol 匹配器
func (m *Muxer) HasAppProtocolMatcher(rule, syntax string) (bool, error)
```

`tcpFuncs` 新增 `"AppProtocol": expect1Parameter(appProtocol)`；`tcpFuncsV2` 不变。

### `pkg/server/router/tcp`

```go
type Router struct {
    // ...
    muxerPostTLS tcpmuxer.Muxer // 新增：TLS 解密后的第二阶段路由
    tlsHandshakeTimeout time.Duration // 新增
}

// 新增：注册 post-TLS 路由
func (r *Router) AddPostTLSRoute(rule, syntax string, priority int, providerName string, target tcp.Handler) error

// 签名变更：新增握手超时参数
func (r *Router) SetHTTPSForwarder(handler tcp.Handler, tlsHandshakeTimeout time.Duration)
```

`peekConn` 新增：

```go
// 第二阶段使用：携带真实 TLS 状态。
// 方法名刻意避开 ConnectionState，防止被 net/http 的 connectionStater 断言命中
// （见 design.md §5.3）。
func (c *peekConn) TLSState() tls.ConnectionState

// 第一阶段使用：把 ClientHello 阶段的 ConnData 带给第二阶段。
type connDataCarrier interface {
    clientHelloConnData() (tcpmuxer.ConnData, bool)
}

func (c *peekConn) clientHelloConnData() (tcpmuxer.ConnData, bool)

// 协商到 http/1.1 或无 ALPN 时交给 http.Server 的包装类型：以 net/http 认得的
// 方法名暴露状态，使其原生填好 Request.TLS 并走 HTTP/1.x 分支。
// h2 分支必须用裸的 peekConn，否则 unencrypted_http2 检测会被跳过。
type tlsStatefulConn struct{ *peekConn }

func (c tlsStatefulConn) ConnectionState() tls.ConnectionState
```

### `pkg/server`

```go
// 签名变更：新增 tlsTerminated，标识这是承接 TLS 终止连接的 HTTPS server
func newHTTPServer(ctx context.Context, ln net.Listener, configuration *static.EntryPoint,
    withH2c, tlsTerminated bool, reqDecorator *requestdecorator.RequestDecorator) (*httpServer, error)
```

`protocols.SetUnencryptedHTTP2(withH2c || tlsTerminated)`。调用点：明文 HTTP server 传 `(true, false)`，
HTTPS server 传 `(false, true)`。`tlsTerminated` 同时决定是否织入 `Request.TLS` 还原器。

`TCPEntryPoint.SwitchRouter` 与 `NewTCPEntryPoint` 中的 `SetHTTPSForwarder` 调用改为传入
`time.Duration(config.Transport.RespondingTimeouts.ReadTimeout)`。

## 3. 可观测性

- post-TLS 匹配命中时 debug 日志：`Matched post-TLS route`，字段含 `appProtocol`、`serverName`、`remoteAddr`、`routerName`。
- 握手失败、嗅探超时、嗅探读错误统一 debug 级别，与 `Router.ServeTCP` 现有的 `io.EOF` / `net.OpError` timeout 降噪策略一致。
- 不新增 metrics。
