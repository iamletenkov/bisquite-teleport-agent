#!/usr/bin/env bash
# Build bisquite-teleport-agent_<version>_all.deb and SHA256SUMS with plain
# dpkg-deb: no debhelper, no network. The package is architecture
# independent (bash, units, schema); the Teleport binary is not in it.
#
#   tools/build-deb.sh [--out DIR]      default DIR: dist/
#
# Reproducible: owners root:root, fixed modes, every mtime = SOURCE_DATE_EPOCH
# (default: the time of the last commit), gzip -n. Two builds of one commit
# give the same sha256 — the pin of the bisquite extension and of a portal
# mirror can be checked against a rebuild.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
OUT="$REPO/dist"
while (( $# )); do
    case "$1" in
        --out) OUT="${2:?--out без каталога}"; shift 2 ;;
        *) echo "использование: tools/build-deb.sh [--out DIR]" >&2; exit 2 ;;
    esac
done

NAME=bisquite-teleport-agent
VERSION="$(tr -d '[:space:]' < "$REPO/VERSION")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION='$VERSION': ожидали X.Y.Z" >&2; exit 1; }
if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
    SOURCE_DATE_EPOCH="$(git -C "$REPO" log -1 --format=%ct 2>/dev/null || date +%s)"
fi
export SOURCE_DATE_EPOCH
command -v dpkg-deb >/dev/null || { echo "нет dpkg-deb" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -r -f -- "$STAGE"' EXIT
P="$STAGE/pkg"
PKG="$P/usr/lib/bisquite-teleport"
DOC="$P/usr/share/doc/$NAME"
UNITS="$P/usr/lib/systemd/system"
install -d -m 0755 "$P" "$P/DEBIAN" "$PKG" "$PKG/lib" "$P/usr/sbin" "$UNITS" "$DOC"

install -m 0755 "$REPO/src/bisquite-teleport" "$PKG/bisquite-teleport"
install -m 0755 "$REPO/src/knobs.apply" "$PKG/knobs.apply"
install -m 0755 "$REPO/src/pkg-setup" "$PKG/pkg-setup"
install -m 0644 "$REPO/src/knobs" "$PKG/knobs"
install -m 0755 "$REPO/lib/bisquite-conf" "$PKG/lib/bisquite-conf"
printf '%s\n' "$VERSION" > "$PKG/VERSION"; chmod 0644 "$PKG/VERSION"
ln -s ../lib/bisquite-teleport/bisquite-teleport "$P/usr/sbin/bisquite-teleport"
for u in "$REPO"/src/systemd/*; do
    install -m 0644 "$u" "$UNITS/$(basename "$u")"
done
install -m 0644 "$REPO/LICENSE" "$DOC/copyright"
install -m 0644 "$REPO/NOTICE" "$DOC/NOTICE"
install -m 0644 "$REPO/README.md" "$DOC/README.md"
install -m 0644 "$REPO/docs/portal-labels-api.md" "$DOC/portal-labels-api.md"
gzip -n -9 -c "$REPO/CHANGELOG.md" > "$DOC/changelog.gz"; chmod 0644 "$DOC/changelog.gz"

for s in postinst prerm postrm; do
    install -m 0755 "$REPO/debian/$s" "$P/DEBIAN/$s"
done
size="$(du -s -k --apparent-size --exclude=DEBIAN "$P" | cut -f1)"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SIZE@/$size/" "$REPO/debian/control.in" > "$P/DEBIAN/control"
chmod 0644 "$P/DEBIAN/control"
( cd "$P" && find . -path ./DEBIAN -prune -o -type f -print | sed 's|^\./||' | LC_ALL=C sort \
    | xargs -d '\n' md5sum ) > "$P/DEBIAN/md5sums"
chmod 0644 "$P/DEBIAN/md5sums"

find "$P" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
install -d -m 0755 "$OUT"
DEB="$OUT/${NAME}_${VERSION}_all.deb"
dpkg-deb --root-owner-group -Zxz --build "$P" "$DEB" >/dev/null
( cd "$OUT" && sha256sum -- "$(basename "$DEB")" > SHA256SUMS )
echo "$DEB"
cat "$OUT/SHA256SUMS"
