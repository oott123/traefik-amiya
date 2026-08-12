# traepxy

针对 [Traefik](https://github.com/traefik/traefik) 的补丁集，目前包含两个功能。

## 功能一：TLS 解密后按应用层协议特征回退到 TCP 后端

新增一个 TCP 路由匹配器 `AppProtocol`，在 TLS 终止之后嗅探解密流的头部字节，判定它是
`http/1.1` / `h2` / `unknown`。命中的连接把**解密后的明文流**交给路由指定的 TCP service，
未命中的连接维持原有的 HTTPS 处理路径（HTTP/1.1 与 HTTP/2 均照常工作）。

典型用途是给一个正常的 HTTPS 站点挂一个"非 HTTP 载荷"的兜底后端：

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

设计与接口细节见 `specs/2026-08-07-post-tls-appprotocol-fallback/`。

## 功能二：把 PROXY protocol v2 的 TLV 透传为 `X-Proxy-Meta` 请求头

入站 PROXY protocol v2 header 里类型为 `0xF3` 的 TLV，其 value 被注入为请求头
`X-Proxy-Meta`，注入发生在 HTTP router 匹配之前，因此路由规则和中间件都能用上它。
value 必须是非空的可打印 ASCII（`0x20`–`0x7E`），否则整条丢弃。客户端发来的同名头在所有
entrypoint 上无条件剥离，后端见到这个头就一定来自 TLV。可信性沿用 entrypoint 已有的
`proxyProtocol.trustedIPs` / `insecure`，不引入新配置项。

```yaml
entryPoints:
  web:
    address: ":80"
    proxyProtocol:
      trustedIPs:
        - "10.0.0.0/8"

http:
  routers:
    tenant-acme:
      entryPoints: [web]
      rule: "Host(`example.com`) && Header(`X-Proxy-Meta`, `tenant=acme`)"
      service: acme-backend
```

设计与接口细节见 `specs/2026-08-11-proxy-protocol-tlv-meta/`。

## 上游基线

`UPSTREAM` 文件记录了补丁针对的上游 commit：

```
3f3466a3c4a5d48d7068635f084d0f403c7039d2   # v3.7.10-31-g3f3466a3c，2026-08-04
```

构建需要 Go 1.26。

## 用法

```bash
./scripts/setup.sh    # clone/更新上游到 .references/traefik 并 checkout 基线 commit
./scripts/apply.sh    # 在基线上新建 appproto-fallback 分支并按 SERIES 顺序 git am 所有补丁
./scripts/build.sh    # 在工作副本里 make binary，产物在 .references/traefik/dist/traefik
```

`.references/` 不入库。

## 补丁集布局

`patches/` 按功能分目录，应用顺序由 `patches/SERIES` 声明，一行一个 `<set 名> <commit 数>`：

```
patches/SERIES
patches/appproto-fallback/0001-….patch … 0008-….patch
patches/proxy-tlv-meta/0001-….patch … 0004-….patch
```

两个 set 在同一个开发分支上线性叠放，功能上互不依赖，但补丁上下文是线性的，**必须按
`SERIES` 顺序整体应用**——单独 `git am patches/proxy-tlv-meta/*.patch` 到基线不保证成功。
分目录只是为了让两个功能的补丁在仓库里分开、各自独立编号和阅读。

`SERIES` 里的 commit 数是手工维护的：`apply.sh` 校验每个目录的 patch 文件数与之相等，
`export.sh` 校验各 count 之和等于 `UPSTREAM..HEAD` 的实际 commit 数，不等就报错要求先更新。

## 开发

改动直接在 `.references/traefik` 的 `appproto-fallback` 分支上做，一个功能步骤一个 commit。
新增功能时在 `SERIES` 末尾追加一行（新 set 叠在已有 set 之后），改完 commit 数后导出：

```bash
./scripts/export.sh   # 按 SERIES 切段，用 git format-patch 重新生成各 set 目录
```

导出使用 `--zero-commit --no-signature`，因此只要提交内容不变，patch 文件就是稳定的。

## 升级基线

1. 修改 `UPSTREAM` 为新的 commit。
2. `./scripts/setup.sh`
3. `./scripts/apply.sh`，若有冲突就在工作副本里解决（`git am --continue`）。
4. `./scripts/export.sh` 重新导出。各 set 的 commit 数不变，因此 `SERIES` 不用动。
