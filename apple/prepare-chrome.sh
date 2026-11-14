#!/bin/sh
set -eu
project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
node_binary="${WORKBENCH_NODE_BINARY:-$(command -v node || true)}"
if test -z "$node_binary"; then
  printf '%s\n' '准备 Chrome 工具需要官方 Node.js 24.11+，也可设置 WORKBENCH_NODE_BINARY。' >&2
  exit 1
fi
exec "$node_binary" "$project/tools/chrome/prepare.mjs"
