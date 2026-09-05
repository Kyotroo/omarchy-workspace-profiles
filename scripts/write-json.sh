#!/bin/bash
set -euo pipefail
destination=$1
json=$2
mkdir -p "$(dirname "$destination")"
tmp=$(mktemp "$destination.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
printf '%s' "$json" > "$tmp"
mv -- "$tmp" "$destination"
