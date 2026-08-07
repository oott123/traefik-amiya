#!/usr/bin/env bash
# 所有脚本共享的路径与常量定义。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${REPO_ROOT}/.references/traefik"
PATCHDIR="${REPO_ROOT}/patches"
UPSTREAM_URL="https://github.com/traefik/traefik"
UPSTREAM_COMMIT="$(tr -d '[:space:]' < "${REPO_ROOT}/UPSTREAM")"
BRANCH="appproto-fallback"
