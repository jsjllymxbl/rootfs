#!/usr/bin/env bash
# 按各层 requires 展开成依赖在前、去重的层列表；base 固定最先叠加，不输出。
# 用法: SRC_DIR=<仓库> resolve-layers.sh [层...]
set -euo pipefail

SRC_DIR=${SRC_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
CONFIG_DIR=${CONFIG_DIR:-$SRC_DIR/config}

seen=' '
result=' '

read_requires() {
	local f=$CONFIG_DIR/profiles/$1/requires
	[ -f "$f" ] || return 0
	sed -e 's/#.*//' "$f" | awk 'NF { print $1 }'
}

visit() {
	local layer=$1 dep reqs
	case $layer in
		''|base) return 0 ;;
	esac
	case $seen in
		*" $layer "*) return 0 ;;
	esac
	if [ ! -d "$CONFIG_DIR/profiles/$layer" ]; then
		printf 'ERROR: 没有 profile %s（可用: %s）\n' "$layer" \
			"$(ls -1 "$CONFIG_DIR/profiles" 2>/dev/null | tr '\n' ' ')" >&2
		exit 1
	fi
	reqs=$(read_requires "$layer")
	for dep in $reqs; do
		if [ "$dep" = "$layer" ]; then
			printf 'ERROR: profile %s 的 requires 引用了自己\n' "$layer" >&2
			exit 1
		fi
		visit "$dep"
	done
	seen="$seen$layer "
	result="$result$layer "
}

for layer in "$@"; do
	visit "$layer"
done

printf '%s\n' "${result# }" | sed 's/ *$//'
