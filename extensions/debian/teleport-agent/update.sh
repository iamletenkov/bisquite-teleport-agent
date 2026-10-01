#!/usr/bin/env bash
# Update the teleport-agent extension on a running robot from an archive
#
#   git archive <ref> extensions/debian/teleport-agent lib | gzip -n
#
# (a portal serves it with its sha256 next to it; checking the sum is the
# downloader's job). Run from the unpacked tree, as root:
#
#   sudo bash <unpacked>/extensions/debian/teleport-agent/update.sh
#
# The archive is laid out the way the bisquite build does it (layout 2,
# docs/extensions.md): lib/ goes to /opt/bisquite/lib/<sha256>/ (the build's
# fingerprint of the tree), the extension to /opt/bisquite/teleport-agent/
# with the lib link. Then the extension's own install.sh (CLI and schema
# links, units; the config is never rewritten) with TELEPORT_VERSION = the
# installed agent, so the binary of the running agent is neither replaced nor
# downloaded. Then daemon-reload and the labels timer. The agent is not
# restarted. A robot of the earlier layout (/opt/vmsetup/teleport-agent)
# moves to /opt/bisquite; the old directory stays on disk.
#
# BISQUITE_TELEPORT_ROOT — a scratch root for the tests
# (tools/test-teleport-labels.sh).
set -euo pipefail

log(){ >&2 echo "teleport-agent update: $*"; }
die(){ log "ОШИБКА: $*"; exit 1; }

NAME=teleport-agent
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd -P "$SCRIPT_DIR/../../.." && pwd)"
ROOT="${BISQUITE_TELEPORT_ROOT:-}"
export BISQUITE_CONF_ROOT="${BISQUITE_CONF_ROOT:-$ROOT}"
GUEST="$ROOT/opt/bisquite"
TARGET="$GUEST/$NAME"
LEGACY="$ROOT/opt/vmsetup/$NAME"
BIN="$ROOT/usr/local/bin/teleport"
TIMER=bisquite-teleport-labels.timer

has_systemd(){
    case "${BISQUITE_TELEPORT_SYSTEMD:-}" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    [[ -z "$ROOT" && -d /run/systemd/system ]]
}

# The fingerprint the bisquite build gives lib/ (LinuxBuilder._library_digest):
# entries in Python's Path order (component by component), each as
# "D <rel>\0", "L <rel> -> <target>\0" or "F <rel>\0<content>\0".
lib_digest(){
    local lib="$1" rel
    find "$lib" -mindepth 1 -printf '%P\n' | sed 's|/|\x01|g' | LC_ALL=C sort | sed 's|\x01|/|g' |
    while IFS= read -r rel; do
        if [[ -L "$lib/$rel" ]]; then
            printf 'L %s -> %s\0' "$rel" "$(readlink "$lib/$rel")"
        elif [[ -f "$lib/$rel" ]]; then
            printf 'F %s\0' "$rel"; cat -- "$lib/$rel"; printf '\0'
        elif [[ -d "$lib/$rel" ]]; then
            printf 'D %s\0' "$rel"
        fi
    done | sha256sum | cut -d' ' -f1
}

[[ -n "$ROOT" || "$(id -u)" -eq 0 ]] || die "нужен root (sudo)"
if [[ -d "$TARGET" && "$(cd -P "$TARGET" && pwd)" == "$SCRIPT_DIR" ]]; then
    die "update.sh запущен из установленного каталога — запускайте из распаковки архива"
fi
[[ -f "$SCRIPT_DIR/extension.yaml" && -f "$SCRIPT_DIR/install.sh" ]] || die "рядом нет extension.yaml и install.sh"
[[ -f "$SRC/lib/bisquite-conf" ]] \
    || die "нет lib/ архива ($SRC/lib) — запускайте из распаковки git archive <ref> extensions/debian/$NAME lib"
version="$(sed -n 's/^version:[[:space:]]*\([0-9.]*\).*/\1/p' "$SCRIPT_DIR/extension.yaml" | head -n 1)"

# Only an installed agent is updated: a new robot gets the extension with
# its image. The version keeps install.sh off the binary.
agent="$("$BIN" version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | tr -d v)" || agent=""
[[ "$agent" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "агент Teleport не установлен ($BIN не отвечает на version) — update.sh обновляет установленное расширение"

previous="нет"
if [[ -f "$TARGET/extension.yaml" ]]; then
    previous="$(sed -n 's/^version:[[:space:]]*//p' "$TARGET/extension.yaml" | head -n 1)"
elif [[ -d "$LEGACY" ]]; then
    previous="раскладка /opt/vmsetup"
fi
log "teleport-agent: было ${previous:-?}, ставлю ${version:-?}; агент $agent не трогаю"

# 1. lib/ by fingerprint: an identical tree is already there and stays shared.
digest="$(lib_digest "$SRC/lib")"
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "отпечаток lib/ не посчитан"
LIB_DIR="$GUEST/lib/$digest"
NEW=""; OLD=""; LIB_NEW=""; SWAPPED=0; DONE=0; UNITS_BAK=""
# What install.sh rewires: the CLI and library links, the schema and hook
# links, the units (copies). Remembered before the swap, put back on failure:
# a half-run install.sh must not leave the CLI pointing into a removed
# directory — ExecStartPre of the agent runs it.
LINKS=("$ROOT/usr/local/sbin/bisquite-teleport" "$ROOT/usr/local/sbin/bisquite-conf"
       "$GUEST/knobs/teleport" "$GUEST/knobs/teleport.apply" "$GUEST/knobs/teleport.secret")
UNITS=(teleport.service bisquite-teleport-apps.path bisquite-teleport-apps.service
       bisquite-teleport-token.path bisquite-teleport-token.service
       bisquite-teleport-labels.service bisquite-teleport-labels.timer)
declare -A LINK_BEFORE=()
snapshot(){
    local l u
    for l in "${LINKS[@]}"; do
        if [[ -L "$l" ]]; then LINK_BEFORE[$l]="$(readlink "$l")"; else LINK_BEFORE[$l]=""; fi
    done
    UNITS_BAK="$(mktemp -d "$GUEST/.$NAME.units.XXXXXX")"
    for u in "${UNITS[@]}"; do
        [[ -f "$ROOT/etc/systemd/system/$u" ]] && cp -a -- "$ROOT/etc/systemd/system/$u" "$UNITS_BAK/$u"
    done
    return 0
}
restore_wiring(){
    local l u
    for l in "${LINKS[@]}"; do
        if [[ -n "${LINK_BEFORE[$l]}" ]]; then
            ln -sfn -- "${LINK_BEFORE[$l]}" "$l"
        elif [[ -L "$l" ]]; then
            rm -f -- "$l"
        fi
    done
    for u in "${UNITS[@]}"; do
        if [[ -f "$UNITS_BAK/$u" ]]; then
            cp -a -- "$UNITS_BAK/$u" "$ROOT/etc/systemd/system/$u"
        else
            rm -f -- "$ROOT/etc/systemd/system/$u"
        fi
    done
    log "ссылки CLI и схемы и юниты возвращены к прежним"
}
# On any failure after the swap the previous directory comes back: a robot
# is never left with half an update. Without a previous one (the /opt/vmsetup
# layout) the new directory goes away again.
cleanup(){
    if (( SWAPPED && ! DONE )); then
        rm -r -f -- "$TARGET"
        if [[ -n "$OLD" && -e "$OLD" ]]; then
            mv -T -- "$OLD" "$TARGET" && log "прежний каталог $TARGET возвращён"
        fi
        OLD=""
        [[ -n "$UNITS_BAK" ]] && restore_wiring
    fi
    rm -r -f -- ${NEW:+"$NEW"} ${OLD:+"$OLD"} ${LIB_NEW:+"$LIB_NEW"} ${UNITS_BAK:+"$UNITS_BAK"}
}
trap cleanup EXIT
install -d -m 0755 "$GUEST" "$GUEST/lib"
if [[ ! -d "$LIB_DIR" ]]; then
    LIB_NEW="$(mktemp -d "$GUEST/lib/.new.XXXXXX")"
    cp -a -- "$SRC/lib/." "$LIB_NEW/"
    # As the build does: +x to every file of lib/.
    find "$LIB_NEW" -type f -exec chmod 0755 {} +
    # git archive carries its umask (0664/0775): nobody but root writes code.
    chmod -R go-w "$LIB_NEW"
    chmod 0755 "$LIB_NEW"
    [[ -n "$ROOT" ]] || chown -R 0:0 "$LIB_NEW"
    mv -T -- "$LIB_NEW" "$LIB_DIR"
    LIB_NEW=""
fi

# 2. The extension directory, swapped whole: no file of the previous version
#    stays behind. The CLI link points into this path, so it keeps working.
NEW="$(mktemp -d "$GUEST/.$NAME.new.XXXXXX")"
cp -a -- "$SCRIPT_DIR/." "$NEW/"
rm -f -- "$NEW/lib"
chmod -R go-w "$NEW"
chmod 0755 "$NEW" "$NEW"/*.sh "$NEW/bisquite-teleport" "$NEW/knobs.apply"
[[ -n "$ROOT" ]] || chown -R 0:0 "$NEW"
ln -sfn -- "$LIB_DIR" "$NEW/lib"
snapshot
if [[ -e "$TARGET" || -L "$TARGET" ]]; then
    OLD="$GUEST/.$NAME.old.$$"
    rm -r -f -- "$OLD"
    mv -T -- "$TARGET" "$OLD"
fi
mv -T -- "$NEW" "$TARGET"
NEW=""; SWAPPED=1

# 3. install.sh of the new version: links, units, settings registration.
TELEPORT_VERSION="$agent" BISQUITE_TELEPORT_UPDATE=1 bash "$TARGET/install.sh" \
    || die "install.sh не прошёл — прежний каталог расширения возвращается"
DONE=1
if [[ -d "$LEGACY" ]]; then
    log "прежняя раскладка $LEGACY оставлена на диске; CLI и схема — теперь из $TARGET"
fi

# 4. systemd picks up the units. The timer is enabled here only for a robot
#    that already has a labels token; otherwise labels-enable enables it.
if has_systemd; then
    systemctl daemon-reload
    if [[ -f "$ROOT/etc/bisquite/teleport/labels-token" ]]; then
        systemctl enable --now "$TIMER" >/dev/null 2>&1 || die "$TIMER не включён"
    fi
fi
log "готово: teleport-agent ${version:-?}. Автоприменение меток — printf '%s' <токен> | bisquite-teleport labels-enable URL=https://<портал>/robot-api/v1/labels"
