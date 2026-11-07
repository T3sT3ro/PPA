#!/usr/bin/env bash
# Builds the published site into OUT_DIR: a copy of pool/, the signed APT metadata,
# KEY.gpg, the <name>.sources file and the landing page (index.html).
# The deploy workflow runs this script; `./ppa.sh preview` runs it locally.
#
# Usage: scripts/build-site.sh [OUT_DIR]        (default: _site)
#
# Environment:
#   GITHUB_REPOSITORY_OWNER  repository owner; default name and title derive from it
#   PAGES_URL                GitHub Pages URL; the default repository URL
#   SIGNING_KEY              key to sign with (default: first secret key in the keyring)
#   UNSIGNED=1               skip signing, for local previews only
#   GITHUB_OUTPUT            set by GitHub Actions; receives url, name, inrelease-sha256
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$(realpath -m "${1:-_site}")
cd "$root"
source scripts/config.sh
ppa_resolve_config "${GITHUB_REPOSITORY_OWNER:-}" "${PAGES_URL:-}"

for tool in dpkg-scanpackages apt-ftparchive dpkg-deb pandoc gpg; do
  if ! command -v "$tool" >/dev/null; then
    echo "error: $tool not found. Install: dpkg-dev apt-utils pandoc gnupg" >&2
    exit 1
  fi
done
if [[ ! -d pool ]]; then
  echo "error: pool/ does not exist. Add a package or an empty pool/.gitkeep." >&2
  exit 1
fi

rm -rf "$out"
mkdir -p "$out"
cp -r pool "$out/pool"
find "$out/pool" -name .gitkeep -delete

# --- APT metadata. Filename: paths in Packages are relative to the site root.
(
  cd "$out"
  dpkg-scanpackages --multiversion pool/ > Packages
  gzip -9 -k -f Packages
  apt-ftparchive release . > Release
)

if [[ ${UNSIGNED:-} == 1 ]]; then
  echo "warning: UNSIGNED=1: no KEY.gpg or signatures; apt will reject this build." >&2
else
  key=${SIGNING_KEY:-$(gpg --batch --list-secret-keys --with-colons 2>/dev/null \
    | awk -F: '$1 == "fpr" && !n++ { print $10 }')}
  if [[ -z $key ]]; then
    echo "error: no secret key in the GnuPG keyring to sign with (or set UNSIGNED=1)." >&2
    exit 1
  fi
  gpg --batch --armor --export "$key" > "$out/KEY.gpg"
  gpg --batch --yes --default-key "$key" --armor --detach-sign -o "$out/Release.gpg" "$out/Release"
  gpg --batch --yes --default-key "$key" --clearsign -o "$out/InRelease" "$out/Release"
fi

cat > "$out/$PPA_NAME.sources" <<EOF
Types: deb
URIs: $PPA_URL
Suites: ./
Signed-By: /etc/apt/keyrings/$PPA_NAME.asc
EOF

# --- Landing page: README.md plus a generated package table.

# Backslash-escape Markdown punctuation, so package metadata (which may come
# from other people's releases) renders as plain text, never as markup or HTML.
md_text() { sed -e 's/[][\\`*_{}()#+!|<>&~^$@%:;="]/\\&/g' <<<"$1"; }

if ! grep -qF "$PPA_URL/KEY.gpg" README.md || ! grep -qF "/etc/apt/keyrings/$PPA_NAME.asc" README.md; then
  echo "::warning::README.md install steps do not use $PPA_URL and '$PPA_NAME'. Run ./ppa.sh setup to update them."
fi

page=$(mktemp)
trap 'rm -f "$page"' EXIT
count=0
{
  cat README.md
  printf '\n## Available Packages\n\n'
  rows=$(find pool -type f -name '*.deb' -print0 | while IFS= read -r -d '' deb; do
    printf '%s\t%s\n' \
      "$(dpkg-deb --show --showformat='${Package}\t${Version}\t${Architecture}\t${binary:Summary}' "$deb")" \
      "$deb"
  done | sort -t $'\t' -k1,1 -k2,2Vr)
  if [[ -z $rows ]]; then
    echo '_No packages yet._'
  else
    echo '| Package | Version | Architecture | Description |'
    echo '| --- | --- | --- | --- |'
    while IFS=$'\t' read -r pkg ver arch summary deb; do
      printf '| %s | [%s](%s) | %s | %s |\n' \
        "$(md_text "$pkg")" "$(md_text "$ver")" "${deb// /%20}" "$(md_text "$arch")" "$(md_text "$summary")"
    done <<<"$rows"
  fi
} > "$page"
[[ -z $rows ]] || count=$(wc -l <<<"$rows")

pandoc "$page" -f markdown -t html5 -s --template=template.html \
  --metadata title="$PPA_TITLE" -o "$out/index.html"

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  {
    echo "url=$PPA_URL"
    echo "name=$PPA_NAME"
    if [[ -f $out/InRelease ]]; then
      echo "inrelease-sha256=$(sha256sum < "$out/InRelease" | cut -d' ' -f1)"
    fi
  } >> "$GITHUB_OUTPUT"
fi

echo "Built $out: $count package file(s), URL $PPA_URL, name $PPA_NAME, title \"$PPA_TITLE\""
