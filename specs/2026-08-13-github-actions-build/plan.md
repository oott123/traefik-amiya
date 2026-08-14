# 执行计划

新增一个工作流文件 `.github/workflows/build.yaml`，不改任何现有脚本与补丁。所有 action 按仓库
既有惯例 pin 到完整 SHA；下列已在本仓库 `.references/traefik/.github/workflows/` 中出现过的
action 直接沿用其 SHA，docker 相关三个 action 在实现时从 marketplace 取当前 SHA 再 pin。

已确认可复用的 SHA：

| action | SHA |
| --- | --- |
| actions/checkout | `8e8c483db84b4bee98b60c0593521ed34d9990e8`（v6.0.1） |
| actions/setup-go | `4a3601121dd01d1626a1e23e37211e3254c1c06c`（v6.4.0） |
| actions/setup-node | `6044e13b5dc448c55e2357c09f80417699197238`（v6.2.0） |
| actions/download-artifact | `37930b1c2abaa49bbe596cd826c3c89aef350131`（v7.0.0） |
| actions/upload-artifact | `b7c566a772e6b6bfb58ed0dc250532a479d7789f`（v6.0.0） |
| actions/cache/restore | `8b402f58fbc84540c8b491a91e594a4576fec3d7`（v5.0.2） |

二进制在 job 间传递时，先在 build job 里 `cp` 成扁平文件名再上传，下载后显式 `cp`/`mv` 到目标
路径，不依赖 `upload/download-artifact` 的路径保留行为。

---

## 步骤 1：工作流骨架

创建 `.github/workflows/build.yaml`：

```yaml
name: Build
on:
  push:
    branches: [master, main]
    tags: ['v*']
  workflow_dispatch:

permissions:
  contents: write
  packages: write

jobs:
  prepare:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    outputs:
      version: ${{ steps.version.outputs.version }}
    steps:
      # … 见步骤 2
  build:
    needs: prepare
    runs-on: ubuntu-latest
    timeout-minutes: 30
    strategy:
      matrix:
        arch: [amd64, arm64]
    steps:
      # … 见步骤 3
  docker:
    needs: [prepare, build]
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      # … 见步骤 4
  release:
    if: github.ref_type == 'tag'
    needs: [prepare, build]
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      # … 见步骤 5
```

## 步骤 2：prepare job

```yaml
    steps:
      - name: Check out code
        uses: actions/checkout@8e8c483db84b4bee98b60c0593521ed34d9990e8 # v6.0.1
        with:
          persist-credentials: false

      - name: Clone upstream and checkout baseline
        run: ./scripts/setup.sh

      - name: Apply patches
        run: ./scripts/apply.sh

      - name: Enable corepack
        run: corepack enable

      - name: Set up Node
        uses: actions/setup-node@6044e13b5dc448c55e2357c09f80417699197238 # v6.2.0
        with:
          node-version-file: .references/traefik/webui/.nvmrc
          cache: yarn
          cache-dependency-path: .references/traefik/webui/yarn.lock

      - name: Build webui
        working-directory: .references/traefik/webui
        run: |
          yarn install --immutable
          yarn build

      - name: Package patched source
        run: |
          tar --exclude=.git --exclude=webui/node_modules --exclude=.yarn --exclude=dist \
            -czf patched-source.tar.gz -C .references/traefik .

      - name: Upload patched source
        uses: actions/upload-artifact@b7c566a772e6b6bfb58ed0dc250532a479d7789f # v6.0.0
        with:
          name: patched-source
          path: patched-source.tar.gz
          retention-days: 1

      - name: Compute version
        id: version
        run: |
          if [ "$GITHUB_REF_TYPE" = "tag" ]; then
            echo "version=$GITHUB_REF_NAME" >> "$GITHUB_OUTPUT"
          else
            echo "version=${GITHUB_REF_NAME}-${GITHUB_SHA:0:8}" >> "$GITHUB_OUTPUT"
          fi
```

## 步骤 3：build job（matrix）

```yaml
    steps:
      - name: Download patched source
        uses: actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131 # v7.0.0
        with:
          name: patched-source

      - name: Untar patched source
        run: |
          mkdir -p traefik
          tar xzf patched-source.tar.gz -C traefik

      - name: Set up Go
        uses: actions/setup-go@4a3601121dd01d1626a1e23e37211e3254c1c06c # v6.4.0
        with:
          go-version-file: traefik/.go-version
          cache: false

      - name: Restore go modules cache
        uses: actions/cache/restore@8b402f58fbc84540c8b491a91e594a4576fec3d7 # v5.0.2
        with:
          path: ~/go/pkg/mod
          key: ${{ runner.os }}-go-mod-${{ hashFiles('traefik/go.sum') }}
          restore-keys: |
            ${{ runner.os }}-go-mod-

      - name: Build binary
        working-directory: traefik
        env:
          VERSION: ${{ needs.prepare.outputs.version }}
          GOOS: linux
          GOARCH: ${{ matrix.arch }}
          CGO_ENABLED: '0'
        run: make binary

      - name: Stage binary
        run: cp traefik/dist/linux/${{ matrix.arch }}/traefik traefik-${{ matrix.arch }}

      - name: Upload binary
        uses: actions/upload-artifact@b7c566a772e6b6bfb58ed0dc250532a479d7789f # v6.0.0
        with:
          name: linux-${{ matrix.arch }}
          path: traefik-${{ matrix.arch }}
          retention-days: 1
```

## 步骤 4：docker job

```yaml
    steps:
      - name: Download patched source
        uses: actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131 # v7.0.0
        with:
          name: patched-source

      - name: Untar patched source
        run: |
          mkdir -p traefik
          tar xzf patched-source.tar.gz -C traefik

      - name: Download linux-amd64 binary
        uses: actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131 # v7.0.0
        with:
          name: linux-amd64
          path: binaries

      - name: Download linux-arm64 binary
        uses: actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131 # v7.0.0
        with:
          name: linux-arm64
          path: binaries

      - name: Place binaries for Dockerfile
        run: |
          mkdir -p traefik/dist/linux/amd64 traefik/dist/linux/arm64
          cp binaries/traefik-amd64 traefik/dist/linux/amd64/traefik
          cp binaries/traefik-arm64 traefik/dist/linux/arm64/traefik

      - name: Set up QEMU
        uses: docker/setup-qemu-action@<SHA> # v3

      - name: Set up buildx
        uses: docker/setup-buildx-action@<SHA> # v3

      - name: Log in to GHCR
        uses: docker/login-action@<SHA> # v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        working-directory: traefik
        env:
          IMAGE: ghcr.io/${{ github.repository }}
          VERSION: ${{ needs.prepare.outputs.version }}
        run: |
          args=()
          if [ "$GITHUB_REF_TYPE" = "tag" ]; then
            args+=("-t" "${IMAGE}:${VERSION}")
          fi
          args+=("-t" "${IMAGE}:latest")
          docker buildx build --push --platform linux/amd64,linux/arm64 \
            "${args[@]}" -f Dockerfile .
```

## 步骤 5：release job

```yaml
    steps:
      - name: Download linux-amd64 binary
        uses: actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131 # v7.0.0
        with:
          name: linux-amd64
          path: binaries

      - name: Download linux-arm64 binary
        uses: actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131 # v7.0.0
        with:
          name: linux-arm64
          path: binaries

      - name: Download patched source
        uses: actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131 # v7.0.0
        with:
          name: patched-source

      - name: Package release assets
        env:
          VERSION: ${{ needs.prepare.outputs.version }}
        run: |
          mkdir -p release
          tar xzf patched-source.tar.gz -C release ./LICENSE.md ./CHANGELOG.md
          for arch in amd64 arm64; do
            cp "binaries/traefik-${arch}" release/traefik
            tar czf "release/traefik_${VERSION}_linux_${arch}.tar.gz" \
              -C release traefik LICENSE.md CHANGELOG.md
            rm -f release/traefik
          done
          (cd release && sha256sum traefik_*.tar.gz) > "release/traefik_${VERSION}_checksums.txt"

      - name: Publish release
        env:
          GH_TOKEN: ${{ github.token }}
          VERSION: ${{ needs.prepare.outputs.version }}
        run: |
          gh release create "$VERSION" release/traefik_*.tar.gz release/*_checksums.txt \
            --title "$VERSION" --generate-notes
```

## 步骤 6：README 更新

在 `README.md` 的「用法」之后新增「CI 构建」小节：说明 `.github/workflows/build.yaml` 在 push
分支/tag 时构建并推 GHCR 镜像（分支 → `latest`，tag → `<tag>`+`latest`），tag 额外建 GitHub
release；镜像名 `ghcr.io/<owner>/traefik-app-protocol`，需在仓库开启 `packages: write` 权限。

## 验证

1. YAML 语法：`yamllint` 或 `actionlint` 校验 `.github/workflows/build.yaml`。
2. 本地重放 prepare 的打包步骤（README 已证明 setup/apply/build 可用，此处覆盖打包与 webui）：

   ```bash
   ./scripts/setup.sh && ./scripts/apply.sh
   tar --exclude=.git --exclude=webui/node_modules --exclude=.yarn --exclude=dist \
     -czf /tmp/patched-source.tar.gz -C .references/traefik .
   tar tzf /tmp/patched-source.tar.gz | grep -c '^\./webui/static/'   # > 0
   tar tzf /tmp/patched-source.tar.gz | grep -c '^\./\.git/'          # = 0
   ```

3. 本地无 `.git` 构建验证（模拟 build job）：

   ```bash
   rm -rf /tmp/t && mkdir /tmp/t && tar xzf /tmp/patched-source.tar.gz -C /tmp/t
   cd /tmp/t && VERSION=test-0000000 GOOS=linux GOARCH=amd64 CGO_ENABLED=0 make binary
   ls -la dist/linux/amd64/traefik
   ```

4. 镜像构建冒烟（有 Docker 时）：

   ```bash
   cd /tmp/t && mkdir -p dist/linux/amd64 dist/linux/arm64
   cp dist/linux/amd64/traefik dist/linux/arm64/traefik   # 占位；真实 arm64 由 build job 产出
   docker buildx build --platform linux/amd64 -t test-image -f Dockerfile .
   ```
