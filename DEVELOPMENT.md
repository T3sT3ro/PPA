# Development Documentation

Reference guide for repository architecture, manual package publishing, and external release synchronization for `T3sT3ro/PPA`.

---

## 1. Repository Structure

* `pool/`: Dedicated storage directory for flat `.deb` packages.
* `README.md`: Single source of truth for the landing page containing installation steps and the `<!-- PACKAGES_LIST -->` injection marker.
* `.github/workflows/deploy-ppa.yml`: Automation pipeline handling GPG signing, APT metadata generation, Pandoc Markdown-to-HTML conversion, GitHub Pages deployment, and containerized testing (`ubuntu:rolling`).

---

## 2. Manual Package Publishing

1. Copy the compiled `.deb` into the pool directory:

```bash
cp /path/to/package_1.0.0_amd64.deb pool/

```

2. Commit and push to `main`:

```bash
git add pool/
git commit -m "feat(ppa): add package version"
git push origin main

```

---

## 3. Automated External Sync

### Option A: Scheduled Poll (Cron)

Place a workflow in `.github/workflows/sync-releases.yml` to periodically pull release assets from source repositories:

```yaml
name: Sync Releases

on:
  schedule:
    - cron: '0 4 * * *'
  workflow_dispatch:

jobs:
  sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          mkdir -p pool
          ASSET_URL=$(gh api repos/T3sT3ro/source-repo/releases/latest --jq '.assets[] | select(.name | endswith(".deb")) | .url')
          ASSET_NAME=$(gh api repos/T3sT3ro/source-repo/releases/latest --jq '.assets[] | select(.name | endswith(".deb")) | .name')
          
          if [ -n "$ASSET_URL" ] && [ ! -f "pool/$ASSET_NAME" ]; then
            curl -L -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/octet-stream" "$ASSET_URL" -o "pool/$ASSET_NAME"
            git config user.name "PPA Sync Bot"
            git config user.email "bot@users.noreply.github.com"
            git add "pool/$ASSET_NAME"
            git commit -m "chore(ppa): auto-sync $ASSET_NAME"
          fi
      - uses: ad-m/github-push-action@master
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          branch: main

```

### Option B: Instant Trigger (Repository Dispatch)

1. Add this step to the source repository's release workflow:

```yaml
- uses: diekotto/repository-dispatch@v1
  with:
    token: ${{ secrets.PPA_DEPLOY_TOKEN }}
    repository: T3sT3ro/PPA
    event-type: new-release

```

2. Listen for the event in `.github/workflows/deploy-ppa.yml`:

```yaml
on:
  repository_dispatch:
    types: [new-release]

```
