# 设计：GitHub Actions 构建与发布

上游基线 `3f3466a3c4a5d48d7068635f084d0f403c7039d2`（`UPSTREAM`）。补丁集 `appproto-fallback`(8) +
`proxy-tlv-meta`(4)，应用顺序由 `patches/SERIES` 声明。本设计新增一条 GitHub Actions 工作流，把
「clone 上游 → 打补丁 → 构建二进制 → 构建镜像 → 发布 release」串起来。

## 1. 现状与约束

- 本仓库只存补丁、脚本、`UPSTREAM`，不含 traefik 源码（`.references/` 被 `.gitignore` 忽略）。
  CI 必须从上游 clone。
- `scripts/setup.sh` 已实现 clone + checkout `UPSTREAM` commit；`scripts/apply.sh` 已实现按
  `SERIES` `git am`。CI 直接复用这两个脚本，不重写逻辑。
- 上游 `Makefile` 的 `binary` 目标依赖 `generate-webui`（需 `webui/static/index.html` 存在）与
  `dist`，然后 `CGO_ENABLED=0 go build`，产物在 `dist/${GOOS}/${GOARCH}/traefik`。**不跑
  `go generate`**（那是 `default`/`crossbinary-default` 的依赖；上游 `build.yaml` 的 PR 构建同样
  不跑，证明 `make binary` 不需要）。
- webui 静态资源经 `webui/embed.go` 的 `go:embed static` 打进二进制；缺 `webui/static/` 会让
  `go build` 失败。`webui/vite.config.ts` 的 `outDir` 即 `./static`。
- 上游 `Dockerfile`：`COPY ./dist/$TARGETPLATFORM/traefik /`，基础镜像 `alpine:3.24`。构建镜像
  只要求把预编译二进制放到 `dist/linux/{amd64,arm64}/traefik`，镜像内不再编译。

## 2. 决策

| 决策点 | 结论 |
| --- | --- |
| 镜像 registry | GHCR，镜像名 `ghcr.io/${{ github.repository }}`（`ghcr.io/<owner>/traefik-app-protocol`），`GITHUB_TOKEN` 推送，权限 `packages: write` |
| 二进制平台 | 仅 linux amd64 + arm64，与镜像多架构一致 |
| 触发 | push 分支（`master`/`main`）+ push tag `v*` + `workflow_dispatch`，不触发 PR |
| 镜像 tag | 分支 → `latest`；tag → `<tag>` + `latest` |
| 版本号 `VERSION` | tag → `github.ref_name`；分支 → `<ref_name>-<8 位 sha>`。注入 `pkg/version.Version` 与产物文件名 |
| release | tag 时 `gh release create <tag>`，附件为两个平台 tar.gz + checksums |
| goreleaser | 不用。平台只有两个，`make binary` + 一个归档步骤即可，不引入 `internal/release` 与 goreleaser-action |
| 补丁应用 | 复用 `scripts/setup.sh` + `scripts/apply.sh`，不改这两个脚本 |

## 3. 工作流结构

单文件 `.github/workflows/build.yaml`，四个 job：

```
prepare ──► build (matrix: amd64/arm64) ──┬──► docker
                                          └──► release   (仅 tag)
```

- **prepare**：checkout 本仓库 → `setup.sh` + `apply.sh` → 构建 webui（yarn）→ 打包
  `patched-source.tar.gz` → 输出 `version`。
- **build**：下载源码包 → `setup-go` → `make binary`（每个 arch 一个 matrix job）→ 上传二进制
  artifact。
- **docker**：下载源码包（取 `Dockerfile`）+ 两个二进制 → buildx 多架构构建 → 推 GHCR。
- **release**：仅 tag。下载源码包（取 `LICENSE.md`/`CHANGELOG.md`）+ 两个二进制 → 归档 +
  checksums → `gh release create`。

### 源码传递

上游源码在 CI 里只 clone 一次（`prepare`），打包成 `patched-source.tar.gz` 在 job 间传递，避免
每个 job 重复 clone。tar 排除 `.git`、`webui/node_modules`、`.yarn`、`dist`；webui 的 `static/`
在打包前已由 yarn 生成，包含在内。

剥掉 `.git` 后 `make binary` 仍可构建：`Makefile` 里 `SHA`/`TAG_NAME` 用 `$(shell git …)` 取兜底
版本号，`.git` 缺失时为空，但可用环境变量 `VERSION` 覆盖（`VERSION := $(if $(VERSION),…)`）。
`make binary` 不读 git 历史、不跑 `go generate`，`go:embed static` 所需的文件已随包带上。因此
构建 job 只需显式传 `VERSION`。

## 4. 各 job 细节

### 4.1 prepare

1. `actions/checkout` 检出本仓库（fork 自身，含 scripts/patches/UPSTREAM）。
2. `./scripts/setup.sh`：clone 上游到 `.references/traefik` 并 checkout `UPSTREAM` commit。
3. `./scripts/apply.sh`：按 `SERIES` `git am` 全部补丁。
4. `actions/setup-node`（`node-version-file: .references/traefik/webui/.nvmrc`，yarn cache），
   `corepack enable`，在 `.references/traefik/webui` 下 `yarn install --immutable && yarn build`。
5. 打包：`tar --exclude=.git --exclude=webui/node_modules --exclude=.yarn --exclude=dist -czf
   patched-source.tar.gz -C .references/traefik .`，上传为 artifact `patched-source`。
6. 计算 `VERSION` 写入 job output `version`：

   ```bash
   if [ "$GITHUB_REF_TYPE" = "tag" ]; then echo "version=$GITHUB_REF_NAME"; \
   else echo "version=${GITHUB_REF_NAME}-${GITHUB_SHA:0:8}"; fi >> "$GITHUB_OUTPUT"
   ```

### 4.2 build（matrix: amd64 / arm64）

1. `download-artifact` 拉 `patched-source` 并解包到工作区根。
2. `actions/setup-go`（`go-version-file: traefik/.go-version`，即 `.go-version` 的 `1.26`）。
3. `actions/cache/restore` 恢复 `~/go/pkg/mod`（key 含 `hashFiles('traefik/go.sum')`）。
4. `VERSION="${{ needs.prepare.outputs.version }}" GOOS=linux GOARCH=${{ matrix.arch }} make
   binary`，产物 `dist/linux/<arch>/traefik`。
5. 上传 `dist/linux/<arch>/traefik` 为 artifact `linux-<arch>`。

### 4.3 docker

1. 解包 `patched-source`（取 `Dockerfile`）。
2. 下载 `linux-amd64`、`linux-arm64`，分别放到 `dist/linux/amd64/traefik` 与
   `dist/linux/arm64/traefik`。
3. `docker/setup-buildx-action` + `docker/setup-qemu-action`（arm64 的 `RUN apk add` 需 qemu 仿真）
   + `docker/login-action`（`registry: ghcr.io`，`username: github.actor`，
   `password: secrets.GITHUB_TOKEN`）。
4. buildx 多架构构建并推送：

   ```bash
   tags=("ghcr.io/${{ github.repository }}:latest")
   [ "$GITHUB_REF_TYPE" = "tag" ] && tags+=("ghcr.io/${{ github.repository }}:$GITHUB_REF_NAME")
   docker buildx build --push --platform linux/amd64,linux/arm64 \
     $(for t in "${tags[@]}"; do printf -- '-t %s ' "$t"; done) -f Dockerfile .
   ```

### 4.4 release（`if: github.ref_type == 'tag'`）

1. 下载 `linux-amd64`、`linux-arm64`，解包 `patched-source`（取 `LICENSE.md`/`CHANGELOG.md`）。
2. 每个平台：`traefik` + `LICENSE.md` + `CHANGELOG.md` 打进
   `traefik_${VERSION}_linux_<arch>.tar.gz`。
3. `sha256sum` 生成 `traefik_${VERSION}_checksums.txt`。
4. `gh release create "$VERSION" … 附件 … --title "$VERSION" --generate-notes`。

## 5. 权限与 secrets

- 工作流 `permissions: contents: write, packages: write`：`packages: write` 推 GHCR，
  `contents: write` 供 `gh release create`。
- 无额外 secret。GHCR 用内置 `GITHUB_TOKEN`。

## 6. 不复用/省略的部分

- **不用 goreleaser**：平台只有两个，goreleaser 的 `internal/release` 配置生成 + 多 job 切分是
  为 17 平台矩阵服务的，对本仓库是多余抽象。
- **不用 `template-webui.yaml` 可复用工作流**：webui 构建在本仓库只出现一次，直接内联到
  `prepare`。
- **不复制上游 `build.yaml`/`release.yaml` 的 `build-webui` + `release` 双工作流切分**：本仓库的
  branch/tag 差异只在「是否建 release + 镜像 tag」，用一个工作流 + 条件 step/job 更省。
- **不引入 safe-chain**：`template-webui.yaml` 里的 `@aikidosec/safe-chain` 是 traefik 组织自身的
  供应链防护，本仓库不需要。
