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
#   TELEPORT_VERSION  18.6.8       must not be newer than the cluster
#   TELEPORT_MIRROR   (empty)      base URL of a teleport-keycloak-ldap binaries
#                                  mirror, e.g. https://binaries.example.org;
#                                  empty — cdn.teleport.dev
#   TELEPORT_SHA256   (empty)      tarball hash; empty — take the .sha256
#                                  published on cdn.teleport.dev (a second
#                                  channel when the tarball comes from a mirror)
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} teleport-agent: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} teleport-agent: $*"; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/lib/bisquite-conf" ]] || { log_error "рядом нет lib/bisquite-conf — сборка не доставила lib/ источника"; exit 1; }
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"

TELEPORT_VERSION="${TELEPORT_VERSION:-18.6.8}"
TELEPORT_MIRROR="${TELEPORT_MIRROR:-}"
TELEPORT_SHA256="${TELEPORT_SHA256:-}"

[[ "$TELEPORT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { log_error "TELEPORT_VERSION='$TELEPORT_VERSION': ожидали X.Y.Z"; exit 1; }
[[ -z "$TELEPORT_SHA256" || "$TELEPORT_SHA256" =~ ^[0-9a-f]{64}$ ]] || { log_error "TELEPORT_SHA256: ожидали 64 hex"; exit 1; }
[[ -z "$TELEPORT_MIRROR" || "$TELEPORT_MIRROR" =~ ^https?://[A-Za-z0-9.:/-]+$ ]] || { log_error "TELEPORT_MIRROR='$TELEPORT_MIRROR': ожидали URL"; exit 1; }

case "$(dpkg --print-architecture)" in
    amd64) ARCH=amd64 ;;
    arm64) ARCH=arm64 ;;
    *) log_error "архитектура $(dpkg --print-architecture) не поддерживается"; exit 1 ;;
esac

for f in bisquite-teleport knobs knobs.apply teleport.service bisquite-teleport-apps.path bisquite-teleport-apps.service \
         bisquite-teleport-token.path bisquite-teleport-token.service; do
    [[ -f "$SCRIPT_DIR/$f" ]] || { log_error "рядом нет $f"; exit 1; }
done

if ! command -v curl >/dev/null 2>&1; then
    apt-get update -q && apt-get install -y -q --no-install-recommends curl ca-certificates
fi

FILE="teleport-v${TELEPORT_VERSION}-linux-${ARCH}-bin.tar.gz"
CDN_URL="https://cdn.teleport.dev/${FILE}"
if [[ -n "$TELEPORT_MIRROR" ]]; then
    URL="${TELEPORT_MIRROR%/}/binaries/teleport/${TELEPORT_VERSION}/${FILE}"
else
    URL="$CDN_URL"
fi

if [[ -x /usr/local/bin/teleport ]] && /usr/local/bin/teleport version 2>/dev/null | grep -q "v${TELEPORT_VERSION} "; then
    log_info "Teleport ${TELEPORT_VERSION} уже установлен"
else
    WORK="$(mktemp -d /var/tmp/teleport-agent.XXXXXX)"
    trap 'rm -r -f -- "$WORK"' EXIT
    if [[ -z "$TELEPORT_SHA256" ]]; then
        TELEPORT_SHA256="$(curl -fsSL --retry 5 --retry-delay 3 "${CDN_URL}.sha256" | awk '{print $1}')" || true
        [[ "$TELEPORT_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
            log_error "не получить ${CDN_URL}.sha256 — задайте TELEPORT_SHA256 явно"; exit 1; }
        log_info "sha256 взят с cdn.teleport.dev"
    fi
    log_info "скачиваю $URL"
    # Stalls become retries instead of an endless wait (see selkies/install.sh).
    curl -fL --retry 5 --retry-delay 5 \
        --connect-timeout 30 --speed-limit 10240 --speed-time 60 \
        -o "$WORK/$FILE" "$URL" || { log_error "tarball не скачался"; exit 1; }
    echo "${TELEPORT_SHA256}  $WORK/$FILE" | sha256sum -c --quiet - || { log_error "sha256 не совпал"; exit 1; }
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
