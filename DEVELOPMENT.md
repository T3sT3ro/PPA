# Development

Maintainer reference: how the repository is built, how to publish packages, how packages sync in from other repositories, and what to do when something breaks.

To set up your own copy of this repository, start with [TEMPLATE.md](TEMPLATE.md).

---

## 1. How it works

This is a [flat APT repository](https://wiki.debian.org/DebianRepository/Format#Flat_Repository_Format): no `dists/` tree, no suites or components, and a single `Packages` index for everything in `pool/`. Clients point at it with `Suites: ./`.

Git holds only the inputs. Every deploy rebuilds the signed metadata, the `.sources` file and the landing page from scratch, and publishes them to GitHub Pages. Nothing generated is committed back.

### Files in git

| Path | Purpose |
| --- | --- |
| `pool/` | The `.deb` packages. Every version stays available until you delete its file. |
| `README.md` | Install instructions. Both the GitHub front page and the top of the landing page. |
| `template.html` | Pandoc HTML template for the landing page (GitHub Markdown CSS, dark mode). |
| `ppa.conf` | Optional overrides for the URL, name and title (see [Configuration](#configuration)). |
| `upstreams.txt` | Repositories whose release `.deb` assets sync into `pool/` (see [section 4](#4-syncing-packages-from-other-repositories)). |
| `ppa.sh` | Command-line tool for setup, connecting repositories, syncing and key rotation (see [section 6](#6-ppash-reference)). |
| `scripts/build-site.sh` | Builds the site into `_site/`. Used by the deploy workflow and `./ppa.sh preview`. |
| `scripts/sync-releases.sh` | Downloads release assets into `pool/`. Used by the sync workflow. |
| `scripts/api-commit.sh` | Commits files through the GitHub API, so GitHub signs the commit. Used by the sync workflow. |
| `scripts/config.sh` | Resolves the configuration. Shared by the scripts above and `ppa.sh`. |
| `.github/workflows/deploy-ppa.yml` | Build, sign, deploy and test. |
| `.github/workflows/sync-releases.yml` | Release sync. |
| `DEVELOPMENT.md`, `TEMPLATE.md` | Docs. Editing them does not trigger a deploy. |

### Files only on the deployed site

| Path | Produced by |
| --- | --- |
| `pool/*.deb` | Copied from git |
| `Packages`, `Packages.gz` | `dpkg-scanpackages --multiversion pool/` |
| `Release` | `apt-ftparchive release .` (checksums of the indexes) |
| `Release.gpg`, `InRelease` | Detached and inline signatures of `Release` |
| `KEY.gpg` | The public half of the signing key |
| `<name>.sources` | deb822 source file with the URL and keyring path |
| `index.html` | `README.md` plus a generated package table, rendered by pandoc |

### Configuration

Three values shape the published repository. Each falls back to a default derived from GitHub unless [`ppa.conf`](ppa.conf) sets it:

| Setting | Default | Used for |
| --- | --- | --- |
| `PPA_URL` | GitHub Pages URL from `actions/configure-pages`, switched to https | `URIs:` in the `.sources` file, and the `test-ppa` job |
| `PPA_NAME` | Repository owner in lowercase | `<name>.sources` and `/etc/apt/keyrings/<name>.asc` |
| `PPA_TITLE` | `<owner>'s PPA` | Landing page title |

`README.md` has to match `PPA_URL` and `PPA_NAME`, because users copy their install commands from it. `./ppa.sh setup` rewrites it after you change either one, and the build prints a warning when they disagree.

### Secrets

| Secret | Where | Needed for |
| --- | --- | --- |
| `PPA_GPG_PRIVATE_KEY` | This repository | **Required.** ASCII-armored private key, **without a passphrase**, because the workflow signs non-interactively. Created by `./ppa.sh setup`. |
| `PPA_SYNC_TOKEN` | This repository | Only for syncing from **private** repositories: a fine-grained token with *Contents: read* on them. |
| `PPA_DISPATCH_TOKEN` | Each source repository | Only for instant syncs: a fine-grained token with *Contents: read and write* on this repository. |

An older setup also had a `PPA_GPG_EMAIL` secret. Nothing reads it any more: the build signs with the only key in the CI keyring. You can delete it.

### Deploy pipeline (`deploy-ppa.yml`)

The deploy runs on a push to `main` that touches `pool/`, `README.md`, `template.html`, `ppa.conf`, the build scripts or the workflow itself. The sync workflow and `ppa.sh` also start it, and so can you:

```bash
gh workflow run deploy-ppa.yml
```

**Job `build-and-deploy`:**

1. Installs `dpkg-dev`, `apt-utils`, `gnupg` and `pandoc`.
2. Reads the Pages URL with `actions/configure-pages`.
3. Imports `PPA_GPG_PRIVATE_KEY`, and fails with a clear message if it is missing.
4. Runs `scripts/build-site.sh _site`.
5. Uploads `_site/` and deploys it to Pages.

**Job `test-ppa`:** in a clean `ubuntu:rolling` container, waits until the served `InRelease` matches this build (for up to 10 minutes). It then runs the install commands from `README.md` and `apt-get update`, and checks that APT lists the repository. It does not install any package.

---

## 2. Landing page

`README.md` is the top of the landing page. When you edit it:

* **Do not add a top-level `#` heading.** `template.html` already renders the page title, which comes from `PPA_TITLE`.
* **Keep `## Repository Files` as the last section.** The build appends `## Available Packages`, a table of every package version with a download link. The install section links to it as `#available-packages`. That section exists only on the site, never in git.
* **Links such as `KEY.gpg` are relative.** They work on the site but are dead on GitHub, because the files are generated.

Package names and descriptions in the table are escaped, so metadata from other people's releases cannot inject Markdown or HTML into the page.

To preview locally, run `./ppa.sh preview`. It needs `dpkg-dev`, `apt-utils` and `pandoc`, and builds an unsigned copy into `_site/`.

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
* **`pool/` must exist.** If it is missing, `dpkg-scanpackages` stops the build. If you remove the last package, commit a `pool/.gitkeep`.
* **Rust projects:** [`cargo-deb`](https://github.com/kornelski/cargo-deb) produces a ready-to-publish `.deb` (`cargo deb`, output in `target/debian/`).
* **Size limits:** GitHub rejects files over 100 MB, and a Pages site should stay under 1 GB. Every `.deb` you ever commit stays in git history. Do not move `pool/` to Git LFS: the checkout step would publish LFS pointer files instead of packages.

---

## 4. Syncing packages from other repositories

If other repositories of yours publish `.deb` files as GitHub release assets, the **Sync Releases** workflow copies them into `pool/`, commits them and starts a deploy.

### Connecting a repository

```bash
./ppa.sh connect OWNER/REPO               # all *.deb assets
./ppa.sh connect OWNER/REPO '*_amd64.deb' # only assets matching a glob
```

The command checks the repository and shows which assets of its latest release match. It then adds a line to [`upstreams.txt`](upstreams.txt), commits, and asks before pushing. The push starts a sync. You can also edit `upstreams.txt` by hand: one `OWNER/REPO [GLOB]` per line, `#` for comments. To disconnect a repository, delete its line. Packages already in `pool/` stay.

### When it runs

| Trigger | What syncs |
| --- | --- |
| Every night at 04:17 UTC | Latest release of every listed repository |
| Push that changes `upstreams.txt` | Same |
| `./ppa.sh sync [OWNER/REPO]` or *Run workflow* in the Actions tab | All repositories, or only the given one |
| `repository_dispatch` of type `new-release` from a source repository | Only that repository (see below) |

A specific release, for example a prerelease, which "latest" skips:

```bash
gh workflow run sync-releases.yml -f repo=OWNER/REPO -f tag=v1.2.3-rc1
```

### What a sync does

For each listed repository, `scripts/sync-releases.sh`:

1. Downloads the assets of the latest release that match the glob.
2. Checks that each one is a valid `.deb` and skips anything that is not.
3. Renames it to the canonical `name_version_arch.deb`, taken from the package metadata, so differently named assets cannot collide.
4. Adds it to `pool/` unless a file of that name already exists. Existing files are **never overwritten**. If an upstream asset changes under the same version, the sync keeps the published file and logs a warning.

If anything new arrived, the workflow commits it to `main` with `scripts/api-commit.sh`, as `github-actions[bot]`:

* **The commit goes through the GitHub API rather than `git push`.** GitHub signs commits made that way, so they pass a "Require signed commits" rule. A commit made with git on the runner would be unsigned.
* **It builds on the newest `main`**, so pushes made during the sync are kept. The branch update is fast-forward only: if `main` moves during the few seconds of the commit itself, GitHub refuses the update and the next sync retries.

Then it starts `deploy-ppa.yml` with `gh workflow run`. That step is needed because changes made with `GITHUB_TOKEN` [do not trigger other workflows](https://docs.github.com/en/actions/concepts/security/github_token).

### Private source repositories

The built-in `GITHUB_TOKEN` can only read public repositories. For private ones, create a fine-grained token with *Contents: read* on them and save it as `PPA_SYNC_TOKEN` in this repository. `./ppa.sh connect` reminds you when a repository is private.

### Instant sync on release

```bash
./ppa.sh connect OWNER/REPO --notify
```

The command:

1. Prints a link that pre-fills a fine-grained token with *Contents: read and write*, the permission `repository_dispatch` requires. Restrict the token to this repository. One token can serve all your source repositories.
2. Saves the token as `PPA_DISPATCH_TOKEN` in the source repository. It prompts for the value, or reads it from the `PPA_DISPATCH_TOKEN` environment variable.
3. Prints this step for you to add to the end of the source repository's release job, after the assets are uploaded:

```yaml
- name: Publish to OWNER/PPA
  env:
    GH_TOKEN: ${{ secrets.PPA_DISPATCH_TOKEN }}
  run: >-
    gh api repos/OWNER/PPA/dispatches
    -f event_type=new-release
    -f "client_payload[repo]=${{ github.repository }}"
```

To sync a specific tag, add `-f "client_payload[tag]=${{ github.ref_name }}"`. The dispatch only takes effect for repositories listed in `upstreams.txt`. If the token expires, the nightly sync still picks up new releases.

---

## 5. Rotating the signing key

```bash
./ppa.sh rotate-key
```

The command creates a new key, replaces `PPA_GPG_PRIVATE_KEY` and starts a deploy. It then prints the command your users must run to download the new `KEY.gpg`. Until they do, `apt update` rejects the repository with `NO_PUBKEY`.

Never commit the private key. If one ever reaches git history, assume it is public and rotate it.

---

## 6. `ppa.sh` reference

| Command | Does |
| --- | --- |
| `./ppa.sh setup` | Enables Pages, creates the key secret if it is missing, sets the homepage, updates `README.md` and deploys. Safe to re-run. |
| `./ppa.sh connect OWNER/REPO [GLOB] [--notify]` | Adds a source repository to `upstreams.txt`. `--notify` also sets up instant syncs. |
| `./ppa.sh sync [OWNER/REPO]` | Starts the sync workflow. |
| `./ppa.sh rotate-key` | Replaces the signing key and deploys. |
| `./ppa.sh preview` | Builds an unsigned site into `_site/`. |

Common options:

* `-y` skips confirmation prompts.
* `--key-backup FILE` saves a newly created private key outside the repository.

Every command that commits asks before it pushes. `ppa.sh` needs `gh` logged in with admin access to the repository.

---

## 7. Repository rules

If you protect `main` with a ruleset (**Settings → Rules**) or branch protection, this is how each rule interacts with the automation:

| Rule | Works with this repository? |
| --- | --- |
| Require signed commits | **Yes.** Sign your own commits, e.g. with `git config commit.gpgsign true`. `ppa.sh` commits with your git config. The sync commits through the GitHub API, and GitHub signs those commits. |
| Require linear history | **Yes.** `ppa.sh` rebases before pushing, and the sync only fast-forwards. |
| Block force pushes | **Yes.** Nothing force-pushes. |
| Require deployments to succeed (`github-pages`) | **No.** `github-pages` only accepts deployments from `main`, and a commit is only deployed after it reaches `main`, so no push can ever meet this rule. Every push fails with `Missing successful active github-pages deployment`. Remove the rule. The `test-ppa` job already checks every deploy. |
| Require a pull request, or require status checks | **Not for the sync.** The sync updates `main` directly, and `ppa.sh` pushes to it. With these rules, both are rejected. |

To see which rule rejected a push, open **Settings → Rules → Insights**, or run:

```bash
gh api "repos/OWNER/REPO/rulesets/rule-suites?time_period=day" --jq '.[] | {id, ref, result}'
gh api repos/OWNER/REPO/rulesets/rule-suites/ID --jq '.rule_evaluations[] | select(.result == "fail")'
```

---

## 8. Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| `Secret PPA_GPG_PRIVATE_KEY is not set` | Run `./ppa.sh setup`. |
| `Setup Pages` fails with `Get Pages site failed` | Pages is not enabled. Run `./ppa.sh setup`, or set **Settings → Pages → Source** to *GitHub Actions*. |
| CI hangs or fails asking for a passphrase / pinentry | The key in `PPA_GPG_PRIVATE_KEY` has a passphrase. Run `./ppa.sh rotate-key`. |
| Warning: `README.md install steps do not use …` | The URL or name changed (new domain, edited `ppa.conf`). Run `./ppa.sh setup`. |
| `dpkg-scanpackages: error: binary path pool/ not found` | `pool/` is empty and so not tracked by git. Add a package or `pool/.gitkeep`. |
| `test-ppa` times out waiting for the new build | Pages or its CDN is slow. Re-run the job. If it keeps failing, check that `PPA_URL` really serves this site. |
| Users get `Hash Sum mismatch` or `File has unexpected size` | Pages' CDN caches files for a few minutes and can briefly serve a new `InRelease` next to an old `Packages`. Wait a few minutes and run `apt update` again. |
| Users get `NO_PUBKEY` or `The following signatures couldn't be verified` | Their keyring is out of date (usually after a key rotation). Download `KEY.gpg` again. |
| A push to `main` did not deploy | The changed paths are outside the workflow's `paths:` filter (e.g. docs only). Run `gh workflow run deploy-ppa.yml`. |
| The sync warns `nothing downloaded` | The release has no asset matching the glob, the repository has no release, or it is private and `PPA_SYNC_TOKEN` is missing. |
| A push, or the sync's commit step, fails with `Repository rule violations` | A rule on `main` blocks it. See [Repository rules](#7-repository-rules). |
| The sync fails with `Update is not a fast forward` | `main` moved while the sync was committing. The next run retries, or run `./ppa.sh sync`. |
| The nightly sync stopped running | GitHub disables scheduled workflows in public repositories after 60 days without activity. Re-enable it in the Actions tab. Any push to this repository resets the clock, including the sync's own commits. |
