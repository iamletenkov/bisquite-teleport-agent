#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2119,SC2120  # literal $… in fakes; postinst [<version>] is called through check
# Тесты пакета: сборка .deb (состав, права, воспроизводимость) и сценарии
# сопровождающих скриптов на подменённом корне (BISQUITE_TELEPORT_ROOT):
# чистая установка, переход с расширения teleport-agent 2.x, повтор,
# prerm/postrm. Пакет распаковывается dpkg-deb -x, скрипты — из его DEBIAN.
# root, systemd и сеть не нужны; нужен dpkg-deb.
#
#   tests/test-package.sh        код 0 — все проверки прошли

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
exec 3>&2
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&3; }
check(){ local what="$1"; shift; if "$@"; then ok; else bad "$what"; fi; }
check_not(){ local what="$1"; shift; if "$@"; then bad "$what"; else ok; fi; }
eq(){ local what="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then ok; else bad "$what: ждали [$want], получили [$got]"; fi; }

command -v dpkg-deb >/dev/null || { echo "нет dpkg-deb — пропущено" >&3; exit 0; }

UNITS=(teleport.service bisquite-teleport-apps.path bisquite-teleport-apps.service
       bisquite-teleport-token.path bisquite-teleport-token.service
       bisquite-teleport-labels.service bisquite-teleport-labels.timer)
VERSION="$(tr -d '[:space:]' < "$REPO/VERSION")"

# ===========================================================================
echo "== сборка .deb =="
export SOURCE_DATE_EPOCH=1700000000
check "сборка" bash "$REPO/tools/build-deb.sh" --out "$TMP/d1" >/dev/null
check "повторная сборка" bash "$REPO/tools/build-deb.sh" --out "$TMP/d2" >/dev/null
DEB="$TMP/d1/bisquite-teleport-agent_${VERSION}_all.deb"
check "файл .deb" test -f "$DEB"
eq "воспроизводимо: та же сумма" "$(sha256sum < "$DEB")" "$(sha256sum < "$TMP/d2/$(basename "$DEB")")"
check "SHA256SUMS сходится" bash -c 'cd "$1" && sha256sum -c --quiet SHA256SUMS' _ "$TMP/d1"
unset SOURCE_DATE_EPOCH
eq "Package" bisquite-teleport-agent "$(dpkg-deb -f "$DEB" Package)"
eq "Version" "$VERSION" "$(dpkg-deb -f "$DEB" Version)"
eq "Architecture" all "$(dpkg-deb -f "$DEB" Architecture)"
check "Teleport не в Depends" bash -c '! dpkg-deb -f "$1" Depends | grep -qi teleport' _ "$DEB"
contents="$(dpkg-deb --contents "$DEB")"
for f in usr/lib/bisquite-teleport/bisquite-teleport usr/lib/bisquite-teleport/knobs \
         usr/lib/bisquite-teleport/knobs.apply usr/lib/bisquite-teleport/lib/bisquite-conf \
         usr/lib/bisquite-teleport/pkg-setup usr/lib/bisquite-teleport/VERSION \
         usr/share/doc/bisquite-teleport-agent/copyright; do
    check "в пакете $f" grep -q " \./$f\$" <<< "$contents"
done
for u in "${UNITS[@]}"; do
    check "в пакете юнит $u" grep -q " \./usr/lib/systemd/system/$u\$" <<< "$contents"
done
check "/usr/sbin/bisquite-teleport — ссылка" grep -q '\./usr/sbin/bisquite-teleport -> ../lib/bisquite-teleport/bisquite-teleport$' <<< "$contents"
check_not "бинаря teleport в пакете нет" grep -qE '/bin/teleport$' <<< "$contents"
check_not "ничего в /etc, /opt, /var, /usr/local" grep -qE ' \./(etc|opt|var|usr/local)/' <<< "$contents"
check "владелец всего — root/root" bash -c '! grep -v " root/root " <<< "$1" | grep -q .' _ "$contents"
check "CLI исполняемый" grep -qE '^-rwxr-xr-x .* \./usr/lib/bisquite-teleport/bisquite-teleport$' <<< "$contents"
check_not "юниты зовут /usr/local/sbin" bash -c 'grep -l /usr/local/sbin "$1"/src/systemd/*' _ "$REPO"

# ===========================================================================
# Scratch root with the package unpacked, scripts in $ROOT/DEBIAN.
FAKE=""
new_root(){
    ROOT="$(mktemp -d "$TMP/root.XXXXXX")"
    FAKE="$ROOT/fake"
    mkdir -p "$ROOT/bin" "$FAKE"
    export BISQUITE_TELEPORT_ROOT="$ROOT" BISQUITE_CONF_ROOT="$ROOT" BISQUITE_TELEPORT_SYSTEMD=0 FAKE
    export PATH="$ROOT/bin:$BASE_PATH"
    cat > "$ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/systemctl.log"
exit 0
EOF
    chmod +x "$ROOT/bin/systemctl"
}
BASE_PATH="$PATH"
unpack(){ dpkg-deb -x "$DEB" "$ROOT" && dpkg-deb -e "$DEB" "$ROOT/DEBIAN"; }
postinst(){ sh "$ROOT/DEBIAN/postinst" configure "${1:-}"; }
wants(){ readlink "$ROOT/etc/systemd/system/$1/$2"; }
cfg(){ cat "$ROOT/etc/bisquite/teleport/config"; }
lib(){ bash -c 'set -euo pipefail; source "$1"; shift; "$@"' _ "$ROOT/usr/lib/bisquite-teleport/lib/bisquite-conf" "$@"; }

# ===========================================================================
echo "== чистая установка =="
new_root; unpack
out="$(postinst 2>&1)"; rc=$?
eq "postinst configure — код 0" 0 "$rc"
check "config создан" test -f "$ROOT/etc/bisquite/teleport/config"
eq "config 0600 (в схеме секрет)" 600 "$(stat -c %a "$ROOT/etc/bisquite/teleport/config")"
eq "метод по умолчанию — token" token "$(lib conf_get teleport TELEPORT_JOIN_METHOD)"
eq "схема — из пакета" "$ROOT/usr/lib/bisquite-teleport/knobs" "$(readlink "$ROOT/opt/bisquite/knobs/teleport")"
eq "хук — из пакета" "$ROOT/usr/lib/bisquite-teleport/knobs.apply" "$(readlink "$ROOT/opt/bisquite/knobs/teleport.apply")"
eq "bisquite-conf — из пакета" "$ROOT/usr/lib/bisquite-teleport/lib/bisquite-conf" "$(readlink "$ROOT/usr/local/sbin/bisquite-conf")"
check "apps.d" test -d "$ROOT/etc/bisquite/teleport/apps.d"
eq "/var/lib/teleport 0750" 750 "$(stat -c %a "$ROOT/var/lib/teleport")"
for u in bisquite-teleport-apps.path bisquite-teleport-token.path; do
    eq "$u включён" "/usr/lib/systemd/system/$u" "$(wants paths.target.wants "$u")"
done
check_not "teleport.service не включён" test -e "$ROOT/etc/systemd/system/multi-user.target.wants/teleport.service"
check_not "таймер меток не включён" test -L "$ROOT/etc/systemd/system/timers.target.wants/bisquite-teleport-labels.timer"
check_not "ссылки /usr/local/sbin/bisquite-teleport нет" test -L "$ROOT/usr/local/sbin/bisquite-teleport"
check_not "teleport.yaml не создан" test -e "$ROOT/etc/teleport.yaml"
check "подсказка про join" grep -q 'bisquite-teleport join' <<< "$out"
check_not "без systemd systemctl не зовётся" test -e "$FAKE/systemctl.log"
eq "CLI из пакета: version" "$VERSION" "$(bash "$ROOT/usr/sbin/bisquite-teleport" version 2>/dev/null || bash "$ROOT/usr/lib/bisquite-teleport/bisquite-teleport" version)"
check "CLI из пакета: status" bash "$ROOT/usr/lib/bisquite-teleport/bisquite-teleport" status >/dev/null 2>&1
before="$(cfg)"
check "повтор postinst (обновление 3.0.0 → 3.0.0)" postinst "$VERSION" 2>/dev/null
eq "повтор: config не тронут" "$before" "$(cfg)"

# A config without a key the schema now has: postinst adds nothing to it.
new_root; unpack
mkdir -p "$ROOT/etc/bisquite/teleport"
printf 'TELEPORT_PROXY=teleport.example.org\n' > "$ROOT/etc/bisquite/teleport/config"
chmod 0600 "$ROOT/etc/bisquite/teleport/config"
postinst 2>/dev/null
eq "существующий config — ни байта не дописано" "TELEPORT_PROXY=teleport.example.org" "$(cfg)"

# ===========================================================================
echo "== переход с teleport-agent 2.x =="
# A robot of the bisquite image: extension in /opt/bisquite/teleport-agent,
# unit copies in /etc/systemd/system, agent joined and enabled, labels on.
old_robot(){
    new_root
    local ext="$ROOT/opt/bisquite/teleport-agent" lib="$ROOT/opt/bisquite/lib/0123abcd" u
    mkdir -p "$ext" "$lib" "$ROOT/usr/local/sbin" "$ROOT/opt/bisquite/knobs" "$ROOT/etc/systemd/system"
    printf '#!/bin/sh\necho old-cli\n' > "$ext/bisquite-teleport"
    printf '#!/bin/sh\n' > "$ext/knobs.apply"; cp "$REPO/src/knobs" "$ext/knobs"
    cp "$REPO/lib/bisquite-conf" "$lib/bisquite-conf"
    ln -s "$lib" "$ext/lib"
    ln -s "$ext/bisquite-teleport" "$ROOT/usr/local/sbin/bisquite-teleport"
    ln -s "$lib/bisquite-conf" "$ROOT/usr/local/sbin/bisquite-conf"
    ln -s "$ext/knobs" "$ROOT/opt/bisquite/knobs/teleport"
    ln -s "$ext/knobs.apply" "$ROOT/opt/bisquite/knobs/teleport.apply"
    ln -s "$ext/knobs.secret" "$ROOT/opt/bisquite/knobs/teleport.secret"
    # Units exactly as 2.5.0 installed them: /usr/local/sbin in ExecStart.
    for u in "${UNITS[@]}"; do
        sed 's|/usr/sbin/bisquite-teleport|/usr/local/sbin/bisquite-teleport|g' "$REPO/src/systemd/$u" > "$ROOT/etc/systemd/system/$u"
    done
    mkdir -p "$TMP/old-units"; cp "$ROOT"/etc/systemd/system/*.* "$TMP/old-units/"
    mkdir -p "$ROOT/etc/systemd/system/"{paths,multi-user,timers}.target.wants
    ln -s /etc/systemd/system/bisquite-teleport-apps.path "$ROOT/etc/systemd/system/paths.target.wants/"
    ln -s /etc/systemd/system/bisquite-teleport-token.path "$ROOT/etc/systemd/system/paths.target.wants/"
    ln -s /etc/systemd/system/teleport.service "$ROOT/etc/systemd/system/multi-user.target.wants/"
    ln -s /etc/systemd/system/bisquite-teleport-labels.timer "$ROOT/etc/systemd/system/timers.target.wants/"
    mkdir -p "$ROOT/etc/bisquite/teleport/apps.d" "$ROOT/var/lib/teleport/proc" "$ROOT/var/lib/bisquite/teleport"
    printf 'TELEPORT_PROXY="teleport.example.org"\nTELEPORT_ENV="dev"\nTELEPORT_LABELS="site=lab,space=sp-aaaaaaaa"\n' \
        > "$ROOT/etc/bisquite/teleport/config"
    chmod 0600 "$ROOT/etc/bisquite/teleport/config"
    printf 'NAME=code-server\nURI=https://127.0.0.1:9002\n' > "$ROOT/etc/bisquite/teleport/apps.d/code-server.conf"
    printf 'url=https://portal.example.org/robot-api/v1/labels\ntoken=x\n' > "$ROOT/etc/bisquite/teleport/labels-token"
    chmod 0600 "$ROOT/etc/bisquite/teleport/labels-token"
    echo 11111111-2222 > "$ROOT/var/lib/teleport/host_uuid"
    echo keypair > "$ROOT/var/lib/teleport/proc/sqlite.db"
    chmod 0700 "$ROOT/var/lib/teleport"
    printf 'version: v3\n# rendered by 2.5.0\n' > "$ROOT/etc/teleport.yaml"
    printf 'revision=0123456789abcdef\nenv=dev\nspace=sp-aaaaaaaa\n' > "$ROOT/var/lib/bisquite/teleport/labels-expected"
}
snapshot(){
    (cd "$ROOT" && find etc/bisquite var/lib/teleport var/lib/bisquite/teleport etc/teleport.yaml \
        ! -path 'var/lib/bisquite/teleport/2.x-units*' -printf '%p %m %s\n' | sort
     cd "$ROOT" && find etc/bisquite var/lib/teleport etc/teleport.yaml var/lib/bisquite/teleport \
        ! -path 'var/lib/bisquite/teleport/2.x-units*' -type f -exec sha256sum {} + | sort)
}

old_robot
before="$(snapshot)"
unpack
export BISQUITE_TELEPORT_SYSTEMD=1
out="$(postinst 2>&1)"; rc=$?
export BISQUITE_TELEPORT_SYSTEMD=0
eq "2.x: postinst — код 0" 0 "$rc"
eq "2.x: config, apps.d, токен меток, регистрация, teleport.yaml, состояние — ни байта" "$before" "$(snapshot)"
for u in "${UNITS[@]}"; do
    check_not "2.x: копии $u в /etc/systemd/system нет" test -e "$ROOT/etc/systemd/system/$u"
    check "2.x: копия $u сохранена в 2.x-units" cmp -s "$TMP/old-units/$u" "$ROOT/var/lib/bisquite/teleport/2.x-units/$u"
done
eq "2.x: teleport.service включён — юнит пакета" /usr/lib/systemd/system/teleport.service "$(wants multi-user.target.wants teleport.service)"
eq "2.x: apps.path включён — юнит пакета" /usr/lib/systemd/system/bisquite-teleport-apps.path "$(wants paths.target.wants bisquite-teleport-apps.path)"
eq "2.x: token.path включён — юнит пакета" /usr/lib/systemd/system/bisquite-teleport-token.path "$(wants paths.target.wants bisquite-teleport-token.path)"
eq "2.x: таймер меток включён — юнит пакета" /usr/lib/systemd/system/bisquite-teleport-labels.timer "$(wants timers.target.wants bisquite-teleport-labels.timer)"
eq "2.x: /usr/local/sbin/bisquite-teleport → /usr/sbin" /usr/sbin/bisquite-teleport "$(readlink "$ROOT/usr/local/sbin/bisquite-teleport")"
eq "2.x: bisquite-conf образа не тронут" "$ROOT/opt/bisquite/lib/0123abcd/bisquite-conf" "$(readlink "$ROOT/usr/local/sbin/bisquite-conf")"
eq "2.x: схема — из пакета" "$ROOT/usr/lib/bisquite-teleport/knobs" "$(readlink "$ROOT/opt/bisquite/knobs/teleport")"
eq "2.x: хук — из пакета" "$ROOT/usr/lib/bisquite-teleport/knobs.apply" "$(readlink "$ROOT/opt/bisquite/knobs/teleport.apply")"
check_not "2.x: хука .secret нет" test -L "$ROOT/opt/bisquite/knobs/teleport.secret"
check "2.x: каталог расширения на месте" test -f "$ROOT/opt/bisquite/teleport-agent/bisquite-teleport"
check "2.x: daemon-reload" grep -qx daemon-reload "$FAKE/systemctl.log"
check "2.x: path-юниты запущены" grep -qx 'start bisquite-teleport-apps.path bisquite-teleport-token.path' "$FAKE/systemctl.log"
check "2.x: таймер меток запущен" grep -qx 'start bisquite-teleport-labels.timer' "$FAKE/systemctl.log"
check_not "2.x: агент не перезапускался" grep -qE 'teleport\.service' "$FAKE/systemctl.log"
check "2.x: сказано про регистрацию" grep -q 'регистрация в /var/lib/teleport сохранена' <<< "$out"
check "2.x: CLI пакета читает конфиг 2.x" bash -c 'bash "$1" status 2>/dev/null | grep -q "teleport.example.org"' _ "$ROOT/usr/lib/bisquite-teleport/bisquite-teleport"

before="$(snapshot)"; links="$(find "$ROOT/etc/systemd/system" -type l -printf '%p %l\n' | sort)"
check "2.x: повтор postinst" postinst "$VERSION" 2>/dev/null
eq "2.x: повтор — состояние то же" "$before" "$(snapshot)"
eq "2.x: повтор — ссылки юнитов те же" "$links" "$(find "$ROOT/etc/systemd/system" -type l -printf '%p %l\n' | sort)"

# A teleport.service written by someone else (a portal's install script):
# not ours to move, but it shadows the package's unit — say so.
old_robot
printf '[Service]\nExecStart=/usr/local/bin/teleport start --config /etc/teleport.yaml\n' > "$ROOT/etc/systemd/system/teleport.service"
unpack
out="$(postinst 2>&1)"
check "чужой teleport.service остался" grep -q 'ExecStart=/usr/local/bin/teleport start' "$ROOT/etc/systemd/system/teleport.service"
check "чужой teleport.service — предупреждение" grep -q 'не юнит bisquite-teleport' <<< "$out"
eq "чужой teleport.service — ссылка включения не тронута" /etc/systemd/system/teleport.service "$(wants multi-user.target.wants teleport.service)"
check_not "чужой teleport.service — не в 2.x-units" test -e "$ROOT/var/lib/bisquite/teleport/2.x-units/teleport.service"

# A dangling bisquite-conf link (its lib/ is gone) points at the package's copy.
old_robot
rm -r -- "$ROOT/opt/bisquite/lib/0123abcd"
unpack; postinst 2>/dev/null
eq "битая ссылка bisquite-conf — на копию пакета" "$ROOT/usr/lib/bisquite-teleport/lib/bisquite-conf" "$(readlink "$ROOT/usr/local/sbin/bisquite-conf")"

# ===========================================================================
echo "== prerm / postrm =="
old_robot; unpack; postinst 2>/dev/null
before="$(snapshot)"
rm -f "$FAKE/systemctl.log"
out="$(BISQUITE_TELEPORT_SYSTEMD=1 sh "$ROOT/DEBIAN/prerm" remove 2>&1)"; rc=$?
eq "prerm remove — код 0" 0 "$rc"
check "prerm: таймер и path-юниты остановлены" grep -qx 'stop bisquite-teleport-labels.timer bisquite-teleport-apps.path bisquite-teleport-token.path' "$FAKE/systemctl.log"
check_not "prerm: агент не остановлен" grep -q 'teleport\.service' "$FAKE/systemctl.log"
check "prerm: сказано про leave" grep -q 'bisquite-teleport leave' <<< "$out"
check "prerm upgrade — код 0, ничего" sh "$ROOT/DEBIAN/prerm" upgrade "$VERSION"
# dpkg removes the package files, then runs postrm.
while IFS= read -r f; do rm -f -- "$ROOT/$f"; done < <(dpkg-deb --fsys-tarfile "$DEB" | tar -t | grep -v '/$')
cp "$ROOT/DEBIAN/postrm" "$TMP/postrm"
check "postrm remove — код 0" sh "$TMP/postrm" remove
check_not "postrm: ссылка /usr/local/sbin/bisquite-teleport снята" test -L "$ROOT/usr/local/sbin/bisquite-teleport"
check_not "postrm: схема снята" test -L "$ROOT/opt/bisquite/knobs/teleport"
check_not "postrm: хук снят" test -L "$ROOT/opt/bisquite/knobs/teleport.apply"
eq "postrm: bisquite-conf образа на месте" "$ROOT/opt/bisquite/lib/0123abcd/bisquite-conf" "$(readlink "$ROOT/usr/local/sbin/bisquite-conf")"
check "postrm remove: ссылки включения остаются до purge" test -L "$ROOT/etc/systemd/system/multi-user.target.wants/teleport.service"
eq "postrm remove: регистрация и настройки — ни байта" "$before" "$(snapshot)"
out="$(sh "$TMP/postrm" purge 2>&1)"; rc=$?
eq "postrm purge — код 0" 0 "$rc"
for w in multi-user.target.wants/teleport.service paths.target.wants/bisquite-teleport-apps.path \
         paths.target.wants/bisquite-teleport-token.path timers.target.wants/bisquite-teleport-labels.timer; do
    check_not "purge: ссылка $w снята" test -L "$ROOT/etc/systemd/system/$w"
done
eq "purge: регистрация и настройки — ни байта" "$before" "$(snapshot)"
check "purge: сказано, что регистрация сохранена" grep -q 'регистрация сохранена' <<< "$out"

# A fresh install, purged: links of the package go, foreign links stay.
new_root; unpack; postinst 2>/dev/null
ln -s /lib/systemd/system/other.service "$ROOT/etc/systemd/system/paths.target.wants/other.service"
while IFS= read -r f; do rm -f -- "$ROOT/$f"; done < <(dpkg-deb --fsys-tarfile "$DEB" | tar -t | grep -v '/$')
sh "$TMP/postrm" purge 2>/dev/null
check_not "purge: path-юнит пакета снят" test -L "$ROOT/etc/systemd/system/paths.target.wants/bisquite-teleport-apps.path"
check_not "purge: bisquite-conf пакета снят" test -L "$ROOT/usr/local/sbin/bisquite-conf"
check "purge: чужая ссылка осталась" test -L "$ROOT/etc/systemd/system/paths.target.wants/other.service"
check "purge: config остался" test -f "$ROOT/etc/bisquite/teleport/config"

echo
echo "проверок: $((pass + fail)), не прошло: $fail"
(( fail == 0 ))
