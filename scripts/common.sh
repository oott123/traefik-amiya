#!/usr/bin/env bash
# 所有脚本共享的路径与常量定义。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${REPO_ROOT}/.references/traefik"
PATCHDIR="${REPO_ROOT}/patches"
SERIESFILE="${PATCHDIR}/SERIES"
UPSTREAM_URL="https://github.com/traefik/traefik"
UPSTREAM_COMMIT="$(tr -d '[:space:]' < "${REPO_ROOT}/UPSTREAM")"
BRANCH="appproto-fallback"

# read_series 逐行输出 SERIES 里的 "<set 名> <commit 数>"，跳过空行与注释。
# 行序即补丁集的应用顺序，各 set 在同一分支上线性叠放。
read_series() {
  local name count
  while read -r name count; do
    [ -z "${name}" ] && continue
    case "${name}" in \#*) continue ;; esac
    echo "${name} ${count}"
  done < "${SERIESFILE}"
}
