#!/usr/bin/env bash
# Set up and manage this APT repository from your machine.
# Requires git, gpg and the GitHub CLI (gh), logged in with admin access to the repository.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./ppa.sh <command> [options]

Commands:
  setup                       One-time setup, safe to re-run. Enables GitHub Pages,
                              creates the signing key secret if it is missing, sets the
                              repository homepage, points the install steps in README.md
                              at your URL, then deploys.
  connect OWNER/REPO [GLOB]   Sync .deb assets matching GLOB (default: *.deb) from the
                              latest GitHub release of OWNER/REPO into pool/.
  sync [OWNER/REPO]           Run the release sync now, for all or one repository.
  rotate-key                  Replace the signing key. Users must download KEY.gpg again.
  preview                     Build the site into _site/ locally, unsigned.

Options:
  --notify                    connect: also sync right after each release of OWNER/REPO.
  --key-backup FILE           setup, rotate-key: also save a new private key to FILE.
  -y, --yes                   Do not ask before pushing or deploying.
  -h, --help                  Show this help.
EOF
}

cd "$(dirname "${BASH_SOURCE[0]}")"
source scripts/config.sh

ASSUME_YES=0
KEY_BACKUP=''
REPO='' OWNER=''

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

confirm() {
  local answer
  if [[ $ASSUME_YES == 1 ]]; then return 0; fi
  read -r -p "$1 [Y/n] " answer || return 1
  [[ -z $answer || $answer == [Yy]* ]]
}

require() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || die "$tool is required but not installed."
  done
}

# Dies when the secrets cannot be listed: guessing "missing" could overwrite a live key.
has_secret() { # REPO NAME
  local names
  names=$(gh secret list --repo "$1" --json name --jq '.[].name') ||
    die "cannot list the secrets of $1 (admin access needed)."
  grep -qx -- "$2" <<<"$names"
}

pages_url() { gh api "repos/$REPO/pages" --jq .html_url 2>/dev/null || true; }

# Sets PPA_URL, PPA_NAME and PPA_TITLE the same way the deploy workflow does.
load_config() {
  local url
  url=$(pages_url)
  [[ -n $url ]] || url="https://${OWNER,,}.github.io/${REPO#*/}"
  ppa_resolve_config "$OWNER" "$url"
}

# Commits FILES and offers to push. Returns 0 if pushed, 1 if there was nothing
# to commit, 2 if committed but not pushed. Callers use `|| rc=$?`, which turns
# off `set -e` in here, so every git step checks its own result.
commit_and_push() { # MESSAGE FILES...
  local message=$1
  shift
  git add -- "$@" || die "git add failed"
  if git diff --cached --quiet -- "$@"; then return 1; fi
  git commit --quiet -m "$message" -- "$@" || die "git commit failed"
  info "Committed: $message"
  if ! confirm "Push to origin/$(git rev-parse --abbrev-ref HEAD)?"; then
    warn "Not pushed. Run 'git push' when ready."
    return 2
  fi
  git pull --rebase --autostash --quiet || die "git pull --rebase failed; resolve it, then run 'git push'."
  git push --quiet || die "git push failed"
}

start_workflow() { # WORKFLOW [gh workflow run args...]
  gh workflow run "$@" --repo "$REPO"
  info "Started $1. Follow it with: gh run watch --repo $REPO"
}

# --- setup -------------------------------------------------------------------

setup_pages() {
  local build_type
  if build_type=$(gh api "repos/$REPO/pages" --jq .build_type 2>/dev/null); then
    if [[ $build_type == workflow ]]; then
      info "GitHub Pages: already deploys from GitHub Actions"
    else
      info "GitHub Pages: switching the source to GitHub Actions"
      gh api -X PUT "repos/$REPO/pages" -f build_type=workflow >/dev/null
    fi
  else
    info "GitHub Pages: enabling, with GitHub Actions as the source"
    gh api -X POST "repos/$REPO/pages" -f build_type=workflow >/dev/null ||
      die "could not enable GitHub Pages. Private repositories need a paid plan. Or enable it under Settings → Pages."
  fi
}

create_signing_key() {
  local gnupg fpr
  require gpg gpgconf
  if [[ -n $KEY_BACKUP && $(realpath -m "$KEY_BACKUP") == "$PWD"/* ]]; then
    die "--key-backup must be outside the repository, so the key cannot be committed by accident."
  fi
  gnupg=$(mktemp -d)
  # shellcheck disable=SC2064 # expand now: $gnupg is local
  trap "GNUPGHOME='$gnupg' gpgconf --kill gpg-agent 2>/dev/null; rm -rf '$gnupg'" EXIT

  GNUPGHOME=$gnupg gpg --batch --quiet --passphrase '' \
    --quick-generate-key "$REPO APT repository signing key" ed25519 sign never
  fpr=$(GNUPGHOME=$gnupg gpg --batch --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1 == "fpr" && !n++ { print $10 }')
  GNUPGHOME=$gnupg gpg --batch --armor --export-secret-keys "$fpr" |
    gh secret set PPA_GPG_PRIVATE_KEY --repo "$REPO"
  info "Signing key: created $fpr and stored it in secret PPA_GPG_PRIVATE_KEY"

  if [[ -n $KEY_BACKUP ]]; then
    (umask 077 && GNUPGHOME=$gnupg gpg --batch --armor --export-secret-keys "$fpr" > "$KEY_BACKUP")
    info "Signing key: private key backup written to $KEY_BACKUP"
  fi
}

update_readme() {
  local old_url old_name text new
  old_url=$(grep -oE 'https?://[^[:space:]]+/KEY\.gpg' README.md | head -n1 || true)
  old_url=${old_url%/KEY.gpg}
  old_name=$(grep -oE '/etc/apt/keyrings/[^[:space:]/]+\.asc' README.md | head -n1 || true)
  old_name=${old_name##*/}
  old_name=${old_name%.asc}
  if [[ -z $old_url || -z $old_name ]]; then
    warn "README.md: install steps not found; point them at $PPA_URL by hand."
    return
  fi

  text=$(<README.md)
  new=${text//"$old_url/"/"$PPA_URL/"}
  new=${new//"/$old_name.asc"/"/$PPA_NAME.asc"}
  new=${new//"$old_name.sources"/"$PPA_NAME.sources"}
  if [[ $new == "$text" ]]; then
    info "README.md: install steps already use $PPA_URL"
    return
  fi
  printf '%s\n' "$new" > README.md
  info "README.md: install steps now use $PPA_URL and name '$PPA_NAME'"
}

cmd_setup() {
  local homepage rc=0

  setup_pages
  if has_secret "$REPO" PPA_GPG_PRIVATE_KEY; then
    info "Signing key: secret PPA_GPG_PRIVATE_KEY already set"
  else
    create_signing_key
  fi
  if has_secret "$REPO" PPA_GPG_EMAIL; then
    info "Secret PPA_GPG_EMAIL is no longer used. To remove it: gh secret delete PPA_GPG_EMAIL --repo $REPO"
  fi

  load_config
  homepage=$(gh repo view "$REPO" --json homepageUrl --jq .homepageUrl)
  if [[ -z $homepage ]]; then
    gh repo edit "$REPO" --homepage "$PPA_URL" >/dev/null
    info "Repository homepage set to $PPA_URL"
  fi

  update_readme
  commit_and_push "Point install instructions at $PPA_URL" README.md || rc=$?
  case $rc in
    0) info "Pushed. The README change starts a deploy." ;;
    1) if confirm "Deploy now?"; then start_workflow deploy-ppa.yml; fi ;;
  esac

  cat <<EOF

Your repository: $PPA_URL
  Name:  $PPA_NAME    Title: $PPA_TITLE    (change them in ppa.conf)
Next:
  - add .deb files to pool/ and push, or
  - ./ppa.sh connect OWNER/REPO   to sync packages from another repository's releases
EOF
}

# --- connect -----------------------------------------------------------------

setup_notify() { # SOURCE_REPO
  local src=$1 token_url
  if has_secret "$src" PPA_DISPATCH_TOKEN; then
    info "$src already has secret PPA_DISPATCH_TOKEN"
  else
    token_url="https://github.com/settings/personal-access-tokens/new?name=Release+dispatch+to+${REPO#*/}&description=Lets+release+jobs+start+a+package+sync+in+${REPO}&target_name=${OWNER}&contents=write"
    cat <<EOF

For instant syncs, $src needs a token that can start workflows in $REPO.
  1. Create a fine-grained token. One token works for all your source repositories:
     $token_url
     Under "Repository access" pick "Only select repositories" → ${REPO#*/}.
  2. Paste it below. It is saved as secret PPA_DISPATCH_TOKEN in $src.
     (Set PPA_DISPATCH_TOKEN in your environment to skip this prompt.)
EOF
    if [[ -n ${PPA_DISPATCH_TOKEN:-} ]]; then
      printf '%s' "$PPA_DISPATCH_TOKEN" | gh secret set PPA_DISPATCH_TOKEN --repo "$src"
    else
      gh secret set PPA_DISPATCH_TOKEN --repo "$src"
    fi
  fi

  cat <<EOF

Add this step to the end of $src's release job, after the .deb files are uploaded:

      - name: Publish to $REPO
        env:
          GH_TOKEN: \${{ secrets.PPA_DISPATCH_TOKEN }}
        run: >-
          gh api repos/$REPO/dispatches
          -f event_type=new-release
          -f "client_payload[repo]=\${{ github.repository }}"

EOF
}

cmd_connect() { # SOURCE_REPO [GLOB] NOTIFY
  local src=$1 glob=${2:-*.deb} notify=$3
  local tag asset line rc=0
  local matched=()

  [[ $src =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "expected OWNER/REPO, got '$src'"
  gh repo view "$src" --json name >/dev/null || die "cannot access $src"

  if tag=$(gh release view --repo "$src" --json tagName --jq .tagName 2>/dev/null); then
    while IFS= read -r asset; do
      # shellcheck disable=SC2053 # $glob is a pattern on purpose
      if [[ -n $asset && $asset == $glob ]]; then matched+=("$asset"); fi
    done < <(gh release view --repo "$src" --json assets --jq '.assets[].name')
    if ((${#matched[@]})); then
      info "$src $tag: ${#matched[@]} asset(s) match '$glob': ${matched[*]}"
    else
      warn "$src $tag has no assets matching '$glob'. Nothing will sync until a release has some."
    fi
  else
    warn "$src has no published release yet. Packages will sync once it has one."
  fi

  if [[ $(gh repo view "$src" --json isPrivate --jq .isPrivate) == true ]] && ! has_secret "$REPO" PPA_SYNC_TOKEN; then
    warn "$src is private. The sync needs secret PPA_SYNC_TOKEN in $REPO: a fine-grained token with Contents: read on $src."
    warn "Create one at https://github.com/settings/personal-access-tokens/new?name=PPA+sync+${REPO#*/}&contents=read then run: gh secret set PPA_SYNC_TOKEN --repo $REPO"
  fi

  touch upstreams.txt
  if awk -v r="${src,,}" '$1 !~ /^#/ && tolower($1) == r { found = 1 } END { exit !found }' upstreams.txt; then
    info "upstreams.txt already lists $src"
  else
    line=$src
    [[ $glob == '*.deb' ]] || line+=" $glob"
    if [[ -s upstreams.txt && -n $(tail -c1 upstreams.txt) ]]; then echo >> upstreams.txt; fi
    printf '%s\n' "$line" >> upstreams.txt
    info "upstreams.txt: added $line"
  fi

  if [[ $notify == 1 ]]; then setup_notify "$src"; fi

  commit_and_push "Sync packages from $src" upstreams.txt || rc=$?
  case $rc in
    0) info "Pushed. Changing upstreams.txt starts a sync." ;;
    1) if confirm "Sync $src now?"; then start_workflow sync-releases.yml -f repo="$src"; fi ;;
  esac
}

# --- other commands ----------------------------------------------------------

cmd_rotate_key() {
  confirm "Replace the signing key of $REPO? Users will have to download KEY.gpg again." || die "aborted"
  create_signing_key
  start_workflow deploy-ppa.yml
  load_config
  cat <<EOF

Tell your users to download the new key:
  sudo curl -fsSL $PPA_URL/KEY.gpg -o /etc/apt/keyrings/$PPA_NAME.asc
EOF
}

cmd_sync() { # [SOURCE_REPO]
  if [[ -n ${1:-} ]]; then
    start_workflow sync-releases.yml -f repo="$1"
  else
    start_workflow sync-releases.yml
  fi
}

cmd_preview() {
  load_config
  GITHUB_REPOSITORY_OWNER=$OWNER PAGES_URL=$PPA_URL UNSIGNED=1 scripts/build-site.sh _site
  info "To view it: python3 -m http.server -d _site 8000, then open http://localhost:8000"
}

# --- main --------------------------------------------------------------------

main() {
  local cmd=${1:-} notify=0
  local args=()
  if (($#)); then shift; fi
  while (($#)); do
    case $1 in
      -y | --yes) ASSUME_YES=1 ;;
      --notify) notify=1 ;;
      --key-backup) KEY_BACKUP=${2:?--key-backup needs a file name}; shift ;;
      -h | --help) usage; exit 0 ;;
      -*) die "unknown option: $1" ;;
      *) args+=("$1") ;;
    esac
    shift
  done

  case $cmd in
    '' | help | -h | --help) usage; exit 0 ;;
    setup | connect | sync | rotate-key | preview) ;;
    *) usage >&2; exit 2 ;;
  esac
  if [[ $cmd == connect && ${#args[@]} -eq 0 ]]; then die "usage: ./ppa.sh connect OWNER/REPO [GLOB] [--notify]"; fi

  require git gh
  gh auth status >/dev/null 2>&1 || die "gh is not logged in. Run: gh auth login"
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) ||
    die "cannot tell which GitHub repository this is. Run: gh repo set-default"
  OWNER=${REPO%%/*}

  case $cmd in
    setup) cmd_setup ;;
    connect) cmd_connect "${args[0]}" "${args[1]:-}" "$notify" ;;
    sync) cmd_sync "${args[0]:-}" ;;
    rotate-key) cmd_rotate_key ;;
    preview) cmd_preview ;;
  esac
}

main "$@"
