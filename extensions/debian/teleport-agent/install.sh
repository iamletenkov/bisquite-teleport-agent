#!/usr/bin/env bash
# Teleport agent for a Teleport cluster: SSH node + web apps, no inbound ports.
#
# Build phase only lays down the binary and the tooling. The image stays
# neutral to the cluster: proxy address, env, CA pin and token are given on
# the device by `bisquite-teleport join`, so one image serves robots of
# different clusters and env. The agent is NOT started here — an identity in
# /var/lib/teleport would make every copy of the image the same node.
#
# Parameters (environment, from VMFILE):
#   TELEPORT_VERSION  18.10.0      must not be newer than the cluster;
#                                  bound_keypair join needs >= 18.8.0
#   TELEPORT_MIRROR   (empty)      base URL of a binaries mirror with the
#                                  teleport-keycloak-ldap layout
#                                  <base>/binaries/teleport/<ver>/<tarball>,
#                                  e.g. https://binaries.example.org;
#                                  empty — cdn.teleport.dev
#   TELEPORT_SHA256   (empty)      tarball hash; empty — take the .sha256
#                                  published on cdn.teleport.dev (a second
#                                  channel when the tarball comes from a
#                                  mirror). A rebuilt fork differs from the
#                                  vanilla tarball: pin its hash here.

# Download source — pure functions; tools/test-conf.sh sources this file and
# calls them, nothing below the guard runs then.
teleport_default_version(){ echo 18.10.0; }
# dpkg architecture -> Teleport tarball architecture. Debian, Ubuntu,
# Raspberry Pi OS 64-bit and JetPack (Ubuntu on Jetson) all report amd64 or
# arm64; 32-bit armhf is not declared by the manifest.
teleport_arch(){
    case "$1" in
        amd64) echo amd64 ;;
        arm64) echo arm64 ;;
        *) return 1 ;;
    esac
}
teleport_tarball(){ echo "teleport-v$1-linux-$2-bin.tar.gz"; }
# teleport_url <version> <arch> <mirror>
teleport_url(){
    if [[ -n "$3" ]]; then
        echo "${3%/}/binaries/teleport/$1/$(teleport_tarball "$1" "$2")"
    else
        echo "https://cdn.teleport.dev/$(teleport_tarball "$1" "$2")"
    fi
}
teleport_sha256_url(){ echo "https://cdn.teleport.dev/$(teleport_tarball "$1" "$2").sha256"; }
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} teleport-agent: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} teleport-agent: $*"; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/lib/bisquite-conf" ]] || { log_error "рядом нет lib/bisquite-conf — сборка не доставила lib/ источника"; exit 1; }
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"

TELEPORT_VERSION="${TELEPORT_VERSION:-$(teleport_default_version)}"
TELEPORT_MIRROR="${TELEPORT_MIRROR:-}"
TELEPORT_SHA256="${TELEPORT_SHA256:-}"

[[ "$TELEPORT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { log_error "TELEPORT_VERSION='$TELEPORT_VERSION': ожидали X.Y.Z"; exit 1; }
[[ -z "$TELEPORT_SHA256" || "$TELEPORT_SHA256" =~ ^[0-9a-f]{64}$ ]] || { log_error "TELEPORT_SHA256: ожидали 64 hex"; exit 1; }
[[ -z "$TELEPORT_MIRROR" || "$TELEPORT_MIRROR" =~ ^https?://[A-Za-z0-9.:/-]+$ ]] || { log_error "TELEPORT_MIRROR='$TELEPORT_MIRROR': ожидали URL"; exit 1; }

DPKG_ARCH="$(dpkg --print-architecture)"
ARCH="$(teleport_arch "$DPKG_ARCH")" || { log_error "архитектура $DPKG_ARCH не поддерживается"; exit 1; }

for f in bisquite-teleport knobs knobs.apply teleport.service bisquite-teleport-apps.path bisquite-teleport-apps.service \
         bisquite-teleport-token.path bisquite-teleport-token.service; do
    [[ -f "$SCRIPT_DIR/$f" ]] || { log_error "рядом нет $f"; exit 1; }
done

if ! command -v curl >/dev/null 2>&1; then
    apt-get update -q && apt-get install -y -q --no-install-recommends curl ca-certificates
fi

FILE="$(teleport_tarball "$TELEPORT_VERSION" "$ARCH")"
URL="$(teleport_url "$TELEPORT_VERSION" "$ARCH" "$TELEPORT_MIRROR")"
SHA256_URL="$(teleport_sha256_url "$TELEPORT_VERSION" "$ARCH")"
SHA256_FROM_CDN=0

if [[ -x /usr/local/bin/teleport ]] && /usr/local/bin/teleport version 2>/dev/null | grep -q "v${TELEPORT_VERSION} "; then
    log_info "Teleport ${TELEPORT_VERSION} уже установлен"
else
    WORK="$(mktemp -d /var/tmp/teleport-agent.XXXXXX)"
    trap 'rm -r -f -- "$WORK"' EXIT
    if [[ -z "$TELEPORT_SHA256" ]]; then
        TELEPORT_SHA256="$(curl -fsSL --retry 5 --retry-delay 3 "$SHA256_URL" | awk '{print $1}')" || true
        [[ "$TELEPORT_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
            log_error "не получить $SHA256_URL — задайте TELEPORT_SHA256 явно"; exit 1; }
        SHA256_FROM_CDN=1
        log_info "sha256 взят с cdn.teleport.dev"
    fi
    log_info "скачиваю $URL"
    # Stalls become retries instead of an endless wait (see selkies/install.sh).
    curl -fL --retry 5 --retry-delay 5 \
        --connect-timeout 30 --speed-limit 10240 --speed-time 60 \
        -o "$WORK/$FILE" "$URL" || { log_error "tarball не скачался"; exit 1; }
    if ! echo "${TELEPORT_SHA256}  $WORK/$FILE" | sha256sum -c --quiet -; then
        # A mirror may carry a rebuilt fork of the same version: its tarball
        # is not the vanilla one the CDN hash describes.
        if (( SHA256_FROM_CDN )) && [[ -n "$TELEPORT_MIRROR" ]]; then
            log_error "tarball с зеркала не совпал с .sha256 cdn.teleport.dev — на зеркале своя сборка? задайте TELEPORT_SHA256 её хешем"
        else
            log_error "sha256 не совпал"
        fi
        exit 1
    fi
    # Only the agent: tsh, tctl, tbot and teleport-update are ~370 MB more and
    # a node needs none of them.
    tar -xzf "$WORK/$FILE" -C "$WORK" teleport/teleport
    install -m 0755 "$WORK/teleport/teleport" /usr/local/bin/teleport
    /usr/local/bin/teleport version | grep -q "v${TELEPORT_VERSION} " || { log_error "teleport version не совпал с ${TELEPORT_VERSION}"; exit 1; }
    log_info "установлен $(/usr/local/bin/teleport version | head -1)"
fi

# A link, not a copy: the CLI finds lib/bisquite-conf next to itself through
# `readlink -f`, i.e. always the library of the build that installed it.
chmod +x "$SCRIPT_DIR/bisquite-teleport"
install -d -m 0755 /usr/local/sbin
ln -sfn "$SCRIPT_DIR/bisquite-teleport" /usr/local/sbin/bisquite-teleport
for u in teleport.service bisquite-teleport-apps.path bisquite-teleport-apps.service \
         bisquite-teleport-token.path bisquite-teleport-token.service; do
    install -m 0644 "$SCRIPT_DIR/$u" "/etc/systemd/system/$u"
done
# Path units always on (cheap, no-ops until joined); the agent itself is
# enabled by `join`. Links, not `systemctl enable`: no systemd in the build.
install -d /etc/systemd/system/paths.target.wants
ln -sf /etc/systemd/system/bisquite-teleport-apps.path /etc/systemd/system/paths.target.wants/
ln -sf /etc/systemd/system/bisquite-teleport-token.path /etc/systemd/system/paths.target.wants/

# Settings file through the library: created once, never rewritten — a
# rebuild on top of an image keeps what `join`/`set` wrote. No --env: the image
# stays neutral to the cluster, env and apps are given on the device.
install -d -m 0755 /etc/bisquite/teleport/apps.d
conf_init teleport "$SCRIPT_DIR/knobs" || { log_error "/etc/bisquite/teleport/config не записан"; exit 1; }
install -d -m 0750 /var/lib/teleport

if [[ -s /var/lib/teleport/host_uuid ]] && [[ ! -d /run/systemd/system ]]; then
    log_error "в /var/lib/teleport уже есть регистрация — образ стал бы одной нодой на все копии"
    exit 1
fi

log_info "готово: подключение — sudo bisquite-teleport join TELEPORT_PROXY=… TELEPORT_TOKEN=… TELEPORT_ENV=…"
