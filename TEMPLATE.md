# Make your own APT repository

This repository is a template for a personal APT repository (a "PPA") that runs entirely on GitHub, with no server to maintain:

* You commit `.deb` files to `pool/`.
* GitHub Actions builds the APT metadata and signs it with your GPG key.
* GitHub Pages hosts the result, together with a landing page that has install instructions and a package list.
* After each deploy, a test job adds the repository in a clean Ubuntu container to check that `apt update` accepts it.

Setup takes about 15 minutes. You need a GitHub account, `git`, `gpg` and, optionally, the [GitHub CLI](https://cli.github.com/) (`gh`). Every `gh` command below also has a matching option in the web UI.

For how the pipeline works after setup, see [DEVELOPMENT.md](DEVELOPMENT.md).

---

## 1. Create your repository

Click **Use this template → Create a new repository** on [T3sT3ro/PPA](https://github.com/T3sT3ro/PPA), or run:

```bash
gh repo create <you>/PPA --template T3sT3ro/PPA --public --clone
cd PPA
```

* **Make it public.** GitHub Pages on private repositories needs a paid plan, and APT clients have to reach the files without authentication anyway.
* **Use the template rather than a fork.** A template copy starts with clean history and Actions enabled.
* **Expect the first run to fail.** The template's initial commit may start a workflow run before the secrets exist. Ignore it.

Choose three values now. The rest of this guide calls them:

| Placeholder | Meaning | Value in this repository |
| --- | --- | --- |
| `<site-url>` | Where Pages serves the repository: `https://<you>.github.io/<repo>` (see [Custom domains](#custom-domains)) | `https://dashunderdash.com/PPA` |
| `<name>` | Short lowercase ID for the keyring and `.sources` file names on users' machines | `t3st3ro` |
| `<title>` | Landing page title | `T3sT3ro's PPA` |

## 2. Create the signing key

The workflow signs without anyone at the keyboard, so the key **must not have a passphrase**. Create it in a throwaway keyring so it never mixes with your personal keys:

```bash
export GNUPGHOME="$(mktemp -d)"
gpg --batch --passphrase '' --quick-generate-key \
    "<you> PPA signing key <ppa@example.com>" ed25519 sign never
```

The email address does not have to be a real mailbox. A GitHub noreply address works. It only identifies the key.

Store the key as repository secrets:

```bash
gpg --armor --export-secret-keys ppa@example.com \
    | gh secret set PPA_GPG_PRIVATE_KEY
gh secret set PPA_GPG_EMAIL --body ppa@example.com
```

In the web UI, add the same two secrets under **Settings → Secrets and variables → Actions**. Paste the output of `gpg --armor --export-secret-keys ppa@example.com` as the value of `PPA_GPG_PRIVATE_KEY`.

To keep a backup, save the exported private key in a password manager. Then delete the temporary keyring:

```bash
rm -rf "$GNUPGHOME"; unset GNUPGHOME
```

If you lose the key, it is not a disaster: generate a new one and follow the steps in [DEVELOPMENT.md → Rotating the signing key](DEVELOPMENT.md#5-rotating-the-signing-key).

> **Never commit the private key**, not even briefly. It stays in git history after you delete the file.

## 3. Enable GitHub Pages

Under **Settings → Pages → Build and deployment**, set **Source** to **GitHub Actions**. Or:

```bash
gh api -X POST repos/<you>/PPA/pages -f build_type=workflow
```

## 4. Replace this repository's values

Change these files from this repository's values to yours:

| File | Change |
| --- | --- |
| `t3st3ro.sources` | Rename to `<name>.sources` (`git mv t3st3ro.sources <name>.sources`). Set `URIs:` to `<site-url>` and `Signed-By:` to `/etc/apt/keyrings/<name>.asc`. |
| `README.md` | In installation steps 2 and 3, the removal command and *Repository Files*: replace the URLs with `<site-url>` and `t3st3ro` with `<name>`. Rewrite the first line to describe your repository. You may keep or drop the *Want your own?* note. |
| `.github/workflows/deploy-ppa.yml` | `on.push.paths`: change `t3st3ro.sources` to `<name>.sources`. *Generate HTML index* step: set `--metadata title=` to `<title>`. *Add PPA* step of the `test-ppa` job: change both URLs and file names, as in `README.md`. |
| `pool/hello-kitty_0.1.0-1_amd64.deb` | A demo package. Replace it with your own `.deb`, or keep it for the first deploy and remove it later. `pool/` must not end up empty. Add a `pool/.gitkeep` if it would. |
| `template.html` | Optional: change the landing page's look. |

Then check that nothing still points at this repository:

```bash
git grep -n -i -e t3st3ro -e dashunderdash -- ':!TEMPLATE.md'
```

The only expected result is the *Want your own?* link in `README.md`, if you kept it. It points back to this guide on purpose.

The `.sources` file, for reference:

```text
Types: deb
URIs: <site-url>
Suites: ./
Signed-By: /etc/apt/keyrings/<name>.asc
```

## 5. Deploy and check

```bash
git add -A
git commit -m "Set up my PPA"
git push
```

On the **Actions** tab, **Build and Deploy PPA** should pass both jobs:

* **`build-and-deploy` failed:** read the [troubleshooting table](DEVELOPMENT.md#6-troubleshooting). It is almost always a secret or the Pages source setting.
* **`test-ppa` failed right after a successful deploy:** Pages may still be propagating. Re-run the job.

Then follow the install steps on `<site-url>` on a Debian or Ubuntu machine:

```bash
sudo apt update
apt policy <package-name>   # shows your repository as a source
```

## 6. Next steps

* **Publish packages:** commit `.deb` files to `pool/`. See [DEVELOPMENT.md → Publishing packages by hand](DEVELOPMENT.md#3-publishing-packages-by-hand).
* **Automate releases:** pull `.deb` files from other repositories' GitHub releases on a schedule or on each release. See [DEVELOPMENT.md → Syncing packages](DEVELOPMENT.md#4-syncing-packages-from-other-repositories-releases).
* **Get upstream fixes:** a template copy has no shared history with this repository. Compare [`deploy-ppa.yml`](https://github.com/T3sT3ro/PPA/blob/main/.github/workflows/deploy-ppa.yml) with yours from time to time and copy changes over by hand.

---

## Custom domains

GitHub Pages serves a project repository at `https://<you>.github.io/<repo>`. You have two ways to use your own domain:

* **Your user site already has a custom domain.** Your `<you>.github.io` repository has one set, so every project site is served under it automatically, at `https://example.com/<repo>`. That is how this repository ends up at `dashunderdash.com/PPA`. No changes are needed in this repository.
* **A dedicated subdomain for the repository.** Set it under **Settings → Pages → Custom domain** (e.g. `ppa.example.com`) and point a DNS `CNAME` record at `<you>.github.io`. With Actions-based deploys, the domain comes from that setting, and no `CNAME` file is needed.

In both cases, use the final URL as `<site-url>` in step 4, and enable **Enforce HTTPS**.

## Limitations

* **One package set for every release.** This is a flat repository: every Debian or Ubuntu release gets the same packages. Build packages against the oldest release you support, or declare `Depends:` carefully.
* **One signing key**, held as a GitHub secret. Anyone with admin access to the repository can use it through a workflow.
* **GitHub limits:** 100 MB per file, about 1 GB per Pages site, and a soft bandwidth limit of 100 GB per month. Every `.deb` stays in git history even after you delete it. This setup suits personal tools, not large binaries or heavy traffic.
