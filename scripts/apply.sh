#!/usr/bin/env bash
# 在基线 commit 上新建分支并按序号应用 patches/*.patch。
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "${WORKDIR}"

if [ -n "$(git status --porcelain)" ]; then
  echo "工作副本有未提交的改动，先清理再应用补丁" >&2
  exit 1
fi

git checkout -B "${BRANCH}" "${UPSTREAM_COMMIT}"

shopt -s nullglob
patches=("${PATCHDIR}"/*.patch)
if [ ${#patches[@]} -eq 0 ]; then
  echo "${PATCHDIR} 下没有 patch 文件"
  exit 0
fi

git am "${patches[@]}"
echo "已应用 ${#patches[@]} 个补丁到分支 ${BRANCH}"
