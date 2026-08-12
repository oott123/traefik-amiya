# 接口：X-Proxy-Meta

## 1. 对外契约

### 请求头

| 名称 | `X-Proxy-Meta` |
| --- | --- |
| 方向 | Traefik → 后端（也对 HTTP router 规则与所有中间件可见） |
| 来源 | 入站连接 PROXY protocol v2 header 中类型为 `0xF3` 的 TLV |
| 值 | TLV value 的原始字节，直接作为字符串。不做编码、转义、trim、大小写处理 |
| 多值 | 一个连接的 PROXY header 里有多个 `0xF3` TLV 时为多值头，顺序与 TLV 在 header 中出现的顺序一致 |
| 客户端可控性 | 无。客户端发来的同名头一律被剥离 |

### 生效条件

全部满足才注入：

1. 连接进入的 entrypoint 配置了 `proxyProtocol`（`trustedIPs` 或 `insecure`）。
2. 上游地址通过了 `trustedIPs` 检查（`insecure = true` 时无条件通过）。
3. 入站 PROXY protocol header 是 v2 且携带至少一个类型 `0xF3` 的 TLV。
4. 该 TLV 的 value 非空，且每个字节都在 `0x20`–`0x7E` 内。

任一条不满足，该 TLV 不产生头。第 4 条按 TLV 逐条判断。

### 行为矩阵

| 入站情况 | 客户端发来的 `X-Proxy-Meta` | 后端看到的 `X-Proxy-Meta` |
| --- | --- | --- |
| 无 PROXY protocol | `evil` | 无 |
| entrypoint 未启用 proxyProtocol | `evil` | 无 |
| 上游不在 `trustedIPs` 内 | 任意 | 无 |
| v1 PROXY header（不支持 TLV） | 任意 | 无 |
| v2，无 `0xF3` TLV | 任意 | 无 |
| v2，`0xF3` = `tenant=acme` | 任意 | `tenant=acme` |
| v2，`0xF3` = `""`（空） | 任意 | 无 |
| v2，`0xF3` = `a\r\nb` | 任意 | 无 |
| v2，`0xF3` = `caf\xc3\xa9`（UTF-8） | 任意 | 无 |
| v2，两个 `0xF3` = `a`、`b` | 任意 | `a`, `b`（两值） |
| v2，三个 `0xF3` = `a`、`\x00`、`c` | 任意 | `a`, `c`（两值） |

### 配置示例

不需要任何新配置。启用 proxyProtocol 即可：

```yaml
entryPoints:
  web:
    address: ":80"
    proxyProtocol:
      trustedIPs:
        - "10.0.0.0/8"
```

路由规则里直接用：

```yaml
http:
  routers:
    tenant-acme:
      entryPoints: [web]
      rule: "Host(`example.com`) && Header(`X-Proxy-Meta`, `tenant=acme`)"
      service: acme-backend
```

## 2. 内部接口

`pkg/server/proxy_protocol_meta.go`，全部包内私有：

```go
// proxyMetaHeader is the request header carrying the PROXY protocol metadata.
const proxyMetaHeader = "X-Proxy-Meta"

// pp2TypeMeta is the PROXY protocol v2 TLV type carrying the metadata.
const pp2TypeMeta proxyproto.PP2Type = 0xF3

type proxyProtocolMetaKey struct{}

// proxyProtocolConn digs through the connection wrappers sitting between net/http
// and the entryPoint listener to find the PROXY protocol connection, if any.
func proxyProtocolConn(c net.Conn) *proxyproto.Conn

// addProxyProtocolMetaInContext stores the metadata TLV values carried by the
// connection, if any, so that the HTTP handlers can read them back.
func addProxyProtocolMetaInContext(ctx context.Context, c net.Conn) context.Context

// isPrintableASCII reports whether v is a non-empty run of printable ASCII bytes.
func isPrintableASCII(v []byte) bool

// proxyProtocolMeta replaces the X-Proxy-Meta header with the values carried by
// the connection PROXY protocol header.
func proxyProtocolMeta(next http.Handler) (http.Handler, error)
```

`addProxyProtocolMetaInContext` 的签名与 `connContextFunc`（`pkg/server/conncontext.go`）一致，`proxyProtocolMeta` 的签名与 `alice.Constructor`（`func(http.Handler) (http.Handler, error)`）一致，两者都能直接挂载，无需适配。`proxyProtocolMeta` 永不返回错误，`error` 只为满足 `alice.Constructor`，与 `requestdecorator.WrapHandler` 一致。

context 中存放的类型是 `[]string`，只在没有任何合法值时不写入 key。
