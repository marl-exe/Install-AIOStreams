#!/usr/bin/env bash
# Rebuilds the minimal AIOStreams deployment used by this VPS on a fresh Ubuntu host.
# It is intentionally fail-closed: it never replaces an existing /opt/docker install.

set -Eeuo pipefail
IFS=$'\n\t'

readonly INSTALL_DIR='/opt/docker'
readonly SERVICE_USER='aio'
readonly PREFERRED_SERVICE_ID='1000'
readonly MAX_SERVICE_ID='60000'
SERVICE_UID=''
SERVICE_GID=''
readonly TEMPLATE_REPOSITORY='https://github.com/Viren070/docker-compose-template.git'
readonly TEMPLATE_REF='59137ec0ae7cb4a9bb386d931cda4f327dbc8625'

DOMAIN=''
AUTH_HOST=''
LETSENCRYPT_EMAIL=''
DRY_RUN=false

log() {
  printf '[aio-recovery] %s\n' "$*"
}

die() {
  printf '[aio-recovery] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  sudo bash Install-AIOStreams.sh [options]

Options:
  --domain NAME       Public AIOStreams hostname (prompted when omitted)
  --auth-host NAME    Public Authelia hostname (prompted when omitted)
  --email ADDRESS     Let's Encrypt notification email (prompted when omitted)
  --dry-run           Validate host and inputs without changing the VPS
  --help              Show this help

Before a real run, create A records for both --domain and --auth-host pointing
at the VPS public IP. The script prompts locally for the hostnames, email,
AIOStreams dashboard credentials, and Authelia password; passwords are never
written to terminal output.
EOF
}

while (($#)); do
  case "$1" in
    --domain)
      DOMAIN=${2:?missing value for --domain}
      shift 2
      ;;
    --auth-host)
      AUTH_HOST=${2:?missing value for --auth-host}
      shift 2
      ;;
    --email)
      LETSENCRYPT_EMAIL=${2:?missing value for --email}
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ $EUID -eq 0 ]] || die 'run this script as root (for example: sudo bash ...)'

if [[ -z $DOMAIN ]]; then
  read -r -p 'AIOStreams public domain (for example: aio.example.com): ' DOMAIN
fi
if [[ -z $AUTH_HOST ]]; then
  read -r -p 'Authelia public domain (for example: auth.aio.example.com): ' AUTH_HOST
fi
if [[ -z $LETSENCRYPT_EMAIL ]]; then
  read -r -p "Let's Encrypt notification email: " LETSENCRYPT_EMAIL
fi

[[ -n $DOMAIN ]] || die 'AIOStreams public domain is required'
[[ -n $AUTH_HOST ]] || die 'Authelia public domain is required'
[[ -n $LETSENCRYPT_EMAIL ]] || die "Let's Encrypt notification email is required"
[[ $DOMAIN =~ ^[A-Za-z0-9.-]+$ ]] || die '--domain contains unsupported characters'
[[ $AUTH_HOST =~ ^[A-Za-z0-9.-]+$ ]] || die '--auth-host contains unsupported characters'
[[ $LETSENCRYPT_EMAIL == *@*.* ]] || die '--email is not a valid email address'
[[ ! -e $INSTALL_DIR ]] || die "$INSTALL_DIR already exists; refusing to overwrite an existing deployment"

source /etc/os-release
[[ ${ID:-} == 'ubuntu' ]] || die 'only Ubuntu is supported by this recovery script'
case ${VERSION_CODENAME:-} in
  resolute|noble|jammy) ;;
  *) die "Ubuntu ${VERSION_CODENAME:-unknown} is not supported by Docker's official repository setup" ;;
esac

if ss -ltnH | awk '{print $4}' | grep -Eq '(:80|:443)$'; then
  die 'TCP port 80 or 443 is already in use; stop and inspect the existing web service first'
fi

for hostname in "$DOMAIN" "$AUTH_HOST"; do
  getent ahostsv4 "$hostname" >/dev/null || die "$hostname has no IPv4 DNS record yet"
done

if [[ $DRY_RUN == true ]]; then
  log 'Dry run passed. No packages, files, containers, or credentials were changed.'
  log "Would install Docker Engine, create/reuse the $SERVICE_USER service account using a free UID/GID (preferring $PREFERRED_SERVICE_ID), clone template ref $TEMPLATE_REF, and publish $DOMAIN and $AUTH_HOST."
  exit 0
fi

read -r -p 'AIOStreams dashboard username [marl]: ' AIO_USERNAME
AIO_USERNAME=${AIO_USERNAME:-marl}
[[ $AIO_USERNAME =~ ^[A-Za-z0-9._-]+$ ]] || die 'dashboard username may contain only letters, numbers, dot, underscore, or hyphen'

read -r -s -p 'Choose AIOStreams dashboard password (16+ letters/numbers/._-): ' AIO_PASSWORD
printf '\n'
[[ $AIO_PASSWORD =~ ^[A-Za-z0-9._-]{16,}$ ]] || die 'dashboard password must be 16+ characters from letters, numbers, dot, underscore, or hyphen'

read -r -s -p 'Choose Authelia login password (16+ letters/numbers/._-): ' AUTHELIA_PASSWORD
printf '\n'
[[ $AUTHELIA_PASSWORD =~ ^[A-Za-z0-9._-]{16,}$ ]] || die 'Authelia password must be 16+ characters from letters, numbers, dot, underscore, or hyphen'

set_env_value() {
  local file=$1
  local key=$2
  local value=$3

  if grep -Eq "^[#[:space:]]*${key}=" "$file"; then
    sed -i -E "s|^[#[:space:]]*${key}=.*|${key}=${value}|" "$file"
  else
    printf '\n%s=%s\n' "$key" "$value" >>"$file"
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log 'Docker is already installed; using the existing Docker Engine.'
    systemctl enable --now docker
    command -v git >/dev/null 2>&1 || {
      apt-get update
      apt-get install -y git
    }
    return
  fi

  log 'Installing Docker Engine from Docker’s official Ubuntu repository.'
  apt-get update
  apt-get install -y ca-certificates curl git
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

find_available_service_id() {
  local candidate=$PREFERRED_SERVICE_ID

  while ((candidate <= MAX_SERVICE_ID)); do
    if ! getent passwd "$candidate" >/dev/null && ! getent group "$candidate" >/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
    ((candidate++))
  done

  return 1
}

create_service_account() {
  local existing_shell existing_group service_id

  if getent passwd "$SERVICE_USER" >/dev/null; then
    SERVICE_UID=$(id -u "$SERVICE_USER")
    SERVICE_GID=$(id -g "$SERVICE_USER")
    existing_shell=$(getent passwd "$SERVICE_USER" | cut -d: -f7)
    existing_group=$(getent group "$SERVICE_GID" | cut -d: -f1)

    [[ $SERVICE_UID -ne 0 && $SERVICE_GID -ne 0 ]] || die "existing $SERVICE_USER account unexpectedly uses UID or GID 0"
    [[ $existing_shell == '/usr/sbin/nologin' ]] || die "existing $SERVICE_USER account is not a nologin service account; refusing to repurpose it"
    [[ $existing_group == "$SERVICE_USER" ]] || die "existing $SERVICE_USER account does not use a same-named primary group; refusing to repurpose it"

    log "Reusing existing $SERVICE_USER service account (UID $SERVICE_UID, GID $SERVICE_GID)."
    return
  fi

  if getent group "$SERVICE_USER" >/dev/null; then
    die "group $SERVICE_USER already exists without a matching user; refusing to repurpose it"
  fi

  service_id=$(find_available_service_id) || die "no free UID/GID found between $PREFERRED_SERVICE_ID and $MAX_SERVICE_ID"

  groupadd --gid "$service_id" "$SERVICE_USER"
  if ! useradd --uid "$service_id" --gid "$service_id" --create-home --shell /usr/sbin/nologin "$SERVICE_USER"; then
    groupdel "$SERVICE_USER" >/dev/null 2>&1 || true
    die "failed to create $SERVICE_USER service account"
  fi

  SERVICE_UID=$service_id
  SERVICE_GID=$service_id
  log "Created $SERVICE_USER service account with UID/GID $service_id."
}

install_docker
create_service_account

log "Cloning the reviewed template revision $TEMPLATE_REF."
git clone "$TEMPLATE_REPOSITORY" "$INSTALL_DIR"
git -C "$INSTALL_DIR" checkout --detach "$TEMPLATE_REF"

set_env_value "$INSTALL_DIR/.env" 'TZ' 'Asia/Manila'
set_env_value "$INSTALL_DIR/.env" 'PUID' "$SERVICE_UID"
set_env_value "$INSTALL_DIR/.env" 'PGID' "$SERVICE_GID"
set_env_value "$INSTALL_DIR/.env" 'COMPOSE_PROFILES' '"required,aiostreams"'
set_env_value "$INSTALL_DIR/.env" 'LETSENCRYPT_EMAIL' "$LETSENCRYPT_EMAIL"
set_env_value "$INSTALL_DIR/.env" 'DOMAIN' "$DOMAIN"
set_env_value "$INSTALL_DIR/.env" 'AIOSTREAMS_HOSTNAME' "$DOMAIN"
set_env_value "$INSTALL_DIR/.env" 'AUTHELIA_HOSTNAME' "$AUTH_HOST"
set_env_value "$INSTALL_DIR/.env" 'COMPOSE_REMOVE_ORPHANS' 'false'
set_env_value "$INSTALL_DIR/.env" 'AUTHELIA_SESSION_SECRET' "\"$(openssl rand -hex 32)\""
set_env_value "$INSTALL_DIR/.env" 'AUTHELIA_STORAGE_ENCRYPTION_KEY' "\"$(openssl rand -hex 32)\""
set_env_value "$INSTALL_DIR/.env" 'AUTHELIA_JWT_SECRET' "\"$(openssl rand -hex 32)\""

set_env_value "$INSTALL_DIR/apps/aiostreams/.env" 'SECRET_KEY' "$(openssl rand -hex 32)"
set_env_value "$INSTALL_DIR/apps/aiostreams/.env" 'AIOSTREAMS_AUTH' "$AIO_USERNAME:$AIO_PASSWORD"
set_env_value "$INSTALL_DIR/apps/aiostreams/.env" 'AIOSTREAMS_AUTH_ADMINS' "$AIO_USERNAME"
set_env_value "$INSTALL_DIR/apps/aiostreams/.env" 'LOG_SENSITIVE_INFO' 'false'
chmod 600 "$INSTALL_DIR/.env" "$INSTALL_DIR/apps/aiostreams/.env"

# The template maps TCP/853 and publishes an unactioned dashboard route. Neither
# is needed for this deployment; retain only the verified HTTP/HTTPS endpoints.
sed -i -e '/      - 853:853/d' -e '/^[[:space:]]*labels:$/d' -e '/traefik.enable=true/d' -e '/traefik.http.routers.api/d' -e '/traefik.http.services.api/d' "$INSTALL_DIR/apps/traefik/compose.yaml"

install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$INSTALL_DIR/data/aiostreams"
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/apps/authelia/config"

log 'Generating the Authelia password hash without printing the password.'
docker pull authelia/authelia:latest >/dev/null
AUTHELIA_HASH=$(docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password "$AUTHELIA_PASSWORD" | awk '/^Digest: / {print $2; exit}')
[[ $AUTHELIA_HASH == '$argon2id$'* ]] || die 'Authelia password hash generation failed'

cat >"$INSTALL_DIR/apps/authelia/config/users.yml" <<EOF
---
users:
  $AIO_USERNAME:
    disabled: false
    displayname: "$AIO_USERNAME"
    password: "$AUTHELIA_HASH"
    email: "$LETSENCRYPT_EMAIL"
    groups:
      - admins
...
EOF
chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/apps/authelia/config/users.yml"
chmod 600 "$INSTALL_DIR/apps/authelia/config/users.yml"

unset AIO_PASSWORD AUTHELIA_PASSWORD AUTHELIA_HASH

cd "$INSTALL_DIR"
docker compose config --quiet
docker compose pull
docker compose up -d

log 'Deployment complete.'
log "Open https://$DOMAIN/stremio/configure and log in through Authelia as $AIO_USERNAME."
log 'Then sign in to the AIOStreams dashboard using the separate dashboard password you entered.'
log 'Protect SSH, TCP/80, and TCP/443 with your VPS-provider firewall. Store backups off the VPS.'
