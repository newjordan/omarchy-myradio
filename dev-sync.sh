#!/usr/bin/env bash
# Copy the working tree into the Omarchy plugin folder (the shell reloads it on change).
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
dst="$HOME/.config/omarchy/plugins/newjordan.myradio"
[[ -L $dst ]] && rm "$dst"
mkdir -p "$dst"
rsync -a --delete --exclude .git --exclude dev-sync.sh --exclude docs "$src/" "$dst/"
