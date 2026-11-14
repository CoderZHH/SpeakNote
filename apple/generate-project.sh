#!/bin/sh
# Regeneration is a development operation; Xcode Run uses the committed project directly.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
xcodegen generate --spec "$root/project.yml"
python3 "$root/check-project.py"
