# Development

Maintainer reference: how the repository is built, how to publish packages, how to pull packages in from other repositories' releases, and what to do when something breaks.

To set up your own copy of this repository, start with [TEMPLATE.md](TEMPLATE.md).

---

## 1. How it works

This is a [flat APT repository](https://wiki.debian.org/DebianRepository/Format#Flat_Repository_Format): no `dists/` tree, no suites or components, and a single `Packages` index for everything in `pool/`. Clients point at it with `Suites: ./`.

Git holds only the inputs. Every deploy regenerates the signed metadata and the landing page from scratch and publishes them to GitHub Pages. Nothing generated is committed back.

### Files in git

| Path | Purpose |
| --- | --- |
| `pool/` | The `.deb` packages. Every version stays available until you delete the file. |
| `README.md` | Install instructions. Both the GitHub front page and the source of the landing page (`index.html`). |
| `template.html` | Pandoc HTML template for the landing page (GitHub Markdown CSS, dark mode). |
| `<name>.sources` | deb822 source file that users download into `/etc/apt/sources.list.d/`. |
| `.github/workflows/deploy-ppa.yml` | The build, sign, deploy and test pipeline. |
| `DEVELOPMENT.md`, `TEMPLATE.md` | Docs. Editing them does not trigger a deploy. |

### Files only on the deployed site

| Path | Produced by |
| --- | --- |
| `KEY.gpg` | `gpg --armor --export` of the signing key's public part |
| `Packages`, `Packages.gz` | `dpkg-scanpackages --multiversion pool/` |
| `Release` | `apt-ftparchive release .` (checksums of the indexes) |
| `Release.gpg`, `InRelease` | Detached and inline signatures of `Release` |
| `index.html` | Pandoc render of `README.md` plus the generated package list |

### Pipeline (`deploy-ppa.yml`)

The workflow runs on a push to `main` that touches `pool/**/*.deb`, `README.md`, `template.html` or the `.sources` file. You can also start it by hand (`workflow_dispatch`):

```bash
gh workflow run deploy-ppa.yml
```

**Job `build-and-deploy`:**

1. Installs `dpkg-dev`, `apt-utils`, `gnupg` and `pandoc`.
2. Imports the private key from the `PPA_GPG_PRIVATE_KEY` secret.
3. Exports the public key, builds `Packages` and `Release`, and signs `Release`. `PPA_GPG_EMAIL` picks the key.
4. Appends an `## Available Packages` list to `README.md` and renders it with `template.html` into `index.html`.
5. Uploads the whole working directory as the Pages artifact and deploys it.

**Job `test-ppa`:** waits 15 seconds, then in a clean `ubuntu:rolling` container adds the repository from its public URL and runs `apt-get update`. This catches a broken signature or a broken `.sources` file. It does not install any package.

### Secrets

| Secret | Value |
| --- | --- |
| `PPA_GPG_PRIVATE_KEY` | ASCII-armored private key, **without a passphrase** (the workflow signs non-interactively) |
| `PPA_GPG_EMAIL` | Email address (or fingerprint) of that key. Passed to `--default-key` and `--export`. |

---

## 2. Landing page

`README.md` is the landing page. When you edit it:

* **Do not add a top-level `#` heading.** `template.html` already renders the page title, which comes from `--metadata title=` in the workflow.
* **Keep `## Repository Files` as the last section.** CI appends `## Available Packages` to the end of the file. Pandoc gives it the `#available-packages` anchor, which the install section links to. On GitHub that section does not exist, because it is only generated during the deploy.
* Links such as `KEY.gpg` are relative. They resolve on the deployed site, but on GitHub `KEY.gpg` is a dead link, since it is never committed.

To preview locally (requires `pandoc`):

```bash
cp README.md /tmp/preview.md
printf '\n## Available Packages\n\n' >> /tmp/preview.md
for f in pool/*.deb; do echo "- [$f]($f)" >> /tmp/preview.md; done
pandoc /tmp/preview.md -s -o /tmp/index.html -t html5 \
    --template=template.html --metadata title="Preview"
xdg-open /tmp/index.html
```

---

## 3. Publishing packages by hand

1. Copy the built `.deb` into `pool/`. Keep the Debian file name format `name_version-revision_arch.deb`:

```bash
cp /path/to/package_1.0.0-1_amd64.deb pool/
```

2. Commit and push to `main`. The deploy starts on its own.

```bash
git add pool/
git commit -m "feat(ppa): add package 1.0.0-1"
git push origin main
```

Notes:

* **Old versions stay installable.** Because of `--multiversion`, `apt` sees every version in `pool/` and installs the newest one. To withdraw a version, `git rm` its file and push.
* **`pool/` must exist.** If it is missing, `dpkg-scanpackages` stops with `binary path pool/ not found` and the deploy fails. If you remove the last package, commit a `pool/.gitkeep`.
* **Rust projects:** [`cargo-deb`](https://github.com/kornelski/cargo-deb) produces a ready-to-publish `.deb` (`cargo deb`, output in `target/debian/`).
* **Size limits:** GitHub rejects files over 100 MB, and a Pages site should stay under 1 GB. Every `.deb` you ever commit stays in git history. Do not move `pool/` to Git LFS: the checkout step would publish LFS pointer files instead of packages.

---

## 4. Syncing packages from other repositories' releases

If your packages are built by release workflows in other repositories, let a workflow here copy the `.deb` assets into `pool/`.

> **Caveat:** a push made with the built-in `GITHUB_TOKEN` [does not trigger other workflows](https://docs.github.com/en/actions/concepts/security/github_token). A sync job that commits and pushes would never cause a deploy. The sync workflow below therefore starts `deploy-ppa.yml` itself with `gh workflow run`. `workflow_dispatch` is one of the events `GITHUB_TOKEN` is allowed to trigger.

### Sync workflow

Save as `.github/workflows/sync-releases.yml` and fill in `SOURCE_REPOS`. It runs every night, on demand, and on a `new-release` dispatch (see below):

```yaml
name: Sync Releases

on:
  schedule:
    - cron: '0 4 * * *'
  repository_dispatch:
    types: [new-release]
  workflow_dispatch:

permissions:
  contents: write   # commit new .deb files
  actions: write    # start deploy-ppa.yml

jobs:
  sync:
    runs-on: ubuntu-latest
    env:
      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      SOURCE_REPOS: OWNER/tool-a OWNER/tool-b   # space-separated
    steps:
      - uses: actions/checkout@v5

      - name: Download .deb assets from the latest releases
        run: |
          mkdir -p pool
          for repo in $SOURCE_REPOS; do
            gh release download --repo "$repo" --pattern '*.deb' \
                --dir pool --skip-existing \
              || echo "::warning::No .deb downloaded from $repo"
          done

      - name: Commit, push and deploy
        run: |
          git add pool/
          if git diff --cached --quiet; then
            echo "No new packages."
            exit 0
          fi
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git commit -m "chore(ppa): sync release assets"
          git push
          gh workflow run deploy-ppa.yml --ref main
```

`GITHUB_TOKEN` can only read *public* source repositories. For private ones, replace `GH_TOKEN` with a fine-grained personal access token that has **Contents: read** on those repositories.

### Instant trigger from a source repository

To skip waiting for the nightly run, have the source repository send a `repository_dispatch` once its release assets are uploaded:

1. Create a fine-grained personal access token scoped to **this** repository with **Contents: read and write**. That is the permission `repository_dispatch` requires.
2. Save it as the `PPA_DISPATCH_TOKEN` secret in the **source** repository.
3. Add this as the last step of the source repository's release job:

```yaml
- name: Notify PPA
  env:
    GH_TOKEN: ${{ secrets.PPA_DISPATCH_TOKEN }}
  run: gh api repos/OWNER/PPA/dispatches -f event_type=new-release
```

The dispatch starts the sync workflow above. Do not send it to `deploy-ppa.yml`: that workflow does not download anything, so it would only rebuild what is already in `pool/`.

---

## 5. Rotating the signing key

1. Generate a new key and update both secrets, as in [TEMPLATE.md, step 2](TEMPLATE.md#2-create-the-signing-key).
2. Start a deploy: `gh workflow run deploy-ppa.yml`.
3. Tell your users to repeat installation step 2 (download `KEY.gpg`). Until they do, `apt update` rejects the repository with a signature error.

Never commit the private key. If one ever reaches git history, assume it is public and rotate it.

---

## 6. Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| `gpg: signing failed: No secret key` in CI | `PPA_GPG_EMAIL` does not match the imported key. Use the key's email or fingerprint. |
| CI hangs or fails asking for a passphrase / pinentry | The key in `PPA_GPG_PRIVATE_KEY` has a passphrase. Export it again without one. |
| `dpkg-scanpackages: error: binary path pool/ not found` | `pool/` is empty and so not tracked by git. Add a package or `pool/.gitkeep`. |
| `test-ppa` fails right after a successful deploy | Pages had not finished propagating. Re-run the job. |
| Users get `Hash Sum mismatch` or `File has unexpected size` | Pages' CDN caches files for a few minutes and can serve a new `InRelease` next to an old `Packages`. Wait a few minutes and run `apt update` again. |
| Users get `NO_PUBKEY` or `The following signatures couldn't be verified` | Their keyring is out of date (usually after a key rotation). Download `KEY.gpg` again. |
| Push to `main` did not deploy | The changed paths are not in the workflow's `paths:` filter (e.g. docs only), or the push was made with `GITHUB_TOKEN`. Run `gh workflow run deploy-ppa.yml`. |
