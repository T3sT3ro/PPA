# Make your own APT repository

This repository is a template for a personal APT repository (a "PPA") that runs entirely on GitHub, with no server to maintain:

* You commit `.deb` files to `pool/`, or let a workflow pull them in from your other repositories' GitHub releases.
* GitHub Actions builds the APT metadata and signs it with your key.
* GitHub Pages hosts the result, together with a landing page that has install instructions and a package table.
* After each deploy, a test job adds the repository in a clean Ubuntu container to check that `apt update` accepts it.

You need a GitHub account, `git`, `gpg` and the [GitHub CLI](https://cli.github.com/), logged in with `gh auth login`. Setup takes about five minutes.

---

## 1. Create your repository

```bash
gh repo create <you>/PPA --template T3sT3ro/PPA --public --clone
cd PPA
```

Or click **Use this template → Create a new repository** on [T3sT3ro/PPA](https://github.com/T3sT3ro/PPA) and clone the result.

* **Make it public.** GitHub Pages on private repositories needs a paid plan, and APT clients have to reach the files without authentication anyway.
* **Use the template rather than a fork.** A template copy starts with clean history and Actions enabled.
* **Expect the first run to fail.** The template's initial commit may start a workflow run before setup is done. It fails with "Secret PPA_GPG_PRIVATE_KEY is not set". Ignore it.

## 2. Run setup

```bash
./ppa.sh setup
```

The command is safe to re-run. It only changes what is missing or wrong:

1. Enables GitHub Pages, with GitHub Actions as the source.
2. Creates a signing key and stores it in the `PPA_GPG_PRIVATE_KEY` secret, if that secret does not exist yet. The key never touches your personal keyring. Add `--key-backup ~/ppa-key.asc` to keep a copy.
3. Sets the repository's homepage to the repository URL.
4. Points the install steps in `README.md` at your URL and name, commits, and asks before pushing. The push starts the first deploy.

Nothing else needs editing. The deploy workflow works out these values itself:

| Setting | Default | Example for `alice/PPA` |
| --- | --- | --- |
| URL | Your GitHub Pages URL, over https. Includes a custom domain if you set one. | `https://alice.github.io/PPA` |
| Name | Owner in lowercase. Used for `/etc/apt/keyrings/<name>.asc` and `/etc/apt/sources.list.d/<name>.sources`. | `alice` |
| Title | `<owner>'s PPA` | `alice's PPA` |

To change any of them, set `PPA_URL`, `PPA_NAME` or `PPA_TITLE` in [`ppa.conf`](ppa.conf), then run `./ppa.sh setup` again so `README.md` follows.

## 3. Add packages

Replace the demo package (`pool/hello-kitty_*.deb`) with your own, using either or both of these:

* **By hand:** copy `.deb` files into `pool/`, then commit and push. Each push to `pool/` deploys.
* **From another repository's releases:**

  ```bash
  ./ppa.sh connect <you>/my-tool               # all .deb assets
  ./ppa.sh connect <you>/other '*_amd64.deb'   # only matching assets
  ```

  This adds the repository to [`upstreams.txt`](upstreams.txt) and pushes. A sync then copies the `.deb` assets of its latest release into `pool/` and deploys. Afterwards a sync runs every night. Add `--notify` to also sync right after each release: the command walks you through creating the token and prints the step to add to the other repository's release workflow.

Do not let `pool/` become empty. The deploy needs the directory to exist, so commit a `pool/.gitkeep` if you remove every package.

## 4. Check

Open the **Actions** tab. **Build and Deploy PPA** should pass both jobs. `test-ppa` waits until the new build is live, then installs the repository the way `README.md` describes. If something fails, see [Troubleshooting](DEVELOPMENT.md#7-troubleshooting).

Then follow the install steps on your site on a Debian or Ubuntu machine:

```bash
sudo apt update
apt policy <package-name>   # shows your repository as a source
```

---

## Custom domains

GitHub Pages serves a project repository at `https://<you>.github.io/<repo>`. You have two ways to use your own domain:

* **Your user site already has a custom domain.** Your `<you>.github.io` repository has one set, so every project site is served under it automatically, at `https://example.com/<repo>`. That is how this repository ends up at `dashunderdash.com/PPA`.
* **A dedicated subdomain for the repository.** Set it under **Settings → Pages → Custom domain** (e.g. `ppa.example.com`) and point a DNS `CNAME` record at `<you>.github.io`.

In both cases the deploy picks up the new URL by itself. Run `./ppa.sh setup` again to update `README.md`. Users who already added the repository need the new `.sources` file.

## Setting up without ppa.sh

`ppa.sh` is a convenience. You can do the same by hand:

1. **Create a signing key without a passphrase**, in a throwaway keyring, and store it as a secret:

   ```bash
   export GNUPGHOME="$(mktemp -d)"
   gpg --batch --passphrase '' --quick-generate-key "My PPA signing key" ed25519 sign never
   gpg --armor --export-secret-keys | gh secret set PPA_GPG_PRIVATE_KEY
   rm -rf "$GNUPGHOME"; unset GNUPGHOME
   ```

   In the web UI, the secret goes under **Settings → Secrets and variables → Actions**.

2. **Enable Pages:** under **Settings → Pages**, set **Source** to **GitHub Actions**.
3. **Point the install steps in `README.md` at your values:** your URL, and your name in place of `t3st3ro` in the `.asc` and `.sources` file names.

## Limitations

* **One package set for every release.** This is a flat repository: every Debian or Ubuntu release gets the same packages. Build packages against the oldest release you support, or declare `Depends:` carefully.
* **One signing key**, held as a GitHub secret. Anyone with admin access to the repository can use it through a workflow.
* **GitHub limits:** 100 MB per file, about 1 GB per Pages site, and a soft bandwidth limit of 100 GB per month. Every `.deb` stays in git history even after you delete it. This setup suits personal tools, not large binaries or heavy traffic.

## Getting upstream fixes

A template copy has no shared history with this repository. From time to time, compare `ppa.sh`, `scripts/` and `.github/workflows/` with [T3sT3ro/PPA](https://github.com/T3sT3ro/PPA) and copy changes over by hand.
