#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# REDMI K90 (annibale) / OriginOS 7 - ONE-KEY post-download flow
#
# Runs, in one command, everything AFTER the modelscope bundle is downloaded:
#   [1/5] locate bundle + verify SHA256 of all 7 images
#   [2/5] backup: fastboot vars, root-partition dd backup (if ADB root available),
#                 unmerged Virtual A/B -cow gate
#   [3/5] flash: reuses bundle's flash_port_mac.sh in place (NO copying of images)
#   [4/5] post-flash logcat/dmesg/AVC diagnostics (auto-finalizes, no Enter needed)
#   [5/5] print where everything landed
#
# Usage:
#   bash scripts/flash_onekey.sh [build_tag] [--yes] [--skip-part-backup]
#
#   build_tag            default: v0.2-bringup
#   --yes                skip the typed FLASH confirmation (for unattended runs)
#   --skip-part-backup   deprecated / no-op: missing partition backups are warn-only now
#
# Environment:
#   STOCK_FLASH_DIR      directory containing a stock K90 flash_all.sh (warn-only)
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_TAG="v0.2-bringup"
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    --skip-part-backup) echo "[INFO] --skip-part-backup is deprecated: missing backups are warn-only now." ;;
    -h|--help)
      echo "Usage: bash scripts/flash_onekey.sh [build_tag] [--yes] [--skip-part-backup]"
      exit 0
      ;;
    --*) echo "[FATAL] Unknown option: $arg" >&2; exit 2 ;;
    *) BUILD_TAG="$arg" ;;
  esac
done

BUNDLE_DIR="$REPO_ROOT/out/${BUILD_TAG}/port_bundle"
BACKUP_DIR="$REPO_ROOT/backups"
DIAG_SCRIPT="$REPO_ROOT/scripts/local_post_flash_diag.sh"
STAMP="$(date '+%Y%m%d_%H%M%S')"

log() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { echo "[FATAL] $*" >&2; exit 1; }
warn() { echo "[WARN] $*"; }

echo "=================================================================="
echo "  REDMI K90 OriginOS 7 - ONE-KEY (build_tag=$BUILD_TAG)"
echo "  Bundle  : $BUNDLE_DIR"
echo "  Backups : $BACKUP_DIR"
echo "=================================================================="

# ---------------------------------------------------------------- [1/5] preflight
log "[1/5] Preflight: tools + downloaded bundle"
for t in fastboot adb shasum; do
  command -v "$t" >/dev/null || die "'$t' not found. Install platform-tools (brew install android-platform-tools)."
done

[[ -d "$BUNDLE_DIR" ]] || die "Bundle not found: $BUNDLE_DIR
  The ModelScope download is probably still running. Wait until
  out/${BUILD_TAG}/port_bundle/ contains the images, then rerun."

REQUIRED=(system.img product.img system_ext.img mi_ext.img mi_product.img vbmeta.img vbmeta_system.img SHA256SUMS.txt flash_port_mac.sh)
MISSING=()
for f in "${REQUIRED[@]}"; do
  [[ -f "$BUNDLE_DIR/$f" ]] || MISSING+=("$f")
done
[[ ${#MISSING[@]} -eq 0 ]] || die "Bundle incomplete, missing: ${MISSING[*]}
  If the download was interrupted, rerun local_download_ms.sh."

echo "  -> Verifying SHA256SUMS.txt in bundle dir (no file copies)..."
(cd "$BUNDLE_DIR" && shasum -a 256 -c SHA256SUMS.txt) || die "Image checksum verification failed. Do NOT flash."
echo "  [OK] All 7 images verified."

# ---------------------------------------------------------------- [2/5] backup
log "[2/5] Backup & safety gates"
mkdir -p "$BACKUP_DIR"

ADB_DEV="$(adb devices 2>/dev/null | awk '$1 != "*" && $1 != "List" && $2 == "device" {print $1; exit}' || true)"
FB_DEV="$(fastboot devices 2>/dev/null | awk 'NF>=2{print $1; exit}' || true)"

if [[ -n "$ADB_DEV" ]]; then
  echo "  -> Device is in Android ($ADB_DEV). Trying adb root for partition backup..."
  adb root >/dev/null 2>&1 || warn "adb root failed; partition dd backup will be skipped (fastboot vars still saved)."
  sleep 2
  if adb shell id 2>/dev/null | grep -q 'uid=0'; then
    for p in persist modemst1 modemst2 fsg fsc devinfo; do
      echo "     dd /dev/block/bootdevice/by-name/$p ..."
      adb shell "dd if=/dev/block/bootdevice/by-name/$p of=/sdcard/$p.img bs=4M status=none" 2>/dev/null || {
        warn "Failed to dump $p (partition may not exist on this device)."
        continue
      }
      adb pull "/sdcard/$p.img" "$BACKUP_DIR/${p}_${STAMP}.img" >/dev/null 2>&1 || warn "Failed to pull $p.img"
      adb shell "rm -f /sdcard/$p.img" >/dev/null 2>&1 || true
    done
    (
      cd "$BACKUP_DIR"
      shasum -a 256 *_"${STAMP}".img > "SHA256SUMS_partitions_${STAMP}.txt" 2>/dev/null || true
    )
    echo "  [OK] Partition backups saved to $BACKUP_DIR"
  else
    warn "No root shell: cannot dd persist/modem here. See the gate below."
  fi
  echo "  -> Rebooting into bootloader..."
  adb reboot bootloader
  for _ in $(seq 1 30); do
    FB_DEV="$(fastboot devices 2>/dev/null | awk 'NF>=2{print $1; exit}' || true)"
    [[ -n "$FB_DEV" ]] && break
    sleep 1
  done
  [[ -n "$FB_DEV" ]] || die "Device did not appear in fastboot after adb reboot bootloader."
fi

[[ -n "$FB_DEV" ]] || die "No device found in ADB or Fastboot. Connect the phone and rerun."

echo "  -> Saving fastboot variables..."
fastboot getvar all > "$BACKUP_DIR/k90_fastboot_vars_${STAMP}.txt" 2>&1 || true

PRODUCT="$(fastboot getvar product 2>&1 | awk -F': ' '/^product:/{print $2}' | tr -d '\r' | head -n 1)"
[[ "$PRODUCT" == "annibale" ]] || die "Connected product='$PRODUCT', expected 'annibale' (REDMI K90)."

SLOT="$(fastboot getvar current-slot 2>&1 | awk -F': ' '/^current-slot:/{print $2}' | tr -d '\r' | head -n 1)"
[[ "$SLOT" == "a" || "$SLOT" == "b" ]] || die "Could not determine current slot (got '${SLOT:-empty}')."
echo "  [OK] device=annibale, active slot=${SLOT}"

# Gate 1: unmerged Virtual A/B snapshots (known cause of infinite reboot in v0.1)
COWS="$(fastboot getvar all 2>&1 | grep -E "partition-size:(vendor|odm|vendor_dlkm|system_dlkm)_${SLOT}-cow:" || true)"
if [[ -n "$COWS" ]]; then
  echo "$COWS"
  die "Unmerged Virtual A/B -cow partitions detected on slot _${SLOT}.
  Wiping /metadata loses the snapuserd merge table and corrupts vendor/odm.
  Merge the OTA (boot stock OS once) or reflash clean stock vendor/odm/dlkm first."
fi
echo "  [OK] No unmerged -cow partitions on slot _${SLOT}."

# Warning only: non-recoverable partition backups (never blocks the flash)
if ! compgen -G "$BACKUP_DIR/persist_*.img" >/dev/null; then
  warn "No persist/modem partition backup found in $BACKUP_DIR."
  warn "This flow does NOT flash persist/modem, and a stock fastboot image is available, so continuing."
  warn "Caveat: a public persist.img cannot restore THIS device's touch/FOD/sensor calibration."
fi

# Warn-only: stock rescue package
if [[ -n "${STOCK_FLASH_DIR:-}" && -f "${STOCK_FLASH_DIR}/flash_all.sh" ]]; then
  echo "  [OK] Stock flash package found at $STOCK_FLASH_DIR"
else
  warn "Set STOCK_FLASH_DIR to a directory containing stock K90 flash_all.sh so you can rescue the device."
fi

# ---------------------------------------------------------------- [3/5] flash
log "[3/5] Flashing (wipe userdata + metadata, then reboot)"
if [[ "$ASSUME_YES" -ne 1 ]]; then
  echo "  This WILL erase all user data on the phone."
  read -r -p "  Type FLASH to proceed: " FLASH_ANS
  [[ "$FLASH_ANS" == "FLASH" ]] || die "Aborted by user at flash confirmation."
fi

# flash_port_mac.sh cd's into its own directory, so images are used in place.
# Feed its two prompts: wipe=YES, reboot=y.
printf 'YES\ny\n' | bash "$BUNDLE_DIR/flash_port_mac.sh"

# ---------------------------------------------------------------- [4/5] diagnostics
log "[4/5] Post-flash diagnostics (logcat + dmesg + SELinux AVC)"
[[ -f "$DIAG_SCRIPT" ]] || die "Diagnostics script missing: $DIAG_SCRIPT"
# --reboot: reboot if still sitting in fastboot. /dev/null makes the final
# "press Enter after hardware testing" pause finish immediately (one-key).
bash "$DIAG_SCRIPT" "$BUILD_TAG" --reboot < /dev/null

# ---------------------------------------------------------------- [5/5] summary
log "[5/5] Done"
echo "  Images / flash script : $BUNDLE_DIR"
echo "  Backups               : $BACKUP_DIR (k90_fastboot_vars_${STAMP}.txt)"
echo "  Diagnostics           : $REPO_ROOT/logs/post_flash_${BUILD_TAG}_*/SUMMARY.txt"
echo ""
echo "  Next: read SUMMARY.txt, fix issues in D3 order:"
echo "  boot -> network -> display -> FOD -> camera -> haptics -> audio/NFC/BT"
