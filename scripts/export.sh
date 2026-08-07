#!/usr/bin/env bash
# 把 .references/traefik 中基线 commit 之后的提交导出为 patches/*.patch。
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "${WORKDIR}"

rm -f "${PATCHDIR}"/*.patch
mkdir -p "${PATCHDIR}"

git format-patch --no-signature --zero-commit --no-numbered \
  -o "${PATCHDIR}" "${UPSTREAM_COMMIT}..HEAD"

echo "已导出 $(ls -1 "${PATCHDIR}"/*.patch | wc -l) 个补丁到 ${PATCHDIR}"
