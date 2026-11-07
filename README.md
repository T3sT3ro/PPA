Personal APT repository for Debian and Ubuntu. GitHub Actions signs it and GitHub Pages serves it.

> Want your own? This repository is a template. See [Make your own APT repository](https://github.com/T3sT3ro/PPA/blob/main/TEMPLATE.md).

## Installation

To add this repository to your system:

1. Make sure the keyrings directory exists:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
```

2. Download the signing key:

```bash
sudo curl -fsSL https://dashunderdash.com/PPA/KEY.gpg \
    -o /etc/apt/keyrings/t3st3ro.asc
```

3. Download the repository source file:

```bash
sudo curl -fsSL https://dashunderdash.com/PPA/t3st3ro.sources \
    -o /etc/apt/sources.list.d/t3st3ro.sources
```

4. Update the APT package lists:

```bash
sudo apt update
```

Then install any package listed under [Available Packages](#available-packages):

```bash
sudo apt install <package-name>
```

## Removal

```bash
sudo rm /etc/apt/sources.list.d/t3st3ro.sources /etc/apt/keyrings/t3st3ro.asc
sudo apt update
```

Packages you already installed stay installed. Remove them with `sudo apt remove <package-name>`.

## Repository Files

* [KEY.gpg](KEY.gpg) (GPG public key)
* [t3st3ro.sources](t3st3ro.sources) (APT deb822 config)
