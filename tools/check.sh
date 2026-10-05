#!/usr/bin/env bash
# Одна точка входа для проверок: shellcheck по всем скриптам (если
# установлен; в CI — обязательно) и все tests/test-*.sh. Доводит до конца
# все проверки, даже если первая упала.
#
#   tools/check.sh              shellcheck + тесты
#   tools/check.sh --lint-only  только shellcheck
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"

SCRIPTS=(src/bisquite-teleport src/knobs.apply src/pkg-setup lib/bisquite-conf
         debian/postinst debian/prerm debian/postrm tools/build-deb.sh tools/check.sh
         tests/test-*.sh)

rc=0
echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
    (cd "$REPO" && shellcheck -x "${SCRIPTS[@]}") || rc=1
elif [[ -n "${CI:-}" ]]; then
    echo "shellcheck не установлен, а в CI он обязателен" >&2; rc=1
else
    echo "  shellcheck не установлен — пропущено"
fi
[[ "${1:-}" == --lint-only ]] && exit "$rc"

for t in "$REPO"/tests/test-*.sh; do
    echo
    echo "== ${t#"$REPO"/} =="
    bash "$t" || rc=1
done

echo
if (( rc )); then echo "проверки не прошли" >&2; else echo "проверки прошли"; fi
exit "$rc"
