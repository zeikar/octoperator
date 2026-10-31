#!/usr/bin/env bash
# snap.sh — back up config files: copy every *.conf file directly in SRC to DEST/<name>.bak.
set -u

if [ $# -ne 2 ]; then
  echo "usage: snap.sh SRC DEST" >&2
  exit 2
fi
src=$1
dest=$2
mkdir -p "$dest" || exit 1

find "$src" -maxdepth 1 -type f -name '*.conf' | while read -r path; do
  name=$(basename $path)
  cp $path $dest/$name.bak || exit 1
done
