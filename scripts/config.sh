# Shared by scripts/build-site.sh and ppa.sh. Source this file, then call
# ppa_resolve_config.
#
# ppa_resolve_config OWNER PAGES_URL
#   Sets PPA_URL, PPA_NAME and PPA_TITLE from ppa.conf. Empty settings fall back to:
#     PPA_URL    PAGES_URL, switched to https
#     PPA_NAME   OWNER in lowercase
#     PPA_TITLE  "OWNER's PPA"

ppa_resolve_config() {
  local owner=$1 pages_url=$2
  local conf default_title
  conf="$(dirname "${BASH_SOURCE[0]}")/../ppa.conf"

  PPA_URL='' PPA_NAME='' PPA_TITLE=''
  if [[ -f $conf ]]; then
    # shellcheck source=../ppa.conf
    source "$conf"
  fi

  default_title="${owner}'s PPA"
  [[ -n $PPA_NAME ]] || PPA_NAME=${owner,,}
  [[ -n $PPA_TITLE ]] || PPA_TITLE=$default_title
  # The Pages API reports http:// even when the site is served over https.
  [[ -n $PPA_URL ]] || PPA_URL=${pages_url/#http:/https:}
  PPA_URL=${PPA_URL%/}

  if [[ ! $PPA_URL =~ ^https?://[^[:space:]]+$ ]]; then
    echo "error: no valid repository URL (got '$PPA_URL'). Is GitHub Pages enabled? Or set PPA_URL in ppa.conf." >&2
    return 1
  fi
  if [[ ! $PPA_NAME =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
    echo "error: PPA_NAME '$PPA_NAME' must be lowercase letters, digits, '.', '_' or '-'." >&2
    return 1
  fi
}
