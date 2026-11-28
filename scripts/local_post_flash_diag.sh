#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# macOS One-Click Post-Flash Boot Monitor & Diagnostics for REDMI K90 OriginOS 7
#
# Usage:
#   bash scripts/local_post_flash_diag.sh [build_tag] [--reboot]
#
# Options:
#   --reboot   Auto-run `fastboot reboot` without prompt if device is in fastboot/fastbootd
#
# What it does automatically after flashing:
#   1. If device is still sitting in fastboot/fastbootd, offers one-key reboot (or auto-reboots with --reboot)
#   2. Waits for ADB & continuously records full logcat (auto-reconnects across bootloops!)
#   3. Live-monitors boot_completed / bootanim / captured line count
#   4. Automatically dumps getprop, mount, dmesg, pstore, SELinux mode, display/FOD/
#      camera/audio/vibrator/NFC/Wi-Fi/telephony HAL status, and service list
#   5. Extracts deduplicated SELinux AVC denials + FATAL/crash/missing-HAL errors
#      into SUMMARY.txt so you can inspect or share directly for Stage 3 fixes
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_TAG="v0.1-bringup"
AUTO_REBOOT=0
for arg in "$@"; do
  case "$arg" in
    --reboot) AUTO_REBOOT=1 ;;
    -h|--help)
      echo "Usage: bash scripts/local_post_flash_diag.sh [build_tag] [--reboot]"
      exit 0
      ;;
    *) BUILD_TAG="$arg" ;;
  esac
done
STAMP="$(date '+%Y%m%d_%H%M%S')"
DIAG_DIR="$REPO_ROOT/logs/post_flash_${BUILD_TAG}_${STAMP}"
mkdir -p "$DIAG_DIR"

command -v adb >/dev/null || { echo "[ERROR] adb not found! Run: brew install android-platform-tools"; exit 1; }
adb start-server >/dev/null 2>&1 || true

LOGCAT_FILE="$DIAG_DIR/logcat_all.txt"
: > "$LOGCAT_FILE"
LOGCAT_PID=""
SNAPSHOT_TAKEN=0
FINALIZED=0

echo "=================================================================="
echo "  REDMI K90 OriginOS 7 - Post-Flash Boot Monitor & Diagnostics"
echo "  Tag      : $BUILD_TAG"
echo "  Log Dir  : $DIAG_DIR"
echo "=================================================================="

# 0. Check if device is still in fastboot/fastbootd
if command -v fastboot >/dev/null; then
  FB_DEV="$(fastboot devices 2>/dev/null | awk 'NF>=2{print $1; exit}' || true)"
  ADB_DEV="$(adb devices 2>/dev/null | awk '$1 != "*" && $1 != "List" && NF == 2 {print $1; exit}' || true)"
  if [[ -n "$FB_DEV" && -z "$ADB_DEV" ]]; then
    echo "[INFO] Detected device '$FB_DEV' still in Fastboot/Fastbootd."
    if [[ "$AUTO_REBOOT" == "1" ]]; then
      echo "[INFO] --reboot specified: rebooting device into Android (ignoring if already rebooting)..."
      fastboot reboot || true
    else
      read -r -p "Reboot device into Android now? [Y/n]: " RB_ANS
      if [[ -z "$RB_ANS" || "$RB_ANS" == "y" || "$RB_ANS" == "Y" ]]; then
        fastboot reboot || true
      fi
    fi
  fi
fi

# Safe adb shell wrapper (never aborts main script on disconnect)
adb_try() {
  adb shell "$@" 2>&1 || true
}

start_logcat_loop() {
  (
    attempt=0
    while true; do
      state="$(adb get-state 2>/dev/null || true)"
      if [[ "$state" == "device" ]]; then
        attempt=$((attempt + 1))
        {
          echo ""
          echo "==================== [LOGCAT SESSION #${attempt} @ $(date '+%H:%M:%S')] ===================="
        } >> "$LOGCAT_FILE"
        adb logcat -b all -v threadtime >> "$LOGCAT_FILE" 2>&1 || true
      fi
      sleep 1
    done
  ) &
  LOGCAT_PID=$!
}

stop_logcat_loop() {
  if [[ -n "$LOGCAT_PID" ]]; then
    kill "$LOGCAT_PID" 2>/dev/null || true
    # Kill child adb logcat spawned by subshell if still running
    pkill -P "$LOGCAT_PID" 2>/dev/null || true
    wait "$LOGCAT_PID" 2>/dev/null || true
    LOGCAT_PID=""
  fi
}

collect_snapshot() {
  local label="${1:-boot}"
  echo ""
  echo ">>> [Snapshot: $label] Collecting device properties, mounts, dmesg, pstore & HAL status..."

  adb_try getprop > "$DIAG_DIR/props_dump.txt"
  adb_try mount > "$DIAG_DIR/mounts.txt"
  adb_try service list > "$DIAG_DIR/service_list.txt"

  # dmesg (try direct first, fallback to su if restricted)
  adb shell dmesg > "$DIAG_DIR/dmesg.txt" 2>&1 || true
  if [[ ! -s "$DIAG_DIR/dmesg.txt" ]] || grep -qiE "Operation not permitted|Permission denied" "$DIAG_DIR/dmesg.txt"; then
    adb_try "su -c dmesg" > "$DIAG_DIR/dmesg.txt"
  fi

  # Pull kernel pstore/ramoops if present (goldmine if previous boot panicked)
  PSTORE_LIST="$(adb_try 'ls /sys/fs/pstore 2>/dev/null' | tr -d '\r')"
  if [[ -n "$PSTORE_LIST" && "$PSTORE_LIST" != *"No such file"* && "$PSTORE_LIST" != *"Permission denied"* ]]; then
    mkdir -p "$DIAG_DIR/pstore"
    adb pull /sys/fs/pstore/. "$DIAG_DIR/pstore/" >/dev/null 2>&1 || true
  fi

  # Tombstones list (native crashes)
  adb_try 'ls -lt /data/tombstones 2>/dev/null | head -n 30' > "$DIAG_DIR/tombstones_list.txt"

  # Hardware & HAL health snapshot
  {
    echo "=== SELinux & Kernel ==="
    echo -n "getenforce: "; adb_try getenforce
    echo -n "uname     : "; adb_try uname -a
    echo -n "uptime    : "; adb_try uptime
    echo ""

    echo "=== Display & SurfaceFlinger ==="
    adb_try wm size
    adb_try wm density
    adb_try 'dumpsys display | grep -E "mDisplayInfo|DisplayModeRecord|activeMode|refreshRate|mState|brightness" | head -n 60'
    echo ""

    echo "=== Fingerprint (FOD) ==="
    adb_try 'dumpsys fingerprint | head -n 60'
    echo ""

    echo "=== Camera ==="
    adb_try 'dumpsys media.camera | head -n 80'
    echo ""

    echo "=== Vibrator / Haptics ==="
    adb_try 'dumpsys vibrator_manager | head -n 60'
    echo ""

    echo "=== Audio ==="
    adb_try 'dumpsys audio | head -n 60'
    echo ""

    echo "=== NFC ==="
    adb_try 'dumpsys nfc | head -n 50'
    echo ""

    echo "=== Wi-Fi & Telephony ==="
    adb_try 'dumpsys wifi | head -n 40'
    adb_try 'dumpsys telephony.registry | head -n 40'
  } > "$DIAG_DIR/hal_hardware_check.txt"

  SNAPSHOT_TAKEN=1
  echo "[OK] Hardware & system snapshot saved."
}

generate_summary() {
  echo ""
  echo ">>> [Analyze] Parsing logcat, dmesg, SELinux AVCs & crashes..."
  python3 - "$DIAG_DIR" "$BUILD_TAG" <<'PYEOF'
import collections, os, re, sys

diag_dir, build_tag = sys.argv[1:3]
logcat_p = os.path.join(diag_dir, "logcat_all.txt")
dmesg_p = os.path.join(diag_dir, "dmesg.txt")
props_p = os.path.join(diag_dir, "props_dump.txt")
mounts_p = os.path.join(diag_dir, "mounts.txt")
hw_p = os.path.join(diag_dir, "hal_hardware_check.txt")

def read_lines(p):
    if not os.path.isfile(p):
        return []
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        return f.readlines()

log_lines = read_lines(logcat_p)
dmesg_lines = read_lines(dmesg_p)
props_lines = read_lines(props_p)
mounts_lines = read_lines(mounts_p)

# Parse getprop [k]: [v]
props = {}
re_prop = re.compile(r"^\[([^\]]+)\]: \[(.*)\]$")
for ln in props_lines:
    m = re_prop.match(ln.strip())
    if m:
        props[m.group(1)] = m.group(2)

# Extract crashes / FATAL / missing HAL / init errors
crash_pats = re.compile(
    r"(FATAL EXCEPTION|AndroidRuntime.*FATAL|Abort message:|Fatal signal \d+|"
    r"Watchdog.*Killing|ServiceManager.*(?:not found|Waiting for service|Could not find)|"
    r"hwservicemanager.*not found|Failed to mount|exited with status [1-9]|"
    r"restarting in|secilc|SELinux.*(?:Failed|error)|CRITICAL.*reboot|"
    r"Unable to instantiate|UnsatisfiedLinkError|NoSuchMethodError|ClassNotFoundException)",
    re.IGNORECASE,
)
crash_hits = []
for i, ln in enumerate(log_lines, 1):
    if crash_pats.search(ln):
        crash_hits.append(f"L{i}: {ln.rstrip()}")
for i, ln in enumerate(dmesg_lines, 1):
    if re.search(r"(init:.*(?:Failed|reboot|crashed|critical)|secilc|Kernel panic|BUG:|Oops:)", ln, re.I):
        crash_hits.append(f"dmesg:L{i}: {ln.rstrip()}")

with open(os.path.join(diag_dir, "crashes_fatals.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(crash_hits) + ("\n" if crash_hits else "(no crash/fatal patterns matched)\n"))

# Extract & deduplicate SELinux AVC denials
avc_counter = collections.Counter()
avc_raw = []
re_avc = re.compile(
    r"avc:\s+denied\s+(\{[^}]+\}).*?scontext=([^\s]+).*?tcontext=([^\s]+).*?tclass=([^\s]+)(?:.*?permissive=(\d))?"
)
for src_name, lines in (("logcat", log_lines), ("dmesg", dmesg_lines)):
    for ln in lines:
        if "avc:" in ln and "denied" in ln:
            avc_raw.append(f"[{src_name}] {ln.rstrip()}")
            m = re_avc.search(ln)
            if m:
                key = f"scontext={m.group(2)}  tcontext={m.group(3)}  tclass={m.group(4)}  perms={m.group(1)}  permissive={m.group(5) or '?'}"
                avc_counter[key] += 1

with open(os.path.join(diag_dir, "selinux_avc.txt"), "w", encoding="utf-8") as f:
    f.write(f"=== Deduplicated SELinux AVC Denials ({len(avc_counter)} unique / {len(avc_raw)} total) ===\n")
    for k, cnt in avc_counter.most_common(120):
        f.write(f"{cnt:5d}x  {k}\n")
    f.write("\n=== First 100 Raw AVC Lines ===\n")
    for ln in avc_raw[:100]:
        f.write(ln + "\n")

# Key mount verification
want_mounts = ["/system", "/product", "/system_ext", "/vendor", "/odm", "/mnt/vendor/mi_ext", "/product/vm-system", "/data"]
found_mounts = []
for ln in mounts_lines:
    parts = ln.split()
    if len(parts) >= 3 and parts[2] in want_mounts:
        found_mounts.append(f"  {parts[2]:<22s} type={parts[4] if len(parts)>4 else '?'}  src={parts[0]}")

# Key prop verification
key_prop_names = [
    "sys.boot_completed",
    "init.svc.bootanim",
    "ro.vivo.os.build.display.id",
    "ro.vivo.oem.name",
    "ro.vivo.vgc.activate",
    "ro.product.model",
    "ro.product.device",
    "ro.product.odm.device",
    "ro.sf.lcd_density",
    "persist.vivo.phone.fps_max",
    "ro.telephony.default_network",
    "debug.stagefright.ccodec",
    "media.c2.hal.selection",
    "ro.adb.secure",
    "ro.debuggable",
]

selinux_mode = "unknown"
if os.path.isfile(hw_p):
    for ln in read_lines(hw_p):
        if ln.startswith("getenforce:"):
            selinux_mode = ln.split(":", 1)[1].strip()
            break

summary = [
    "==================================================================",
    f"  REDMI K90 OriginOS 7 Post-Flash Diagnostic Summary ({build_tag})",
    "==================================================================",
    f"Logcat lines captured : {len(log_lines):,d}",
    f"Dmesg lines captured  : {len(dmesg_lines):,d}",
    f"SELinux mode          : {selinux_mode}",
    f"Crash / Fatal hits    : {len(crash_hits)}",
    f"SELinux AVC denials   : {len(avc_raw)} total ({len(avc_counter)} unique)",
    "",
    "--- Key System Properties ---",
]
for kp in key_prop_names:
    summary.append(f"  {kp:<32s} = {props.get(kp, '<not set>')}")

summary.append("")
summary.append("--- Key Mounted Partitions ---")
summary.extend(found_mounts if found_mounts else ["  (no mount table captured yet)"])

summary.append("")
summary.append("--- Top 15 SELinux AVC Denials ---")
if avc_counter:
    for k, cnt in avc_counter.most_common(15):
        summary.append(f"  {cnt:5d}x  {k}")
else:
    summary.append("  (none)")

summary.append("")
summary.append("--- First 25 Crash / Fatal / Missing-HAL Hits ---")
if crash_hits:
    for ln in crash_hits[:25]:
        summary.append("  " + ln[:220])
else:
    summary.append("  (none)")

summary.append("")
summary.append(f"Full files saved in: {diag_dir}")
summary.append("==================================================================")

out_txt = "\n".join(summary) + "\n"
with open(os.path.join(diag_dir, "SUMMARY.txt"), "w", encoding="utf-8") as f:
    f.write(out_txt)
print(out_txt)
PYEOF
}

finalize() {
  if [[ "$FINALIZED" -eq 1 ]]; then
    return
  fi
  FINALIZED=1
  trap - INT TERM EXIT
  echo ""
  echo ">>> Stopping logcat capture & finalizing report..."
  stop_logcat_loop

  # Take snapshot now if device is currently online and we haven't captured one yet
  if [[ "$SNAPSHOT_TAKEN" -eq 0 ]]; then
    if [[ "$(adb get-state 2>/dev/null || true)" == "device" ]]; then
      collect_snapshot "on-exit"
    fi
  fi
  generate_summary
}
trap finalize INT TERM EXIT

# 1. Start continuous auto-reconnecting logcat recorder immediately
echo ""
echo "[1/3] Waiting for REDMI K90 ADB connection (Ctrl-C anytime to stop & generate summary)..."
echo "      Tip: First boot from HyperOS -> OriginOS normally takes 2~4 minutes."
start_logcat_loop

START_TS="$(date +%s)"
WARNED_UNAUTH=0
BOOTED=0

# 2. Live boot progress monitor
while true; do
  NOW_TS="$(date +%s)"
  ELAPSED=$((NOW_TS - START_TS))
  LINES="$(wc -l < "$LOGCAT_FILE" | tr -d ' ')"

  RAW_DEV="$(adb devices 2>/dev/null | awk '$1 != "*" && $1 != "List" && NF == 2 {print $2; exit}' || true)"
  if [[ "$RAW_DEV" == "unauthorized" && "$WARNED_UNAUTH" -eq 0 ]]; then
    echo ""
    echo "[ACTION NEEDED] ADB shows 'unauthorized' — if screen is on, tap 'Allow USB debugging' on phone!"
    WARNED_UNAUTH=1
  fi

  if [[ "$RAW_DEV" == "device" ]]; then
    BC="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n' || true)"
    BA="$(adb shell getprop init.svc.bootanim 2>/dev/null | tr -d '\r\n' || true)"
    printf "\r  [%3ds] ADB=online | boot_completed=%-1s | bootanim=%-8s | logcat_lines=%-7s " \
      "$ELAPSED" "${BC:-0}" "${BA:-?}" "$LINES"
    if [[ "$BC" == "1" ]]; then
      BOOTED=1
      echo ""
      echo ""
      echo "=================================================================="
      echo "  [SUCCESS] OriginOS 7 REACHED sys.boot_completed=1 in ${ELAPSED}s!"
      echo "=================================================================="
      echo "[2/3] Waiting 10s for post-boot services to settle, then taking full hardware snapshot..."
      sleep 10
      collect_snapshot "boot_completed"
      generate_summary
      break
    fi
  else
    printf "\r  [%3ds] ADB=%-12s | logcat_lines=%-7s (waiting for device...) " \
      "$ELAPSED" "${RAW_DEV:-offline}" "$LINES"
  fi
  sleep 3
done

# 3. Optional interactive Stage-3 hardware test capture window
if [[ "$BOOTED" -eq 1 ]]; then
  echo ""
  echo "[3/3] Logcat is STILL recording in the background!"
  echo "      You can now test on your REDMI K90:"
  echo "        - Wi-Fi / 5G 移动数据 / 通话"
  echo "        - 亮度调节 / 120Hz 刷新率"
  echo "        - 屏下指纹录入与解锁 (FOD)"
  echo "        - 相机拍照录像 / 相册"
  echo "        - 外放音频 / 蓝牙 / NFC / 线性马达振动"
  echo ""
  read -r -p "After testing, press [Enter] to refresh snapshot & finish (or Ctrl-C anytime): " _ || true
  if [[ "$(adb get-state 2>/dev/null || true)" == "device" ]]; then
    collect_snapshot "post_hardware_test"
  fi
fi
