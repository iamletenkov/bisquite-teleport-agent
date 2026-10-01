#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes and patterns is the test data
# Тесты меток с портала расширения teleport-agent: set-managed, pull,
# labels-enable, юниты таймера и update.sh — на подменённом корне
# (BISQUITE_TELEPORT_ROOT), с поддельными curl, systemctl, dpkg и teleport в
# PATH. root, systemd и сеть не нужны.
#
#   tools/test-teleport-labels.sh        код 0 — все проверки прошли

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
EXT="$REPO/extensions/debian/teleport-agent"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
# fd 3: the real stderr — a check called with 2>/dev/null must still report.
exec 3>&2
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&3; }
check(){ local what="$1"; shift; if "$@"; then ok; else bad "$what"; fi; }
check_not(){ local what="$1"; shift; if "$@"; then bad "$what"; else ok; fi; }
eq(){ local what="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then ok; else bad "$what: ждали [$want], получили [$got]"; fi; }

TOKEN=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde
URL=https://stvor.example.org/robot-api/v1/labels
REV_B=0123456789abcdef
REV_C=fedcba9876543210

# ---------------------------------------------------------------------------
# Scratch root and fakes
# ---------------------------------------------------------------------------
# FAKE: where the fakes keep their logs and switches.
#   systemctl.log     every systemctl call, one per line
#   active            exists — teleport.service is active
#   start-fails       exists — `restart teleport.service` fails
#   portal.code       HTTP code of the next answers (200, 304, 401, …; down — no network)
#   portal.body       body of the answer
#   curl.argv         argv of every curl call
#   curl.req          URL and headers (from -H @file) of every call
new_root(){
    ROOT="$(mktemp -d "$TMP/root.XXXXXX")"
    FAKE="$ROOT/fake"
    mkdir -p "$ROOT/bin" "$FAKE"
    export BISQUITE_TELEPORT_ROOT="$ROOT" BISQUITE_CONF_ROOT="$ROOT" FAKE
    export BISQUITE_TELEPORT_SYSTEMD=1 BISQUITE_TELEPORT_RESTART_TIMEOUT=2
    export PATH="$ROOT/bin:$BASE_PATH"
    fake_systemctl; fake_curl; fake_dpkg
}
BASE_PATH="$PATH"

# A restart of teleport.service renders teleport.yaml the way ExecStartPre
# does, so a config that does not render never becomes active.
fake_systemctl(){
    cat > "$ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/systemctl.log"
case "${1:-}" in
    is-active) [[ -f "$FAKE/active" ]]; exit ;;
    is-system-running) echo running; exit 0 ;;
    restart)
        if [[ "${2:-}" == teleport.service ]]; then
            rm -f "$FAKE/active"
            [[ -f "$FAKE/start-fails" ]] && exit 1
            "$FAKE_TP" render 2>/dev/null || exit 1
            touch "$FAKE/active"
        fi ;;
esac
exit 0
EOF
    chmod +x "$ROOT/bin/systemctl"
}

fake_curl(){
    cat > "$ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/curl.argv"
out=""; hdr=""; url=""
while (( $# )); do
    case "$1" in
        -H) hdr="$2"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        -w|--max-time|--connect-timeout|--max-filesize|--proto) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
{ echo "URL $url"; [[ "$hdr" == @* ]] && cat "${hdr#@}"; echo "--"; } >> "$FAKE/curl.req"
code="$(cat "$FAKE/portal.code" 2>/dev/null || echo 200)"
if [[ "$code" == down ]]; then printf 000; exit 7; fi
if [[ -n "$out" ]]; then
    : > "$out"
    [[ "$code" != 304 && -f "$FAKE/portal.body" ]] && cat "$FAKE/portal.body" > "$out"
fi
printf '%s' "$code"
EOF
    chmod +x "$ROOT/bin/curl"
}

fake_dpkg(){ printf '#!/bin/sh\necho amd64\n' > "$ROOT/bin/dpkg"; chmod +x "$ROOT/bin/dpkg"; }

# The agent binary where install.sh and update.sh look for it.
fake_teleport(){
    mkdir -p "$ROOT/usr/local/bin"
    printf '#!/bin/sh\necho "Teleport v%s git: go1.25"\n' "$1" > "$ROOT/usr/local/bin/teleport"
    chmod +x "$ROOT/usr/local/bin/teleport"
}

# The build layout: /opt/bisquite/teleport-agent with lib/ linked in.
stage(){
    mkdir -p "$ROOT/opt/bisquite"
    cp -a "$EXT" "$ROOT/opt/bisquite/teleport-agent"
    ln -sfn "$REPO/lib" "$ROOT/opt/bisquite/teleport-agent/lib"
    STAGED="$ROOT/opt/bisquite/teleport-agent"
    export FAKE_TP="$STAGED/bisquite-teleport"
}
lib(){ bash -c 'set -euo pipefail; source "$1"; shift; "$@"' _ "$REPO/lib/bisquite-conf" "$@"; }
tp(){ bash "$STAGED/bisquite-teleport" "$@"; }
get(){ lib conf_get teleport "$1"; }
syslog(){ grep -v '^is-active' "$FAKE/systemctl.log" 2>/dev/null; }
reset_logs(){ rm -f "$FAKE/systemctl.log" "$FAKE/curl.argv" "$FAKE/curl.req"; }
app_decl(){
    local n="$1" f; shift
    f="$ROOT/etc/bisquite/teleport/apps.d/$n.conf"
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "NAME=$n" "$@" > "$f"
    chmod 0644 "$f"
}
# A joined robot: cluster, node name, operator labels, two apps, agent active.
robot(){
    new_root; stage
    bash -c 'set -euo pipefail; source "$1/lib/bisquite-conf"; conf_init teleport "$1/knobs"' _ "$STAGED" \
        || bad "conf_init teleport"
    lib conf_set teleport --allow-ro TELEPORT_PROXY=teleport.example.org TELEPORT_NODENAME=robot-1 \
        TELEPORT_ENV=dev TELEPORT_LABELS=site=lab,space=sp-aaaaaaaa TELEPORT_APPS=grafana=3000
    app_decl code-server URI=https://127.0.0.1:9002
    # The apply hook must never run on these paths: a marker instead of it.
    printf '#!/bin/sh\ntouch "%s/hook-called"\n' "$FAKE" > "$ROOT/opt/bisquite/knobs/teleport.apply"
    chmod +x "$ROOT/opt/bisquite/knobs/teleport.apply"
    tp render 2>/dev/null || bad "render исходного конфига"
    touch "$FAKE/active"
    reset_logs
}
cfg_snapshot(){ cat "$ROOT/etc/bisquite/teleport/config"; }
portal(){ # portal <code> [env space revision]
    echo "$1" > "$FAKE/portal.code"
    if (( $# == 4 )); then
        printf '{"labels":{"env":"%s","space":"%s"},"revision":"%s"}' "$2" "$3" "$4" > "$FAKE/portal.body"
    fi
}
enable_labels(){ printf '%s' "$TOKEN" | tp labels-enable "URL=$URL" 2>/dev/null; }
yaml_spaces(){ grep -c '"space": "'"$1"'"' "$ROOT/etc/teleport.yaml"; }

# ===========================================================================
echo "== set-managed =="
robot
check "set-managed: слияние — код 0" tp set-managed env=prod space=sp-bbbbbbbb 2>/dev/null
eq "set-managed: метки оператора сохранены, space заменён" site=lab,space=sp-bbbbbbbb "$(get TELEPORT_LABELS)"
eq "set-managed: TELEPORT_ENV" prod "$(get TELEPORT_ENV)"
# node + grafana + code-server
eq "set-managed: space у узла и у каждого приложения" 3 "$(yaml_spaces sp-bbbbbbbb)"
eq "set-managed: старого space в teleport.yaml нет" 0 "$(yaml_spaces sp-aaaaaaaa)"
eq "set-managed: env у узла и приложений" 3 "$(grep -c '"env": "prod"' "$ROOT/etc/teleport.yaml")"
eq "set-managed: ровно один restart, без reload" "restart teleport.service" "$(syslog)"
check_not "set-managed: хук apply не вызывался" test -e "$FAKE/hook-called"

reset_logs
before="$(cfg_snapshot)"
check "set-managed: без изменений — код 0" tp set-managed env=prod space=sp-bbbbbbbb 2>/dev/null
eq "set-managed: без изменений — systemctl не вызывается" "" "$(cat "$FAKE/systemctl.log" 2>/dev/null)"
eq "set-managed: без изменений — config тот же" "$before" "$(cfg_snapshot)"

check "set-managed: только space" tp set-managed space=sp-cccccccc 2>/dev/null
eq "set-managed: только space — env прежний" prod "$(get TELEPORT_ENV)"
eq "set-managed: только space — метки" site=lab,space=sp-cccccccc "$(get TELEPORT_LABELS)"

robot
before="$(cfg_snapshot)"
check_not "set-managed: чужой ключ app — отказ" tp set-managed app=x 2>/dev/null
check_not "set-managed: чужой ключ вместе с допустимым — отказ" tp set-managed space=sp-bbbbbbbb site=x 2>/dev/null
check_not "set-managed: ключ ручки — отказ" tp set-managed TELEPORT_ENV=prod 2>/dev/null
check_not "set-managed: без аргументов — отказ" tp set-managed 2>/dev/null
check_not "set-managed: space=A\"b — отказ" tp set-managed 'space=A"b' 2>/dev/null
check_not "set-managed: пустой space — отказ" tp set-managed space= 2>/dev/null
check_not "set-managed: перевод строки в значении — отказ" tp set-managed $'space=sp-a\nenv=x' 2>/dev/null
check_not "set-managed: заглавные — отказ" tp set-managed env=Prod 2>/dev/null
check_not "set-managed: запятая — отказ" tp set-managed space=a,b=c 2>/dev/null
check_not "set-managed: ключ дважды — отказ" tp set-managed space=a space=b 2>/dev/null
eq "set-managed: после отказов config не тронут" "$before" "$(cfg_snapshot)"
eq "set-managed: после отказов systemctl не вызывался" "" "$(cat "$FAKE/systemctl.log" 2>/dev/null)"

robot
TELEPORT_LABELS_NOSPACE=site=lab
lib conf_set teleport TELEPORT_LABELS="$TELEPORT_LABELS_NOSPACE"
check "set-managed: space дописывается, если его не было" tp set-managed space=sp-bbbbbbbb 2>/dev/null
eq "set-managed: space в конце списка" site=lab,space=sp-bbbbbbbb "$(get TELEPORT_LABELS)"
lib conf_set teleport TELEPORT_LABELS=
reset_logs
check "set-managed: пустые метки оператора" tp set-managed space=sp-dddddddd 2>/dev/null
eq "set-managed: из пустого списка" space=sp-dddddddd "$(get TELEPORT_LABELS)"

robot
touch "$FAKE/start-fails"
msg="$(tp set-managed env=prod space=sp-bbbbbbbb 2>&1)"; rc=$?
eq "set-managed: агент не поднялся — код 1" 1 "$rc"
check "set-managed: агент не поднялся — текст" grep -q 'не поднялся' <<< "$msg"

robot
lib conf_set teleport --allow-ro TELEPORT_PROXY=
check "set-managed: кластер не задан — только запись" tp set-managed space=sp-bbbbbbbb 2>/dev/null
eq "set-managed: кластер не задан — systemctl не вызывается" "" "$(syslog)"
eq "set-managed: кластер не задан — записано" site=lab,space=sp-bbbbbbbb "$(get TELEPORT_LABELS)"

robot
check "set-managed: без systemd — только запись" env BISQUITE_TELEPORT_SYSTEMD=0 bash "$STAGED/bisquite-teleport" set-managed space=sp-bbbbbbbb 2>/dev/null
eq "set-managed: без systemd — systemctl не вызывается" "" "$(syslog)"

# ===========================================================================
echo "== labels-enable =="
robot
portal 200 prod sp-bbbbbbbb "$REV_B"
check_not "labels-enable: URL не по шаблону — отказ (http)" \
    bash -c 'printf %s "$1" | bash "$2" labels-enable URL=http://stvor.example.org/robot-api/v1/labels' _ "$TOKEN" "$STAGED/bisquite-teleport" 2>/dev/null
check_not "labels-enable: URL с чужим путём — отказ" \
    bash -c 'printf %s "$1" | bash "$2" labels-enable URL=https://stvor.example.org/api/v1/labels' _ "$TOKEN" "$STAGED/bisquite-teleport" 2>/dev/null
check_not "labels-enable: URL с кавычкой — отказ" \
    bash -c 'printf %s "$1" | bash "$2" labels-enable "URL=https://stvor\".example.org/robot-api/v1/labels"' _ "$TOKEN" "$STAGED/bisquite-teleport" 2>/dev/null
check_not "labels-enable: без URL — отказ" \
    bash -c 'printf %s "$1" | bash "$2" labels-enable' _ "$TOKEN" "$STAGED/bisquite-teleport" 2>/dev/null
check_not "labels-enable: токен не по шаблону — отказ" \
    bash -c 'printf %s "short" | bash "$1" labels-enable "URL=$2"' _ "$STAGED/bisquite-teleport" "$URL" 2>/dev/null
check_not "labels-enable: пустой stdin — отказ" \
    bash -c 'bash "$1" labels-enable "URL=$2" < /dev/null' _ "$STAGED/bisquite-teleport" "$URL" 2>/dev/null
check_not "labels-enable: после отказов файла токена нет" test -e "$ROOT/etc/bisquite/teleport/labels-token"
eq "labels-enable: после отказов systemctl не вызывался" "" "$(syslog)"
check_not "labels-enable: после отказов — нет запроса к порталу" test -e "$FAKE/curl.argv"

out="$(printf '%s\n' "$TOKEN" | tp labels-enable "URL=$URL" 2>&1)"; rc=$?
eq "labels-enable: код 0" 0 "$rc"
eq "labels-enable: файл токена 0600" 600 "$(stat -c %a "$ROOT/etc/bisquite/teleport/labels-token")"
eq "labels-enable: в файле токен без перевода строки вокруг" "$TOKEN" "$(cat "$ROOT/etc/bisquite/teleport/labels-token")"
eq "labels-enable: ручка TELEPORT_LABELS_URL" "$URL" "$(get TELEPORT_LABELS_URL)"
check "labels-enable: таймер enable --now" grep -qx 'enable --now bisquite-teleport-labels.timer' "$FAKE/systemctl.log"
check "labels-enable: один pull сразу — запрос к порталу" grep -q "^URL $URL\$" "$FAKE/curl.req"
eq "labels-enable: pull применил метки" site=lab,space=sp-bbbbbbbb "$(get TELEPORT_LABELS)"
check_not "labels-enable: токена нет в config" grep -qF "$TOKEN" "$ROOT/etc/bisquite/teleport/config"
check_not "labels-enable: токена нет в выводе" grep -qF "$TOKEN" <<< "$out"
check_not "labels-enable: токена нет в argv curl" grep -qF "$TOKEN" "$FAKE/curl.argv"
check "labels-enable: токен в заголовке запроса" grep -qxF "Authorization: Bearer $TOKEN" "$FAKE/curl.req"
status="$(tp status 2>&1)"
check_not "status: токена нет" grep -qF "$TOKEN" <<< "$status"
check "status: автоприменение включено" grep -q 'Метки с портала: включено' <<< "$status"
check "status: ожидаемые метки" grep -q "space=sp-bbbbbbbb" <<< "$status"
check_not "status: временных файлов запроса не осталось" \
    bash -c 'find "$1/var/lib/bisquite/teleport" -name ".pull.*" | grep -q .' _ "$ROOT"

# ===========================================================================
echo "== pull =="
robot
printf '%s' "$TOKEN" > "$ROOT/etc/bisquite/teleport/labels-token"; chmod 0600 "$ROOT/etc/bisquite/teleport/labels-token"
lib conf_set teleport "TELEPORT_LABELS_URL=$URL"
STATE="$ROOT/var/lib/bisquite/teleport"
portal 200 prod sp-bbbbbbbb "$REV_B"
check "pull: 200 — код 0" tp pull 2>/dev/null
eq "pull: 200 — метки применены" site=lab,space=sp-bbbbbbbb "$(get TELEPORT_LABELS)"
eq "pull: 200 — env применён" prod "$(get TELEPORT_ENV)"
eq "pull: 200 — space у узла и приложений" 3 "$(yaml_spaces sp-bbbbbbbb)"
eq "pull: 200 — один restart" "restart teleport.service" "$(syslog)"
eq "pull: labels-expected" $'revision='"$REV_B"$'\nenv=prod\nspace=sp-bbbbbbbb' "$(cat "$STATE/labels-expected")"
eq "pull: labels-applied" "$REV_B" "$(cat "$STATE/labels-applied")"
check_not "pull: первый запрос без If-None-Match" grep -q '^If-None-Match' "$FAKE/curl.req"
check_not "pull: первый запрос без X-Applied-Revision" grep -q '^X-Applied-Revision' "$FAKE/curl.req"
check "pull: curl только https" grep -q -- '--proto =https' "$FAKE/curl.argv"

reset_logs; portal 304
check "pull: 304 — код 0" tp pull 2>/dev/null
check "pull: следующий запрос несёт If-None-Match" grep -qx "If-None-Match: \"$REV_B\"" "$FAKE/curl.req"
check "pull: следующий запрос несёт X-Applied-Revision" grep -qx "X-Applied-Revision: $REV_B" "$FAKE/curl.req"
eq "pull: 304 без расхождения — агент не перезапускается" "" "$(syslog)"

reset_logs; portal 200 prod sp-bbbbbbbb "$REV_B"
check "pull: тот же ответ 200 — код 0" tp pull 2>/dev/null
eq "pull: 200 без изменений — агент не перезапускается" "" "$(syslog)"

# R3: a hand edit is undone even when the portal answers 304.
lib conf_set teleport TELEPORT_LABELS=site=lab,space=sp-cccccccc
reset_logs; portal 304
check "pull: 304, конфиг разошёлся — код 0" tp pull 2>/dev/null
check_not "pull: расхождение — X-Applied-Revision не сообщается" grep -q '^X-Applied-Revision' "$FAKE/curl.req"
eq "pull: 304, конфиг разошёлся — снова применено" site=lab,space=sp-bbbbbbbb "$(get TELEPORT_LABELS)"
eq "pull: самовосстановление — один restart" "restart teleport.service" "$(syslog)"
lib conf_set teleport TELEPORT_ENV=dev
reset_logs
check "pull: ручной env — код 0" tp pull 2>/dev/null
eq "pull: ручной env исправлен" prod "$(get TELEPORT_ENV)"

# Network and HTTP errors: code 0, one line, nothing touched.
for code in 401 429 500 down; do
    reset_logs; portal "$code"
    echo '{"code":"robot_api.unauthorized","message":"Токен меток не принят"}' > "$FAKE/portal.body"
    lib conf_set teleport TELEPORT_LABELS=site=lab,space=sp-bbbbbbbb
    before="$(cfg_snapshot)"; exp_before="$(cat "$STATE/labels-expected")"
    err="$(tp pull 2>&1 >/dev/null)"; rc=$?
    eq "pull: $code — код 0" 0 "$rc"
    eq "pull: $code — одна строка в журнале" 1 "$(grep -c . <<< "$err")"
    check_not "pull: $code — токена нет в журнале" grep -qF "$TOKEN" <<< "$err"
    eq "pull: $code — config не тронут" "$before" "$(cfg_snapshot)"
    eq "pull: $code — labels-expected не тронут" "$exp_before" "$(cat "$STATE/labels-expected")"
    eq "pull: $code — агент не перезапускается" "" "$(syslog)"
done
check "pull: 401 — подсказка про токен" grep -q '401' <<< "$(portal 401; tp pull 2>&1)"

# Malformed answers: refused, nothing written.
bad_body(){
    reset_logs; echo 200 > "$FAKE/portal.code"; printf '%s' "$1" > "$FAKE/portal.body"
    before="$(cfg_snapshot)"; exp_before="$(cat "$STATE/labels-expected")"
    tp pull 2>/dev/null; rc=$?
    check "pull: $2 — отказ (код ≠ 0)" test "$rc" -ne 0
    eq "pull: $2 — config не тронут" "$before" "$(cfg_snapshot)"
    eq "pull: $2 — labels-expected не тронут" "$exp_before" "$(cat "$STATE/labels-expected")"
    eq "pull: $2 — агент не перезапускается" "" "$(syslog)"
}
bad_body 'not json' "битый JSON"
bad_body '' "пустое тело"
bad_body '{"labels":{"env":"prod","space":"sp-x","space":"sp-y"},"revision":"'"$REV_C"'"}' "два значения space"
bad_body '{"labels":{"env":"prod","space":"sp-x"},"revision":"'"$REV_C"'"}{"labels":{"env":"prod","space":"sp-y"},"revision":"'"$REV_C"'"}' "два объекта"
bad_body '{"labels":{"env":"prod","space":"Sp_X"},"revision":"'"$REV_C"'"}' "недопустимое значение space"
bad_body '{"labels":{"env":"pr od","space":"sp-x"},"revision":"'"$REV_C"'"}' "пробел в env"
bad_body '{"labels":{"env":"prod","space":"sp-x"},"revision":"xyz"}' "ревизия не 16 hex"
bad_body '{"labels":{"env":"prod"},"revision":"'"$REV_C"'"}' "нет space"
bad_body '{"labels":{"env":"prod","space":"sp-x","app":"y"},"revision":"'"$REV_C"'"}' "лишний ключ"

reset_logs
printf '{\n  "labels": {"env": "prod", "space": "sp-cccccccc"},\n  "revision": "%s"\n}\n' "$REV_C" > "$FAKE/portal.body"
echo 200 > "$FAKE/portal.code"
check "pull: JSON с пробелами между лексемами принимается" tp pull 2>/dev/null
eq "pull: JSON с пробелами — применено" site=lab,space=sp-cccccccc "$(get TELEPORT_LABELS)"

# The agent does not come up: the revision is not marked applied, the next
# tick tries again.
reset_logs; touch "$FAKE/start-fails"; portal 200 prod sp-bbbbbbbb "$REV_B"
tp pull 2>/dev/null; rc=$?
eq "pull: агент не поднялся — код 1" 1 "$rc"
eq "pull: агент не поднялся — ревизия не отмечена" "$REV_C" "$(cat "$STATE/labels-applied")"
eq "pull: агент не поднялся — ожидаемое записано" $'revision='"$REV_B"$'\nenv=prod\nspace=sp-bbbbbbbb' "$(cat "$STATE/labels-expected")"
reset_logs; portal 304
tp pull 2>/dev/null
check_not "pull: агент лежит — X-Applied-Revision не сообщается" grep -q '^X-Applied-Revision' "$FAKE/curl.req"
rm -f "$FAKE/start-fails"
reset_logs; portal 304
check "pull: следующий тик — код 0" tp pull 2>/dev/null
eq "pull: следующий тик — агент перезапущен" "restart teleport.service" "$(syslog)"
eq "pull: следующий тик — ревизия отмечена" "$REV_B" "$(cat "$STATE/labels-applied")"

# Not enabled: no token or no URL — nothing happens, code 0.
robot
lib conf_set teleport "TELEPORT_LABELS_URL=$URL"
check "pull: без токена — код 0" tp pull 2>/dev/null
check_not "pull: без токена — запроса нет" test -e "$FAKE/curl.argv"
robot
printf '%s' "$TOKEN" > "$ROOT/etc/bisquite/teleport/labels-token"; chmod 0600 "$ROOT/etc/bisquite/teleport/labels-token"
check "pull: без URL — код 0" tp pull 2>/dev/null
check_not "pull: без URL — запроса нет" test -e "$FAKE/curl.argv"
lib conf_set teleport "TELEPORT_LABELS_URL=$URL"
printf 'bad token\n' > "$ROOT/etc/bisquite/teleport/labels-token"
check_not "pull: испорченный файл токена — отказ" tp pull 2>/dev/null
check_not "pull: испорченный файл токена — запроса нет" test -e "$FAKE/curl.argv"
check_not "TELEPORT_LABELS_URL через set: чужой путь — отказ" \
    tp set TELEPORT_LABELS_URL=https://stvor.example.org/x 2>/dev/null

# ===========================================================================
echo "== join: набор ключей не изменился (R2) =="
new_root; stage
bash -c 'set -euo pipefail; source "$1/lib/bisquite-conf"; conf_init teleport "$1/knobs"' _ "$STAGED"
fake_teleport 18.10.0
portal down
check "join со старым набором ключей" env BISQUITE_TELEPORT_SYSTEMD=0 TELEPORT_BIN="$ROOT/usr/local/bin/teleport" \
    bash "$STAGED/bisquite-teleport" join TELEPORT_PROXY=teleport.example.org TELEPORT_TOKEN=abcdefgh1 \
    TELEPORT_NODENAME=robot-1 TELEPORT_ENV=dev TELEPORT_LABELS=site=lab,space=sp-aaaaaaaa 2>/dev/null
eq "join: метки записаны" site=lab,space=sp-aaaaaaaa "$(get TELEPORT_LABELS)"
check "join: teleport.yaml собран" grep -q '"space": "sp-aaaaaaaa"' "$ROOT/etc/teleport.yaml"
check_not "join: таймер меток не трогает" grep -qs labels "$FAKE/systemctl.log"

# ===========================================================================
echo "== install.sh: юниты меток в сборке =="
new_root; stage; fake_teleport 18.10.0
export BISQUITE_TELEPORT_SYSTEMD=0
check "install.sh в staged-раскладке" bash "$STAGED/install.sh" 2>/dev/null
for u in bisquite-teleport-labels.service bisquite-teleport-labels.timer; do
    check "install.sh: $u в /etc/systemd/system" cmp -s "$STAGED/$u" "$ROOT/etc/systemd/system/$u"
done
check_not "install.sh: таймер не включён при сборке" test -e "$ROOT/etc/systemd/system/timers.target.wants/bisquite-teleport-labels.timer"
check_not "install.sh: systemctl не зовётся" test -e "$FAKE/systemctl.log"
check_not "install.sh: агент не скачивается, если версия та же" test -e "$FAKE/curl.argv"
eq "install.sh: CLI — ссылка в каталог расширения" "$STAGED/bisquite-teleport" "$(readlink "$ROOT/usr/local/sbin/bisquite-teleport")"
export BISQUITE_TELEPORT_SYSTEMD=1

# Units: what the timer runs and when.
svc="$EXT/bisquite-teleport-labels.service"; tmr="$EXT/bisquite-teleport-labels.timer"
check "юнит: oneshot" grep -qx 'Type=oneshot' "$svc"
check "юнит: только при токене" grep -qx 'ConditionPathExists=/etc/bisquite/teleport/labels-token' "$svc"
check "юнит: ExecStart — pull" grep -qx 'ExecStart=/usr/local/sbin/bisquite-teleport pull' "$svc"
check "таймер: OnBootSec=1min" grep -qx 'OnBootSec=1min' "$tmr"
check "таймер: OnUnitActiveSec=1min" grep -qx 'OnUnitActiveSec=1min' "$tmr"
check "таймер: RandomizedDelaySec=20s" grep -qx 'RandomizedDelaySec=20s' "$tmr"
check "таймер: WantedBy=timers.target" grep -qx 'WantedBy=timers.target' "$tmr"

# ===========================================================================
echo "== update.sh: архив git archive на работающем роботе =="
# The archive exactly as the portal mirror makes it: `git archive <ref>
# extensions/debian/teleport-agent lib | gzip -n`, here of the working tree
# (a scratch index, so uncommitted files are in it too).
make_archive(){
    local idx="$TMP/index" tree
    rm -f "$idx"
    GIT_INDEX_FILE="$idx" git -C "$REPO" read-tree HEAD || return 1
    GIT_INDEX_FILE="$idx" git -C "$REPO" add -- extensions/debian/teleport-agent lib || return 1
    tree="$(GIT_INDEX_FILE="$idx" git -C "$REPO" write-tree)" || return 1
    git -C "$REPO" archive "$tree" extensions/debian/teleport-agent lib | gzip -n > "$TMP/agent.tar.gz"
}
# The build's fingerprint of lib/ (bisquite: LinuxBuilder._library_digest).
py_digest(){
    python3 - "$1" <<'EOF'
import hashlib, sys
from pathlib import Path
lib = Path(sys.argv[1]); d = hashlib.sha256()
for item in sorted(lib.rglob("*")):
    rel = item.relative_to(lib).as_posix()
    if item.is_symlink(): d.update(f"L {rel} -> {item.readlink()}\0".encode())
    elif item.is_file(): d.update(f"F {rel}\0".encode()); d.update(item.read_bytes()); d.update(b"\0")
    elif item.is_dir(): d.update(f"D {rel}\0".encode())
print(d.hexdigest())
EOF
}
# A robot running an earlier build: agent 18.6.8 (older than the default of
# install.sh — a wrong version would make install.sh download), joined, with
# a config of its own.
old_robot(){ # old_robot <extension root: /opt/bisquite or /opt/vmsetup>
    new_root; fake_teleport 18.6.8
    local dir="$ROOT$1/teleport-agent"
    mkdir -p "$dir" "$ROOT/usr/local/sbin" "$ROOT/var/lib/teleport" "$ROOT/etc/bisquite/teleport"
    printf 'name: teleport-agent\nversion: 2.4.0\n' > "$dir/extension.yaml"
    printf '#!/bin/sh\necho old\n' > "$dir/bisquite-teleport"; chmod +x "$dir/bisquite-teleport"
    echo stale > "$dir/obsolete-file"
    ln -sfn "$dir/bisquite-teleport" "$ROOT/usr/local/sbin/bisquite-teleport"
    echo 11111111-2222 > "$ROOT/var/lib/teleport/host_uuid"
    printf 'TELEPORT_PROXY=teleport.example.org\nTELEPORT_ENV=dev\nTELEPORT_LABELS=site=lab\n' \
        > "$ROOT/etc/bisquite/teleport/config"
    chmod 0600 "$ROOT/etc/bisquite/teleport/config"
    rm -r -f "$TMP/unpacked"; mkdir -p "$TMP/unpacked"
    # -p: as root on the robot, tar keeps the archive modes (0664/0775).
    tar -xpzf "$TMP/agent.tar.gz" -C "$TMP/unpacked"
    UPD="$TMP/unpacked/extensions/debian/teleport-agent/update.sh"
}
updated_ok(){ # updated_ok <label>
    local t="$ROOT/opt/bisquite/teleport-agent" digest want
    check "$1: update.sh — код 0" test "$rc" -eq 0
    check "$1: версия 2.5.0 на месте" grep -qx 'version: 2.5.0' "$t/extension.yaml"
    check_not "$1: файлы прежней версии убраны" test -e "$t/obsolete-file"
    check "$1: юниты меток в каталоге" test -f "$t/bisquite-teleport-labels.timer"
    digest="$(basename "$(readlink "$t/lib")")"
    eq "$1: lib — ссылка на /opt/bisquite/lib/<sha256>" "$ROOT/opt/bisquite/lib/$digest" "$(readlink "$t/lib")"
    check "$1: lib на месте" test -f "$ROOT/opt/bisquite/lib/$digest/bisquite-conf"
    check "$1: lib исполняемый" test -x "$ROOT/opt/bisquite/lib/$digest/bisquite-conf"
    eq "$1: запись группе и всем снята (git archive несёт 0664/0775)" "" \
        "$(find "$t/" "$ROOT/opt/bisquite/lib/$digest/" -perm /022 ! -type l)"
    if command -v python3 >/dev/null 2>&1; then
        want="$(py_digest "$REPO/lib")"
        eq "$1: отпечаток lib тот же, что у сборки" "$want" "$digest"
    fi
    eq "$1: CLI — ссылка на новый каталог" "$t/bisquite-teleport" "$(readlink "$ROOT/usr/local/sbin/bisquite-teleport")"
    eq "$1: схема — ссылка на новый knobs" "$t/knobs" "$(readlink "$ROOT/opt/bisquite/knobs/teleport")"
    for u in teleport.service bisquite-teleport-labels.service bisquite-teleport-labels.timer; do
        check "$1: $u установлен" cmp -s "$t/$u" "$ROOT/etc/systemd/system/$u"
    done
    check "$1: daemon-reload" grep -qx 'daemon-reload' "$FAKE/systemctl.log"
    check "$1: таймер включён" grep -qx 'enable --now bisquite-teleport-labels.timer' "$FAKE/systemctl.log"
    check_not "$1: агент не перезапускался" grep -q 'teleport.service' "$FAKE/systemctl.log"
    check_not "$1: бинарь агента не скачивался" test -e "$FAKE/curl.argv"
    check "$1: бинарь агента прежний" grep -q 'v18.6.8' "$ROOT/usr/local/bin/teleport"
    eq "$1: config сохранён — env" dev "$(get TELEPORT_ENV)"
    eq "$1: config сохранён — прокси" teleport.example.org "$(get TELEPORT_PROXY)"
    check "$1: регистрация цела" test -s "$ROOT/var/lib/teleport/host_uuid"
    check "$1: новый CLI работает" bash -c 'bash "$1/usr/local/sbin/bisquite-teleport" status >/dev/null 2>&1' _ "$ROOT"
}

if ! command -v git >/dev/null 2>&1 || ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    # A container with only the tree mounted (python:3.12-slim): no git, no
    # repository — said aloud, not passed silently.
    echo "ПРОПУЩЕНО: update.sh — нет git или $REPO не git-репозиторий, архив не собрать" >&3
elif make_archive; then
    check "архив: update.sh внутри" bash -c 'tar -tzf "$1" | grep -qx "extensions/debian/teleport-agent/update.sh"' _ "$TMP/agent.tar.gz"
    check "архив: lib внутри" bash -c 'tar -tzf "$1" | grep -qx "lib/bisquite-conf"' _ "$TMP/agent.tar.gz"

    old_robot /opt/bisquite
    out="$(bash "$UPD" 2>&1)"; rc=$?
    [[ "$rc" -eq 0 ]] || echo "$out" >&3
    updated_ok "раскладка /opt/bisquite"
    check "раскладка /opt/bisquite: версия агента передана install.sh" grep -q '18.6.8 уже установлен' <<< "$out"
    reset_logs
    out="$(bash "$UPD" 2>&1)"; rc=$?
    eq "повторный update.sh — код 0" 0 "$rc"
    eq "повторный update.sh — один каталог lib" 1 "$(find "$ROOT/opt/bisquite/lib" -mindepth 1 -maxdepth 1 | wc -l)"
    check_not "повторный update.sh — временных каталогов нет" \
        bash -c 'find "$1/opt/bisquite" -maxdepth 1 -name ".teleport-agent.*" | grep -q .' _ "$ROOT"

    old_robot /opt/vmsetup
    out="$(bash "$UPD" 2>&1)"; rc=$?
    [[ "$rc" -eq 0 ]] || echo "$out" >&3
    updated_ok "раскладка /opt/vmsetup"
    check "раскладка /opt/vmsetup: старый каталог не тронут" test -f "$ROOT/opt/vmsetup/teleport-agent/obsolete-file"
    check "раскладка /opt/vmsetup: сказано про старый путь" grep -q '/opt/vmsetup' <<< "$out"

    old_robot /opt/bisquite
    rm -f "$ROOT/usr/local/bin/teleport"
    out="$(bash "$UPD" 2>&1)"; rc=$?
    check "агента нет — отказ" test "$rc" -ne 0
    check "агента нет — каталог расширения не тронут" test -f "$ROOT/opt/bisquite/teleport-agent/obsolete-file"
    check_not "агента нет — lib не разложен" test -d "$ROOT/opt/bisquite/lib"

    old_robot /opt/bisquite
    bash "$UPD" >/dev/null 2>&1
    check_not "update.sh из установленного каталога — отказ" bash "$ROOT/opt/bisquite/teleport-agent/update.sh" 2>/dev/null
else
    bad "update.sh: git archive рабочего дерева не собрался"
fi

echo
echo "проверок: $((pass + fail)), не прошло: $fail"
(( fail == 0 ))
