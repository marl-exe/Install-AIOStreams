# Install-AIOStreams

> **Looking for a $10.88/yr VPS?** Use my DediRock referral link: https://billing.dedirock.com/aff.php?aff=898
>
> This is a referral/affiliate link, which may provide me with a referral benefit if you sign up through it.

Recovery/install script for rebuilding the minimal AIOStreams Docker deployment on a fresh Ubuntu VPS.

The installer uses the reviewed `Viren070/docker-compose-template` revision pinned in the script, configures AIOStreams and Authelia, generates local secrets, and starts the deployment with Docker Compose.

## What the script does

- Verifies it is running as root.
- Validates the AIOStreams hostname, Authelia hostname, and Let's Encrypt email.
- Refuses to overwrite an existing `/opt/docker` deployment.
- Verifies TCP ports 80 and 443 are not already in use.
- Verifies both hostnames resolve to IPv4 addresses.
- Installs Docker Engine from Docker's official Ubuntu repository when needed.
- Creates a dedicated `aio` service account, preferring UID/GID `1000` when available and otherwise selecting the next free matching UID/GID.
- Reuses an existing `aio` account only when it is a non-root, `nologin` service account with a same-named primary group.
- Clones a pinned revision of `Viren070/docker-compose-template`.
- Configures the `required,aiostreams` Docker Compose profiles.
- Writes the actual `aio` account UID/GID into Docker `PUID` and `PGID`.
- Generates Authelia and AIOStreams secrets locally with OpenSSL.
- Prompts locally for the AIOStreams dashboard password and Authelia password.
- Hashes the Authelia password with Argon2 before writing the Authelia user database.
- Sets sensitive environment/configuration files to mode `600`.
- Removes the unused Traefik TCP/853 mapping and dashboard route from this deployment.
- Runs `docker compose config --quiet`, pulls images, and starts the stack.

## Supported Ubuntu releases

The current script accepts these Ubuntu codenames:

- `resolute`
- `noble`
- `jammy`

## Important requirements

Before running the installer:

1. Use a fresh Ubuntu VPS.
2. Create an IPv4 DNS A record for the AIOStreams hostname pointing to the VPS public IP.
3. Create an IPv4 DNS A record for the Authelia hostname pointing to the VPS public IP.
4. Ensure TCP ports 80 and 443 are free.
5. Ensure `/opt/docker` does not already exist.

### UID/GID behavior

The installer no longer requires UID/GID `1000` to be unused.

It prefers `1000`, but checks both the passwd and group databases. If either UID `1000` or GID `1000` is already allocated, the installer searches upward for the next number that is free as both a UID and a GID, up to `60000`.

For example, on a standard Ubuntu VPS where the initial `ubuntu` user already uses UID/GID `1000`, the installer will normally create:

```text
aio:x:1001:1001:...
```

and configure:

```text
PUID=1001
PGID=1001
```

The exact value depends on the accounts already present on the host.

If an `aio` user already exists from a previous partial installation, it is reused only if it is a non-root `/usr/sbin/nologin` account whose primary group is also named `aio`. Otherwise the installer stops rather than repurposing an unexpected account.

You can inspect the selected account after installation with:

```bash
id aio
getent passwd aio
getent group aio
```

## Clone the repository

```bash
git clone https://github.com/marl-exe/Install-AIOStreams.git
cd Install-AIOStreams
```

Because this repository is private, GitHub authentication is required when cloning it.

## Dry run first

A dry run validates the host and supplied inputs without installing packages, creating accounts, cloning the deployment template, or creating credentials.

```bash
sudo bash Install-AIOStreams.sh \
  --domain aio.example.com \
  --auth-host auth.aio.example.com \
  --email you@example.com \
  --dry-run
```

If the hostname/email options are omitted, the script prompts for them.

The dry run reports that the real installation will create or reuse the `aio` service account while preferring UID/GID `1000`; it does not modify the account database.

## Install

```bash
sudo bash Install-AIOStreams.sh \
  --domain aio.example.com \
  --auth-host auth.aio.example.com \
  --email you@example.com
```

During the real installation the script prompts for:

- AIOStreams dashboard username (default: `marl`)
- AIOStreams dashboard password
- Authelia login password

Passwords must contain at least 16 characters and may use letters, numbers, `.`, `_`, and `-`.

The passwords are entered silently and are not printed to terminal output.

## After installation

Open:

```text
https://aio.example.com/stremio/configure
```

Authenticate through Authelia, then use the separate AIOStreams dashboard credentials when requested.

Useful checks:

```bash
cd /opt/docker
docker compose ps
docker compose logs --tail=100
id aio
grep -E '^(PUID|PGID)=' .env
```

## Security notes

- No dashboard or Authelia passwords are hard-coded in this repository.
- Authelia session, storage-encryption, and JWT secrets are generated on the VPS.
- The AIOStreams `SECRET_KEY` is generated on the VPS.
- Sensitive `.env` and Authelia user files are restricted to mode `600`.
- The installer is fail-closed and refuses to replace an existing `/opt/docker` installation.
- The installer refuses to repurpose an unexpected existing `aio` account or group.
- Protect SSH, TCP/80, and TCP/443 with the VPS provider firewall as appropriate.
- Keep backups outside the VPS.

## Help

```bash
sudo bash Install-AIOStreams.sh --help
```

## Upstream template

The deployment is based on:

```text
https://github.com/Viren070/docker-compose-template.git
```

The exact revision used is pinned in `Install-AIOStreams.sh` rather than automatically tracking the upstream default branch.

---

## Need a VPS?

If you're looking for a VPS to run AIOStreams, you can use my DediRock referral link:

https://billing.dedirock.com/aff.php?aff=898

This is a referral/affiliate link, which may provide me with a referral benefit if you sign up through it.
