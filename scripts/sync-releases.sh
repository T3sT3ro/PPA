#!/usr/bin/env bash
# Downloads .deb assets from the latest GitHub release of each repository in
# upstreams.txt into pool/, named NAME_VERSION_ARCH.deb. Files already in pool/
# are never overwritten. The sync-releases workflow runs this script.
#
# Environment:
#   ONLY_REPO  sync only this OWNER/REPO, which must be listed in upstreams.txt
#   TAG        with ONLY_REPO: sync this release tag instead of the latest release
#   GH_TOKEN   token for gh, with read access to the listed repositories
set -euo pipefail
shopt -s nullglob
cd "$(dirname "${BASH_SOURCE[0]}")/.."

list=upstreams.txt
only=${ONLY_REPO:-}
tag=${TAG:-}
listed=0 added=0

warn() { echo "::warning::$*"; }

if [[ ! -f $list ]]; then
  echo "No $list; nothing to sync."
  exit 0
fi
mkdir -p pool
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

while read -r repo pattern _ || [[ -n $repo ]]; do
  if [[ -z $repo || $repo == \#* ]]; then continue; fi
  if [[ -n $only && ${repo,,} != "${only,,}" ]]; then continue; fi
  listed=$((listed + 1))
  pattern=${pattern:-*.deb}
  release=()
  if [[ -n $only && -n $tag ]]; then release=("$tag"); fi

  dir="$work/$listed"
  mkdir -p "$dir"
  echo "== $repo: ${release[0]:-latest release}, assets matching '$pattern'"
  if ! gh release download "${release[@]}" --repo "$repo" --pattern "$pattern" --dir "$dir"; then
    warn "$repo: nothing downloaded (no release, no asset matching '$pattern', or no access)"
    continue
  fi

  for file in "$dir"/*; do
    if ! meta=$(dpkg-deb --show --showformat='${Package}\t${Version}\t${Architecture}' "$file" 2>/dev/null); then
      warn "$repo: $(basename "$file") is not a .deb package; skipped"
      continue
    fi
    IFS=$'\t' read -r pkg ver arch <<<"$meta"
    target="pool/${pkg}_${ver#*:}_${arch}.deb" # Debian file names omit the epoch
    if [[ -e $target ]]; then
      if ! cmp -s "$file" "$target"; then
        warn "$repo: $target already exists with different content; kept the existing file"
      fi
      continue
    fi
    mv "$file" "$target"
    echo "added $target"
    added=$((added + 1))
  done
done < "$list"

if [[ -n $only && $listed -eq 0 ]]; then
  echo "::error::$only is not listed in $list"
  exit 1
fi
echo "Added $added package file(s)."
