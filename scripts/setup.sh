#!/usr/bin/env bash
# 把上游 traefik clone/更新到 .references/traefik，并 checkout 到 UPSTREAM 记录的 commit。
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [ ! -d "${WORKDIR}/.git" ]; then
  mkdir -p "$(dirname "${WORKDIR}")"
  git clone "${UPSTREAM_URL}" "${WORKDIR}"
fi

cd "${WORKDIR}"
git fetch origin

if ! git cat-file -e "${UPSTREAM_COMMIT}^{commit}" 2>/dev/null; then
  echo "commit ${UPSTREAM_COMMIT} not found in ${WORKDIR}" >&2
  exit 1
fi

git checkout --detach "${UPSTREAM_COMMIT}"
echo "工作副本已就绪：${WORKDIR} @ ${UPSTREAM_COMMIT}"
