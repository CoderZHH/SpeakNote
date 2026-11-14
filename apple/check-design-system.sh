#!/bin/sh
# Content lists must opt into the shared layout contract. The native sidebar is
# intentionally a separate system role and is the only host-level exception.
set -eu
command -v rg >/dev/null 2>&1 || { printf "%s\n" "需要 ripgrep 才能运行设计容器检查。" >&2; exit 2; }
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
features="$root/apple/Packages/WorkBenchKit/Sources/WorkBenchKit/Features"
if rg -n '^\s*List(\(|\s*\{)' "$features" -g '*.swift' -g '!AppRoot.swift' -g '!WorkbenchDesign.swift'; then
  printf '%s\n' '业务列表请使用 WorkspaceList，统一边距、行高和分割线。' >&2
  exit 1
fi
if rg --multiline -n 'ToolbarItem\(placement: \.secondaryAction\)\s*\{\s*Menu' "$features" -g '*.swift'; then
  printf '%s\n' '工具栏 Menu 请直接使用 primaryAction，避免系统“更多”再嵌套一个菜单。' >&2
  exit 1
fi
if rg --multiline -n 'ControlGroup\s*\{\s*TaskImportanceChoices' "$features" -g '*.swift'; then
  printf '%s\n' '重要程度色板请使用 ItemActionPanel，系统菜单 ControlGroup 会丢失纯图标内容和颜色。' >&2
  exit 1
fi
printf '%s\n' '共享列表容器与工具栏菜单检查通过。'
if rg -n 'MenuBarExtra|FocusMenuBarLabel' "$root/apple/Hosts" -g '*.swift'; then
  printf '%s\n' 'Mac 专注菜单栏必须使用 FocusStatusItemController；动态 SwiftUI 标签会触发菜单栏更新内存失控。' >&2
  exit 1
fi
