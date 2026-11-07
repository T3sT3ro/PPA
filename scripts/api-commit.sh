#!/usr/bin/env bash
# Adds FILES to the current branch as one commit made through the GitHub API,
# instead of `git commit` + `git push`. With GITHUB_TOKEN, GitHub signs commits
# made this way, so they pass a "Require signed commits" rule; a commit made
# with git on the runner would be unsigned and rejected.
#
# Usage: scripts/api-commit.sh MESSAGE FILE...
#
# Environment (set by GitHub Actions):
#   GH_TOKEN, GITHUB_REPOSITORY, GITHUB_REF_NAME
set -euo pipefail

message=$1
shift
repo=$GITHUB_REPOSITORY
branch=$GITHUB_REF_NAME
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

head=$(gh api "repos/$repo/git/ref/heads/$branch" --jq .object.sha)
base_tree=$(gh api "repos/$repo/git/commits/$head" --jq .tree.sha)

: > "$tmp/entries"
for file in "$@"; do
  base64 -w0 "$file" > "$tmp/content"
  jq -n --rawfile content "$tmp/content" '{content: $content, encoding: "base64"}' > "$tmp/blob.json"
  sha=$(gh api -X POST "repos/$repo/git/blobs" --input "$tmp/blob.json" --jq .sha)
  jq -nc --arg path "$file" --arg sha "$sha" \
    '{path: $path, mode: "100644", type: "blob", sha: $sha}' >> "$tmp/entries"
done

tree=$(jq -s --arg base "$base_tree" '{base_tree: $base, tree: .}' "$tmp/entries" |
  gh api -X POST "repos/$repo/git/trees" --input - --jq .sha)

# No author or committer fields: GitHub only signs commits that use its defaults.
commit=$(jq -n --arg msg "$message" --arg files "$(printf '%s\n' "$@")" --arg tree "$tree" --arg parent "$head" \
  '{message: ($msg + "\n\n" + $files), tree: $tree, parents: [$parent]}' |
  gh api -X POST "repos/$repo/git/commits" --input - --jq .sha)

# Fast-forward only. Fails if the branch moved meanwhile; the next sync retries.
gh api -X PATCH "repos/$repo/git/refs/heads/$branch" -f sha="$commit" -F force=false >/dev/null
echo "Committed $commit to $branch: $*"
