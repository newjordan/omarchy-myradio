#!/usr/bin/env bash
# Copy the working tree into the Omarchy plugin folder (the shell reloads it on change).
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
dst="${HOME}/.config/omarchy/plugins/newjordan.myradio"
if [[ -L "$dst" ]]; then
  rm "$dst"
fi
mkdir -p "$dst"
rsync -a --delete \
  --exclude .git \
  --exclude .github \
  --exclude tests \
  --exclude docs \
  --exclude dev-sync.sh \
  --exclude Makefile \
  --exclude .shellcheckrc \
  --exclude .gitignore \
  "$src/" "$dst/"
