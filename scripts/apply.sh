#!/usr/bin/env bash
# 在基线 commit 上新建分支并按 patches/SERIES 的顺序应用各补丁集。
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "${WORKDIR}"

if [ -n "$(git status --porcelain)" ]; then
  echo "工作副本有未提交的改动，先清理再应用补丁" >&2
  exit 1
fi

shopt -s nullglob
patches=()
while read -r name count; do
  set_patches=("${PATCHDIR}/${name}"/*.patch)
  if [ ${#set_patches[@]} -ne "${count}" ]; then
    echo "补丁集 ${name} 实际有 ${#set_patches[@]} 个 patch，SERIES 里记的是 ${count}，先更新 SERIES" >&2
    exit 1
  fi
  patches+=("${set_patches[@]}")
done < <(read_series)

if [ ${#patches[@]} -eq 0 ]; then
  echo "${PATCHDIR} 下没有 patch 文件"
  exit 0
fi

git checkout -B "${BRANCH}" "${UPSTREAM_COMMIT}"

# 各 set 的补丁上下文是线性的，必须一次性按序应用，同时保留原有的冲突处理体验。
git am "${patches[@]}"
echo "已应用 ${#patches[@]} 个补丁到分支 ${BRANCH}"
