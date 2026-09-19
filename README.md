This is a personal APT repository. 

## Installation

To add this repository to your system, follow these steps:

1. Ensure the keyrings directory exists:
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

4. Update APT package lists:

```bash
sudo apt update
```

## Repository Files

* [KEY.gpg](KEY.gpg) (GPG Public Key)
* [t3st3ro.sources](t3st3ro.sources) (APT deb822 config)

