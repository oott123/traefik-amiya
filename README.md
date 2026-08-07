# traepxy

针对 [Traefik](https://github.com/traefik/traefik) 的补丁集：**TLS 解密后按应用层协议特征回退到 TCP 后端**。

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

## 上游基线

`UPSTREAM` 文件记录了补丁针对的上游 commit：

```
3f3466a3c4a5d48d7068635f084d0f403c7039d2   # v3.7.10-31-g3f3466a3c，2026-08-04
```

构建需要 Go 1.26。

## 用法

```bash
./scripts/setup.sh    # clone/更新上游到 .references/traefik 并 checkout 基线 commit
./scripts/apply.sh    # 在基线上新建 appproto-fallback 分支并 git am patches/*.patch
./scripts/build.sh    # 在工作副本里 make binary，产物在 .references/traefik/dist/traefik
```

`.references/` 不入库。

## 开发

改动直接在 `.references/traefik` 的 `appproto-fallback` 分支上做，一个功能步骤一个 commit，
完成后导出：

```bash
./scripts/export.sh   # 用 git format-patch 重新生成 patches/
```

导出使用 `--zero-commit --no-signature`，因此只要提交内容不变，patch 文件就是稳定的。

## 升级基线

1. 修改 `UPSTREAM` 为新的 commit。
2. `./scripts/setup.sh`
3. `./scripts/apply.sh`，若有冲突就在工作副本里解决（`git am --continue`）。
4. `./scripts/export.sh` 重新导出。
