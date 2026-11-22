#!/usr/bin/env bash
# 打 TWRP 刷机包：rootfs tar 作为第一个 STORED 成员，偏移写进 update-binary。
set -euo pipefail

SRC_DIR=${SRC_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
WORK_DIR=${WORK_DIR:-$SRC_DIR/work}
OUT_DIR=${OUT_DIR:-$SRC_DIR/out}
ROOTFS_TAR=${ROOTFS_TAR:-$OUT_DIR/rootfs.tar.gz}
TARGET_DIR=${TARGET_DIR:-/data/rootfs}
ZIP_NAME=${ZIP_NAME:-aries-alpine.zip}
UPDATE_BINARY_IN=${UPDATE_BINARY_IN:-$SRC_DIR/scripts/recovery/update-binary.in}
UPDATER_SCRIPT=${UPDATER_SCRIPT:-$SRC_DIR/scripts/recovery/updater-script}
MKZIP=${MKZIP:-$SRC_DIR/scripts/mkzip.py}

ZIP=${ZIP:-$OUT_DIR/$ZIP_NAME}
ZIP_DIR=$WORK_DIR/zip
MEMBER=$(basename "$ROOTFS_TAR")

log() { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$ROOTFS_TAR" ] || die "缺少 $ROOTFS_TAR（先 make rootfs）"

mkdir -p "$OUT_DIR"
rm -rf "$ZIP_DIR"
mkdir -p "$ZIP_DIR/META-INF/com/google/android"
cp "$UPDATER_SCRIPT" "$ZIP_DIR/META-INF/com/google/android/updater-script"
cp "$UPDATE_BINARY_IN" "$ZIP_DIR/META-INF/com/google/android/update-binary"

log "第一遍：量 $MEMBER 的偏移"
eval "$(python3 "$MKZIP" --work "$ZIP_DIR" --output "$ZIP" \
	--member "$MEMBER" --source "$ROOTFS_TAR" --print-offset)"
[ -n "${OFFSET:-}" ] && [ -n "${SIZE:-}" ] || die '没量出偏移'
[ "$SIZE" = "$(stat -c %s "$ROOTFS_TAR")" ] || die "zip 里的大小对不上 ($SIZE)"

sed -e "s|@@TARGET_DIR@@|$TARGET_DIR|" \
	-e "s|@@ROOTFS_MEMBER@@|$MEMBER|" \
	-e "s|@@ROOTFS_OFFSET@@|$OFFSET|" \
	-e "s|@@ROOTFS_SIZE@@|$SIZE|" \
	"$UPDATE_BINARY_IN" > "$ZIP_DIR/META-INF/com/google/android/update-binary"
chmod 0755 "$ZIP_DIR/META-INF/com/google/android/update-binary"

sed -e "s|@@ROOTFS_MEMBER@@|$MEMBER|" \
	"$UPDATER_SCRIPT" > "$ZIP_DIR/META-INF/com/google/android/updater-script"

log "第二遍：写入 offset=$OFFSET size=$SIZE"
python3 "$MKZIP" --work "$ZIP_DIR" --output "$ZIP" \
	--member "$MEMBER" --source "$ROOTFS_TAR"

[ -n "${SUDO_UID:-}" ] && chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$ZIP"
log "刷机包: $ZIP ($(du -h "$ZIP" | cut -f1))"
log "sha256: $(sha256sum "$ZIP" | cut -d' ' -f1)"
