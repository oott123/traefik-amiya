# 执行计划

上游基线：`3f3466a3c4a5d48d7068635f084d0f403c7039d2`。
开发在 `.references/traefik` 的 `appproto-fallback` 分支上继续追加 commit，本需求占 4 个 commit，导出到 `patches/proxy-tlv-meta/`。

---

## 步骤 0：补丁集目录改造（仓库侧）

不碰 traefik 工作副本，只改本仓库。

**移动现有补丁：**

```
patches/0001-….patch … patches/0008-….patch
  → patches/appproto-fallback/0001-….patch … 0008-….patch
```

用 `git mv`，文件内容不变。

**新增 `patches/SERIES`：**

```
# <set 名> <commit 数>，应用顺序即行序
appproto-fallback 8
proxy-tlv-meta 0
```

`proxy-tlv-meta` 先记 0，步骤 5 导出时改成实际数量。

**`scripts/common.sh`：** 新增 `SERIESFILE="${PATCHDIR}/SERIES"` 与 `read_series()`，后者过滤空行和 `#` 开头的注释行，逐行输出 `<name> <count>`。

**`scripts/apply.sh`：** 按 `read_series` 的顺序逐 set 收集 `${PATCHDIR}/<name>/*.patch`，拼成一个列表后一次 `git am`（保持冲突处理体验与现在一致）。收集时校验每个 set 的 patch 文件数等于 `SERIES` 里的 count，不等则报错退出，提示 `SERIES` 已过期。

**`scripts/export.sh`：**

1. `mapfile -t commits < <(git rev-list --reverse "${UPSTREAM_COMMIT}..HEAD")`。
2. 校验 `SERIES` 各 count 之和等于 `${#commits[@]}`，不等则报错并打印两个数字，要求先更新 `SERIES`。
3. 按 `SERIES` 顺序切段：每段起点为上一段终点（首段为 `UPSTREAM_COMMIT`），终点为 `commits[idx+count-1]`；`rm -f` 该 set 目录下旧 patch 后 `git format-patch --no-signature --zero-commit --no-numbered -o "${PATCHDIR}/<name>" "<base>..<end>"`。count 为 0 的 set 跳过。

flags 与现在完全一致，因此现有 8 个补丁重新导出后内容与文件名不变。

**`README.md`：** 更新「用法」「开发」「升级基线」三节里的 `patches/` 描述，加入 `SERIES` 与分目录说明，并在开头的功能列表里加上第二个功能（`X-Proxy-Meta`）的一段简介与 `specs/` 链接。

**验收：**

```bash
./scripts/setup.sh && ./scripts/apply.sh   # 8 个补丁应用成功
./scripts/export.sh                        # git status 干净，patch 文件无变化
```

---

## 步骤 1：把 TLV 送进 request context（commit 1）

`Carry the PROXY protocol metadata TLV to the request context`

**新增 `pkg/server/proxy_protocol_meta.go`：**

- `const proxyMetaHeader = "X-Proxy-Meta"`
- `const pp2TypeMeta proxyproto.PP2Type = 0xF3`
- `type proxyProtocolMetaKey struct{}`
- `func proxyProtocolConn(c net.Conn) *proxyproto.Conn`：循环剥包装，上限 16 跳。type switch 分支顺序：`*proxyproto.Conn`（命中即返回）→ `tcp.TLSConn`（取 `.WriteCloser`）→ `*writeCloserWrapper`（取 `.Conn`）→ `*trackedConnection`（取 `.WriteCloser`）→ `interface{ NetConn() net.Conn }`（覆盖 `*tls.Conn` 与两种 `PeekConn`）→ default 返回 `nil`。每轮开头判 `c == nil` 返回 `nil`。
- `func isPrintableASCII(v []byte) bool`：`len(v) == 0` 返回 `false`；任一字节 `< 0x20 || > 0x7E` 返回 `false`。
- `func addProxyProtocolMetaInContext(ctx context.Context, c net.Conn) context.Context`：取 `*proxyproto.Conn` → `ProxyHeader()`（nil 则原样返回）→ `TLVs()`（出错记 `log.Ctx(ctx).Debug()` 并原样返回）→ 收集 `Type == pp2TypeMeta` 且 `isPrintableASCII` 的 value；被丢弃的记一条 debug 日志；`len(values) == 0` 时不写 key。

注释只写 why：为什么要逐层剥包装、为什么选可打印 ASCII、为什么有跳数上限。

**改 `pkg/server/server_entrypoint_tcp.go`：** 在 `newHTTPServer` 里已有的匿名 `connContext.AddConnContextFunc(...)` 之后加一行：

```go
connContext.AddConnContextFunc(addProxyProtocolMetaInContext)
```

**新增 `pkg/server/proxy_protocol_meta_test.go`（本 commit 部分）：**

- `TestProxyProtocolConn`：表驱动。用本地 fake conn（实现 `tcp.WriteCloser`，`net.Pipe` 的一端 + `CloseWrite`）作底。用例覆盖：裸 `*proxyproto.Conn`；`&writeCloserWrapper{Conn: pConn}`；`&trackedConnection{WriteCloser: …}`；`tcp.TLSConn{WriteCloser: …}`；`tls.Server(…)`（不握手，只取 `NetConn()`）；本地定义的 `NetConn()` mock 包装（代表 `PeekConn` / `TLSStatefulConn` 这条接口路径，两者的构造函数在 `pkg/server/router/tcp` 里私有，无法在本包直接构造）；七层全叠的深链；不含 proxyproto 时返回 `nil`；返回自身的自引用包装不死循环。
- `TestIsPrintableASCII`：空、`0x1F`、`0x20`、`0x7E`、`0x7F`、`0x80`、CR/LF/NUL/TAB、正常字符串。
- `TestAddProxyProtocolMetaInContext`：用 `net.Pipe`，goroutine 里把 `proxyproto.Header{Version: 2, …}` + `SetTLVs(…)` 写进一端，另一端 `proxyproto.NewConn(…)`。覆盖 api.md 行为矩阵的 TLV 相关行：合法值、空值、含控制字符、含 `0x80+`、无 `0xF3`、多个 `0xF3`、多个里部分非法、v1 header（无 TLV）。

**验收：**

```bash
go test ./pkg/server/ -run 'ProxyProtocolConn|IsPrintableASCII|AddProxyProtocolMeta' -v
```

---

## 步骤 2：注入请求头（commit 2）

`Inject the PROXY protocol metadata as the X-Proxy-Meta header`

**改 `pkg/server/proxy_protocol_meta.go`：** 加

```go
func proxyProtocolMeta(next http.Handler) http.Handler
```

先无条件 `req.Header.Del(proxyMetaHeader)`，再把 context 里的 `[]string` 逐个 `req.Header.Add(...)`。注释记录为什么 `Del` 是无条件的。

**改 `pkg/server/server_entrypoint_tcp.go`：** alice 链改为

```go
next, err := alice.New(proxyProtocolMeta, requestdecorator.WrapHandler(reqDecorator)).Then(httpSwitcher)
```

**补测试到 `pkg/server/proxy_protocol_meta_test.go`：**

- `TestProxyProtocolMeta`：表驱动，用 `httptest.NewRequest` + `context.WithValue` 直接造 request。覆盖：context 无值 + 客户端带 `X-Proxy-Meta: evil` → 后端侧 `req.Header.Values` 为空；context 有一个值 + 客户端带伪造值 → 只剩注入值；context 有两个值 → 两个值且顺序一致；客户端用非规范大小写 `x-proxy-meta` 发送 → 同样被剥离（由 `http.Header` 的规范化保证，用例固定这一行为）。

**验收：**

```bash
go test ./pkg/server/ -run ProxyProtocolMeta -v
go build ./...
```

---

## 步骤 3：集成测试（commit 3）

`Add the X-Proxy-Meta integration test`

**改 `integration/proxy_protocol_test.go`：** 复用现有的 `ProxyProtocolSuite`、compose 项目（只有 whoami）与 `fixtures/proxy-protocol/proxy-protocol.toml`（8000 = trusted，9000 = not trusted）。

新增 helper，不改动既有 `proxyProtoRequest` 的签名：

```go
func proxyProtoRequestWithTLVs(address string, tlvs []proxyproto.TLV, extraHeaders string) (string, error)
```

写 v2 header + `SetTLVs`，请求行后追加 `extraHeaders`，其余逻辑与 `proxyProtoRequest` 一致。

新增用例，断言均针对 whoami 回显的请求头：

| 用例 | 输入 | 断言 |
| --- | --- | --- |
| `TestProxyProtocolTLVMeta` | 8000，`0xF3` = `tenant=acme` | 含 `X-Proxy-Meta: tenant=acme` |
| `TestProxyProtocolTLVMetaStripsClientHeader` | 8000，`0xF3` = `tenant=acme`，客户端另发 `X-Proxy-Meta: evil` | 含 `tenant=acme`，不含 `evil` |
| `TestProxyProtocolTLVMetaWithoutTLV` | 8000，无 TLV，客户端发 `X-Proxy-Meta: evil` | 不含 `X-Proxy-Meta` |
| `TestProxyProtocolTLVMetaInvalidValue` | 8000，`0xF3` = `bad\x00value` | 不含 `X-Proxy-Meta` |
| `TestProxyProtocolTLVMetaMultipleValues` | 8000，两个 `0xF3` = `first`、`second` | 两个值都在 |
| `TestProxyProtocolTLVMetaNotTrusted` | 9000，`0xF3` = `tenant=acme` | 不含 `X-Proxy-Meta` |

HTTPS 与 h2 路径不进集成测试：这两条路径相对明文只多了 `*tls.Conn` 与 `tcp.TLSConn` 两层包装，已由步骤 1 的 `TestProxyProtocolConn` 深链用例覆盖；明文路径本身已经过 `PeekConn` + `trackedConnection` + `writeCloserWrapper` 三层真实包装。

**验收：**

```bash
make binary
make test-integration TESTFLAGS="-test.run TestProxyProtocolSuite"
```

---

## 步骤 4：文档（commit 4）

`Document the X-Proxy-Meta header`

**改 `docs/content/reference/install-configuration/entrypoints.md`：** 在 proxyProtocol 相关段落（`proxyprotocol-and-load-balancers` 附近）新增一节 `PROXY Protocol Metadata`，内容为 api.md 第 1 节的英文版：`0xF3` TLV → `X-Proxy-Meta`、可打印 ASCII 约束、空值与非法值丢弃、多值语义、客户端同名头无条件剥离、信任模型沿用 `trustedIPs`、HTTP/3 只剥离不注入。附一个 `Header(...)` 路由规则示例。

**验收：** `make validate-files`（misspell / 生成文件检查），并 `make docs-serve` 预览新章节的渲染。

---

## 步骤 5：导出与全量验证

1. 在 `.references/traefik` 上确认 4 个新 commit 都带 `Assisted-by: Claude Opus 5` trailer，作者与既有补丁一致。
2. 把 `patches/SERIES` 的 `proxy-tlv-meta` 改成 `4`。
3. `./scripts/export.sh`，确认 `patches/appproto-fallback/` 无变化、`patches/proxy-tlv-meta/` 生成 4 个补丁。
4. 干净重放：

```bash
cd .references/traefik
git checkout --detach "$(tr -d '[:space:]' < ../../UPSTREAM)" && git branch -D appproto-fallback
cd ../..
./scripts/apply.sh && ./scripts/build.sh
```

5. 全量测试：

```bash
cd .references/traefik
go test ./pkg/server/...
make lint
make test-integration TESTFLAGS="-test.run 'TestProxyProtocolSuite|TestAppProtoSuite'"
```

6. 本仓库提交：步骤 0 的目录改造与脚本改动、`patches/SERIES`、`patches/proxy-tlv-meta/`、`README.md`、本 spec 目录。
