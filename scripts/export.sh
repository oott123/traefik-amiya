#!/usr/bin/env bash
# 把 .references/traefik 中基线 commit 之后的提交按 patches/SERIES 切段导出到各补丁集目录。
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "${WORKDIR}"

mapfile -t commits < <(git rev-list --reverse "${UPSTREAM_COMMIT}..HEAD")

total=0
while read -r name count; do
  total=$((total + count))
done < <(read_series)

# SERIES 里的数字是手工维护的，这个校验是防忘的闸门。
if [ "${total}" -ne "${#commits[@]}" ]; then
  echo "SERIES 声明了 ${total} 个 commit，${UPSTREAM_COMMIT}..HEAD 实际有 ${#commits[@]} 个，先更新 SERIES" >&2
  exit 1
fi

idx=0
base="${UPSTREAM_COMMIT}"
exported=0
while read -r name count; do
  if [ "${count}" -eq 0 ]; then
    continue
  fi

  end="${commits[$((idx + count - 1))]}"
  mkdir -p "${PATCHDIR}/${name}"
  rm -f "${PATCHDIR}/${name}"/*.patch
  git format-patch --no-signature --zero-commit --no-numbered \
    -o "${PATCHDIR}/${name}" "${base}..${end}" >/dev/null

  echo "已导出 ${count} 个补丁到 ${PATCHDIR}/${name}"
  base="${end}"
  idx=$((idx + count))
  exported=$((exported + count))
done < <(read_series)

echo "共导出 ${exported} 个补丁"
