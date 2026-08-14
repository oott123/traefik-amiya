# 需求：GitHub Actions 构建 traefik（补丁集 → 镜像 / artifacts / release）

## 原始需求

写一个 GitHub Actions 构建 traefik：采用仓库中记录的 commit（`UPSTREAM` 文件），应用 patch
（`patches/SERIES` + `patches/*/`），构建 Docker 镜像、GitHub Actions artifacts、GitHub releases
（如果是有 tag）。可以参考 `.references/traefik/.github/workflows/` 里有没有现成的可以复用。

## 参考（可复用来源）

`.references/traefik/.github/workflows/` 下与构建/发布直接相关的工作流：

- `build.yaml`：PR/分支构建，`build-webui`（复用 `template-webui.yaml`）+ `make binary` 全 os/arch 矩阵。
- `release.yaml`：tag 触发，`build-webui` + goreleaser（`internal/release` 生成配置）+ `gh release create`。
- `template-webui.yaml`：可复用工作流，yarn 构建 webui 静态资源并打包 `webui.tar.gz`。

本仓库与上游的关键差异：traefik 源码不入库（`.references/` 被 `.gitignore` 忽略），CI 必须先
clone 上游、checkout `UPSTREAM` commit、再 `git am` 补丁。补丁集应用已有 `scripts/setup.sh` +
`scripts/apply.sh` 可复用。

## 澄清后的决策

| 决策点 | 结论 |
| --- | --- |
| 镜像 registry | GHCR，镜像名 `ghcr.io/${{ github.repository }}`（`ghcr.io/<owner>/traefik-app-protocol`），用内置 `GITHUB_TOKEN` 推送 |
| 二进制平台 | 仅 linux amd64 + arm64（与 Docker 多架构一致） |
| 触发条件 | push 分支（`master`/`main`）+ push tag `v*` + `workflow_dispatch`；不触发 PR |
| 镜像 tag | 分支 → `latest`；tag → `<tag>` + `latest` |
| 版本号 | tag → `github.ref_name`；分支 → `<ref_name>-<8 位 sha>`，注入 `pkg/version.Version` 并用于产物文件名 |
| GitHub release | tag 时创建，附件为 linux amd64/arm64 两个 tar.gz + checksums |
| goreleaser | 不用。平台只有两个，直接用 `make binary` + 归档步骤，避免引入 traefik 的 `internal/release` 与 goreleaser-action |
