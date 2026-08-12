# 需求：把 PROXY protocol v2 的 0xF3 TLV 透传为 X-Proxy-Meta 请求头

## 原始需求

看看怎么让下游的 http router 能读取 proxy protocol v2 发来的 TLV 数据，比如加到 http request header 里之类的。

先看能不能不 patch、用插件做；不行的话按补丁的方法做。

只识别 `0xF3` 这一个 TLV 类型，按 ASCII 解析 value，传入 `X-Proxy-Meta = value`。如果值在 ASCII 外，则放弃添加这个头。

补丁放到当前仓库下，和 AppProtocol 功能分开成两个文件夹。

## 调研结论：插件无法实现

1. `pkg/plugins/builder.go:14` 把插件构造函数写死为 `func(context.Context, http.Handler) (http.Handler, error)`：插件只有 HTTP 中间件与 provider 两种形态，没有 TCP 层插件。
2. TLV 是连接级数据，只存在于 `*proxyproto.Conn` 上。Traefik 现有的 `ConnContext`（`pkg/server/server_entrypoint_tcp.go`）只往 request context 里放了 TLS options name、transport、connState，**没有放 conn 本身**；Go 的 `http.Server` 也不提供 `Request → net.Conn` 的通路（`http.LocalAddrContextKey` 只有地址）。因此 HTTP 中间件插件取不到 TLV。
3. 唯一的逃生口 `ResponseWriter.Hijack()` 会接管连接、无法交回 handler chain，且 HTTP/2 下不可用。
4. 即使 Hijack 成功，Yaegi 插件里 `import "github.com/pires/go-proxyproto"` 得到的是解释器中的另一份类型，与 traefik 二进制内的 `*proxyproto.Conn` 不是同一类型，断言必然失败，只能上反射。

因此改源码，走 patch 补丁集。

## 澄清后的决策

| 决策点 | 结论 |
| --- | --- |
| TLV 类型 | 只识别 `0xF3`（属于 PROXY protocol v2 的 experiment 区间 `0xF0`–`0xF7`），其他类型一律忽略 |
| 目标请求头 | `X-Proxy-Meta`，值为 TLV value 的原始字节字符串 |
| ASCII 边界 | 仅接受可打印 ASCII `0x20`–`0x7E`。出现控制字符（NUL/CR/LF/TAB）或 `0x7F` DEL 或任何 `>= 0x80` 的字节，该 TLV 整条丢弃、不注入 |
| 空 value | 长度为 0 的 TLV 视为无效，不注入 |
| 重复 TLV | 一个 PROXY header 里出现多个 `0xF3` 时，全部注入为多值 `X-Proxy-Meta` 头，顺序与 TLV 出现顺序一致；合法性逐值独立判断，非法的那一个跳过，不影响其余 |
| 客户端伪造 | 所有 entrypoint 无条件剥离客户端发来的 `X-Proxy-Meta`，与该 entrypoint 是否启用 proxyProtocol 无关。后端看到这个头就一定来自 TLV |
| 生效范围 | 注入发生在 HTTP router 匹配之前，因此 `Header(...)` / `HeaderRegexp(...)` 路由规则和所有中间件都能用上它 |
| 可信性 | 由 entrypoint 现有的 `proxyProtocol.trustedIPs` / `insecure` 保证，不引入新配置项 |
| 配置开关 | 不引入。行为固定，无静态或动态配置 |
| 覆盖协议 | HTTP/1.x、HTTPS、h2（含 post-TLS 嗅探后的 h2）。HTTP/3 走 QUIC 没有 PROXY protocol，只剥离不注入 |
| 交付形态 | patch 补丁集，追加到本仓库。`patches/` 按功能拆成两个子目录，线性按序应用 |

## 补丁集布局

`patches/` 重组为按功能分目录，应用顺序由 `patches/SERIES` 定义：

```
patches/SERIES                     # 一行一个 "<set 名> <commit 数>"，定义应用顺序
patches/appproto-fallback/         # 现有 8 个补丁，内容不变
patches/proxy-tlv-meta/            # 本需求的补丁
```

两个 set 在同一个开发分支上线性叠放，`proxy-tlv-meta` 位于 `appproto-fallback` 之后。功能上互不依赖，但补丁上下文是线性的，必须按 `SERIES` 顺序整体应用。
