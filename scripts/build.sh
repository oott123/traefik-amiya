#!/usr/bin/env bash
# 在工作副本里构建 traefik 二进制。
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "${WORKDIR}"
make binary
echo "二进制：${WORKDIR}/dist/traefik"
