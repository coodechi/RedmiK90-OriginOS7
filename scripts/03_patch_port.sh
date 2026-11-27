#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Stage 2: Build, Patch, Repack & Verify OriginOS 7 for REDMI K90 (annibale)
#
# Output: fastbootd independent partition bundle ready for macOS flashing:
#   - system.img (OriginOS 7 patched + /oem + /vgc flattened + debloated)
#   - product.img (OriginOS 7 + K90 displayconfig XML)           [full mode]
#   - system_ext.img (OriginOS 7 passthrough)                    [full mode]
#   - mi_ext.img, mi_product.img (empty EROFS anti-hijack)       [full mode]
#   - vbmeta.img, vbmeta_system.img (K90 stock for AVB disable)  [full mode]
#   - flash_port_mac.sh + SHA256SUMS.txt + BUILD_INFO.txt
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/config/device_annibale.env"

WORK_ROOT="${WORK_ROOT:-/tmp/rom_work}"
REPORT_DIR="${REPORT_DIR:-$WORK_ROOT/build_report}"
OUT_DIR="${OUT_DIR:-$WORK_ROOT/port_bundle}"
PORT_ROM_SOURCE="${PORT_ROM_SOURCE:?PORT_ROM_SOURCE env var is required}"
BASE_ROM_URL="${BASE_ROM_URL:-$K90_BASE_ROM_URL}"
BUILD_TAG="${BUILD_TAG:-v0.1-bringup}"
BUILD_SCOPE="${BUILD_SCOPE:-full}"          # full | system_only
DEBUG_ADB="${DEBUG_ADB:-true}"              # true | false
EROFS_COMPRESS="${EROFS_COMPRESS:-$DEFAULT_EROFS_COMPRESS}"

# ------------------------------------------------------------------------------
# K90-BASE ALIGNMENT (v0.2)
#   compatibility_matrix / plat_sepolicy 描述的是 vendor 侧的形状，必须来自 vendor
#   自己的底包。把外来 system 的矩阵+策略和 K90 vendor 拼在一起，必炸在：
#     1) system_server: VintfObject::CheckCompatibility -> FATAL -> 重启循环
#     2) init: selinux_android_load_policy() 失败 -> Freeze() 死循环
#        （表现：卡开机 logo、无 adb、无 kmsg、无 panic）
#   因此默认强制把 system/etc/{vintf,selinux} 换回 K90 原厂，并删除外来 device 矩阵。
#   all | vintf | selinux | none
# ------------------------------------------------------------------------------
ALIGN_K90_BASE="${ALIGN_K90_BASE:-all}"
case "$ALIGN_K90_BASE" in
  all)     ALIGN_K90_VINTF=true;  ALIGN_K90_SELINUX=true ;;
  vintf)   ALIGN_K90_VINTF=true;  ALIGN_K90_SELINUX=false ;;
  selinux) ALIGN_K90_VINTF=false; ALIGN_K90_SELINUX=true ;;
  none)    ALIGN_K90_VINTF=false; ALIGN_K90_SELINUX=false ;;
  *) echo "[FATAL] ALIGN_K90_BASE must be one of: all|vintf|selinux|none (got '$ALIGN_K90_BASE')"; exit 1 ;;
esac
# annibale | none  —— 把 product/build.prop 的 ro.product.product.* 伪装成 K90
MASK_DEVICE="${MASK_DEVICE:-annibale}"

if ! mkdir -p "$WORK_ROOT" "$REPORT_DIR" "$OUT_DIR" 2>/dev/null; then
  echo "[FATAL] 无法创建 WORK_ROOT / REPORT_DIR / OUT_DIR："
  echo "        WORK_ROOT=$WORK_ROOT"
  echo "        REPORT_DIR=$REPORT_DIR"
  echo "        OUT_DIR=$OUT_DIR"
  echo "        常见原因：WORK_ROOT 未导出，REPORT_DIR/OUT_DIR 被展开成 /build_report、"
  echo "        /port_bundle 这类根目录路径（runner 用户对 / 无写权限）。"
  exit 1
fi

# Cleanup any active loop mounts on exit
ACTIVE_MOUNTS=()
cleanup_mounts() {
  set +e
  for m in "${ACTIVE_MOUNTS[@]}"; do
    if mountpoint -q "$m" 2>/dev/null; then
      sudo umount "$m" 2>/dev/null || true
    fi
  done
  if [[ -d "${REPORT_DIR:-}" ]]; then
    sudo chown -R "$(id -u):$(id -g)" "$REPORT_DIR" 2>/dev/null || true
  fi
}
trap cleanup_mounts EXIT

apply_remove_list() {
  local section="$1" stage_dir="$2" log_file="$3"
  local in_sec=0 raw_line line dir_rel target_dir target sz
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="${raw_line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -z "$line" ]]; then
      continue
    fi
    if [[ "$line" == \[*\] ]]; then
      if [[ "$line" == "[$section]" ]]; then
        in_sec=1
      else
        in_sec=0
      fi
      continue
    fi
    if [[ "$in_sec" -ne 1 ]]; then
      continue
    fi

    if [[ "$line" == *"/*" ]]; then
      dir_rel="${line%/*}"
      target_dir="$stage_dir/$dir_rel"
      if sudo test -d "$target_dir"; then
        sz="$(sudo du -sh "$target_dir" | awk '{print $1}')"
        sudo find "$target_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        echo "[CLEARED DIR][$section] $dir_rel (was $sz)" | tee -a "$log_file"
      else
        echo "[SKIP MISSING DIR][$section] $dir_rel" | tee -a "$log_file"
      fi
    else
      target="$stage_dir/$line"
      if sudo test -e "$target" || sudo test -L "$target"; then
        sz="$(sudo du -sh "$target" | awk '{print $1}')"
        sudo rm -rf "$target"
        echo "[REMOVED][$section] $line (was $sz)" | tee -a "$log_file"
      else
        echo "[SKIP MISSING][$section] $line" | tee -a "$log_file"
      fi
    fi
  done < "$REPO_ROOT/config/remove_list.txt"
}

mount_erofs_ro() {
  local img="$1" mnt="$2"
  mkdir -p "$mnt"
  if ! sudo mount -t erofs -o ro,loop "$img" "$mnt" 2>/dev/null; then
    sudo mount -o ro,loop "$img" "$mnt"
  fi
  ACTIVE_MOUNTS+=("$mnt")
}

umount_erofs() {
  local mnt="$1"
  if mountpoint -q "$mnt" 2>/dev/null; then
    sudo umount "$mnt"
  fi
}

echo "=================================================================="
echo "  OriginOS 7 -> REDMI K90 (annibale) Cloud Port Builder"
echo "  Tag:      $BUILD_TAG"
echo "  Scope:    $BUILD_SCOPE"
echo "  DebugADB: $DEBUG_ADB"
echo "  Compress: $EROFS_COMPRESS"
echo "  AlignK90: $ALIGN_K90_BASE (vintf=$ALIGN_K90_VINTF selinux=$ALIGN_K90_SELINUX)"
echo "  MaskDev : $MASK_DEVICE"
echo "  WorkRoot: $WORK_ROOT"
echo "  Report  : $REPORT_DIR"
echo "  OutDir  : $OUT_DIR"
echo "=================================================================="
df -Th "$WORK_ROOT"

# Ensure required tools exist
command -v mkfs.erofs >/dev/null || { echo "[FATAL] mkfs.erofs missing"; exit 1; }
command -v simg2img >/dev/null || { echo "[FATAL] simg2img missing"; exit 1; }
command -v payload-dumper-go >/dev/null || { echo "[FATAL] payload-dumper-go missing"; exit 1; }

# ------------------------------------------------------------------------------
# PHASE A: Extract tiny K90 base artifacts (vbmeta + product displayconfig)
#          Skipped completely in system_only mode!
# ------------------------------------------------------------------------------
K90_EXTRACTED_DC=""
if [[ "$BUILD_SCOPE" == "full" ]]; then
  echo ""
  echo ">>> [Phase A] Extracting K90 stock vbmeta & displayconfig..."
  mkdir -p "$WORK_ROOT/k90_tmp" "$WORK_ROOT/k90_mnt"

  bash "$REPO_ROOT/scripts/01_fetch_rom.sh" "$BASE_ROM_URL" "$WORK_ROOT/k90_base.tgz"

  # Extract ONLY super.img, vbmeta.img, vbmeta_system.img to minimize disk usage
  tar -tzf "$WORK_ROOT/k90_base.tgz" > "$WORK_ROOT/k90_tar_list.txt"
  K90_MEMBERS=()
  for want in "images/vbmeta.img" "images/vbmeta_system.img" "images/super.img"; do
    m="$(grep -E "(^|/)${want}$" "$WORK_ROOT/k90_tar_list.txt" | head -n 1 || true)"
    if [[ -z "$m" ]]; then
      echo "[FATAL] Required member $want not found in K90 base archive"
      exit 1
    fi
    K90_MEMBERS+=("$m")
  done

  echo "[K90] Extracting ${#K90_MEMBERS[@]} files from .tgz..."
  tar -xzf "$WORK_ROOT/k90_base.tgz" -C "$WORK_ROOT/k90_tmp" "${K90_MEMBERS[@]}"
  rm -f "$WORK_ROOT/k90_base.tgz" "$WORK_ROOT/k90_tar_list.txt"

  K90_IMG_DIR="$(dirname "$(find "$WORK_ROOT/k90_tmp" -name 'super.img' | head -n 1)")"
  cp "$K90_IMG_DIR/vbmeta.img" "$OUT_DIR/vbmeta.img"
  cp "$K90_IMG_DIR/vbmeta_system.img" "$OUT_DIR/vbmeta_system.img"
  echo "[K90] Copied vbmeta.img & vbmeta_system.img"

  echo "[K90] Converting super.img -> super_raw.img & unpacking product_a,vendor_a,odm_a,system_a,system_ext_a for displayconfig + SEPolicy gate..."
  simg2img "$K90_IMG_DIR/super.img" "$WORK_ROOT/k90_super_raw.img"
  rm -rf "$WORK_ROOT/k90_tmp"

  python3 "$REPO_ROOT/scripts/lp_tools.py" dump "$WORK_ROOT/k90_super_raw.img" > "$REPORT_DIR/k90_super_layout.txt"
  python3 "$REPO_ROOT/scripts/lp_tools.py" unpack "$WORK_ROOT/k90_super_raw.img" "$WORK_ROOT/k90_parts" "product_a,vendor_a,odm_a,system_a,system_ext_a"
  rm -f "$WORK_ROOT/k90_super_raw.img"

  mkdir -p "$WORK_ROOT/k90_sepolicy" "$WORK_ROOT/k90_assets"

  # Extract K90 product displayconfig + product SELinux CILs
  mount_erofs_ro "$WORK_ROOT/k90_parts/product_a.img" "$WORK_ROOT/k90_mnt/product"
  if sudo test -f "$WORK_ROOT/k90_mnt/product/$K90_PRODUCT_DISPLAYCONFIG"; then
    sudo cp "$WORK_ROOT/k90_mnt/product/$K90_PRODUCT_DISPLAYCONFIG" "$WORK_ROOT/k90_assets/$(basename "$K90_PRODUCT_DISPLAYCONFIG")"
    sudo chown "$(id -u):$(id -g)" "$WORK_ROOT/k90_assets/$(basename "$K90_PRODUCT_DISPLAYCONFIG")"
    K90_EXTRACTED_DC="$WORK_ROOT/k90_assets/$(basename "$K90_PRODUCT_DISPLAYCONFIG")"
    echo "[K90] Extracted displayconfig: $K90_PRODUCT_DISPLAYCONFIG"
  else
    echo "[WARN] Expected K90 displayconfig not found: $K90_PRODUCT_DISPLAYCONFIG"
  fi
  if sudo test -d "$WORK_ROOT/k90_mnt/product/etc/selinux"; then
    sudo cp -r "$WORK_ROOT/k90_mnt/product/etc/selinux" "$WORK_ROOT/k90_sepolicy/product"
  fi
  # K90 product 的 VINTF/SEPolicy 持久档（用于替换 OriginOS product 的同名目录，
  # 保持 CIL 文件集合与 precompiled_sepolicy 的 sha256 侧文件完全一致）
  for sub in vintf selinux; do
    if sudo test -d "$WORK_ROOT/k90_mnt/product/etc/$sub"; then
      sudo rm -rf "$WORK_ROOT/k90_assets/product_$sub"
      sudo cp -a "$WORK_ROOT/k90_mnt/product/etc/$sub" "$WORK_ROOT/k90_assets/product_$sub"
      echo "[K90] Persisted product/etc/$sub for base alignment"
    fi
  done
  # Product build.prop → 用于 device identity 伪装（ro.product.product.* 是
  # property_source_order 的首选来源，决定最终 ro.product.device/model/name）
  if sudo test -f "$WORK_ROOT/k90_mnt/product/build.prop"; then
    sudo cp "$WORK_ROOT/k90_mnt/product/build.prop" "$WORK_ROOT/k90_assets/k90_product_build.prop"
    echo "[K90] Persisted product/build.prop for device identity masking"
  fi
  umount_erofs "$WORK_ROOT/k90_mnt/product"
  rm -f "$WORK_ROOT/k90_parts/product_a.img"

  # Extract K90 vendor/odm/system/system_ext SELinux CILs (< 5 MB total) for real secilc pre-flight gate!
  for kp in vendor odm system system_ext; do
    if [[ -f "$WORK_ROOT/k90_parts/${kp}_a.img" ]]; then
      mount_erofs_ro "$WORK_ROOT/k90_parts/${kp}_a.img" "$WORK_ROOT/k90_mnt/$kp"
      if [[ "$kp" == "system" ]] && sudo test -d "$WORK_ROOT/k90_mnt/$kp/system/etc/selinux"; then
        sudo cp -r "$WORK_ROOT/k90_mnt/$kp/system/etc/selinux" "$WORK_ROOT/k90_sepolicy/$kp"
      elif sudo test -d "$WORK_ROOT/k90_mnt/$kp/etc/selinux"; then
        sudo cp -r "$WORK_ROOT/k90_mnt/$kp/etc/selinux" "$WORK_ROOT/k90_sepolicy/$kp"
      fi
      # K90 stock framework VINTF + SEPolicy → 持久档（不随 k90_sepolicy 删除），
      # 供 Phase C 的 K90-BASE ALIGNMENT 覆盖外来 system 使用。
      if [[ "$kp" == "system" ]]; then
        for sub in vintf selinux; do
          if sudo test -d "$WORK_ROOT/k90_mnt/$kp/system/etc/$sub"; then
            sudo rm -rf "$WORK_ROOT/k90_assets/$sub"
            sudo cp -a "$WORK_ROOT/k90_mnt/$kp/system/etc/$sub" "$WORK_ROOT/k90_assets/$sub"
            echo "[K90] Persisted system/etc/$sub ($(sudo du -sh "$WORK_ROOT/k90_mnt/$kp/system/etc/$sub" | awk '{print $1}')) for base alignment"
          else
            echo "[WARN] K90 stock system/etc/$sub not found — base alignment may be incomplete"
          fi
        done
      fi
      if [[ "$kp" == "system_ext" ]]; then
        for sub in vintf selinux; do
          if sudo test -d "$WORK_ROOT/k90_mnt/$kp/etc/$sub"; then
            sudo rm -rf "$WORK_ROOT/k90_assets/system_ext_$sub"
            sudo cp -a "$WORK_ROOT/k90_mnt/$kp/etc/$sub" "$WORK_ROOT/k90_assets/system_ext_$sub"
            echo "[K90] Persisted system_ext/etc/$sub for base alignment"
          fi
        done
      fi
      umount_erofs "$WORK_ROOT/k90_mnt/$kp"
      rm -f "$WORK_ROOT/k90_parts/${kp}_a.img"
    fi
  done
  sudo chown -R "$(id -u):$(id -g)" "$WORK_ROOT/k90_sepolicy" "$WORK_ROOT/k90_assets"
  echo "[K90] Extracted SEPolicy CIL trees for secilc pre-flight verification."

  rm -rf "$WORK_ROOT/k90_parts" "$WORK_ROOT/k90_mnt"
  echo "[K90] Phase A complete. Free disk:"
  df -h "$WORK_ROOT"
else
  echo ""
  echo ">>> [Phase A] Skipped (build_scope=system_only)"
fi

# ------------------------------------------------------------------------------
# PHASE B: Fetch & Unpack iQOO Neo 11 OriginOS 7 Partitions + oem + vgc
# ------------------------------------------------------------------------------
echo ""
echo ">>> [Phase B] Fetching & extracting Neo 11 OriginOS 7..."
bash "$REPO_ROOT/scripts/01_fetch_rom.sh" "$PORT_ROM_SOURCE" "$WORK_ROOT/neo11_port.zip"

mkdir -p "$WORK_ROOT/neo11_unzip" "$WORK_ROOT/neo11_parts" "$WORK_ROOT/neo11_oem_vgc"
unzip -o -j "$WORK_ROOT/neo11_port.zip" "payload.bin" -d "$WORK_ROOT/neo11_unzip"
unzip -o -j "$WORK_ROOT/neo11_port.zip" "META-INF/com/android/metadata" -d "$REPORT_DIR" 2>/dev/null || true
unzip -o "$WORK_ROOT/neo11_port.zip" "oem_zip/*" -d "$WORK_ROOT/neo11_oem_vgc" || true
rm -f "$WORK_ROOT/neo11_port.zip"

if [[ "$BUILD_SCOPE" == "full" ]]; then
  DUMP_PARTS="system,system_ext,product"
else
  DUMP_PARTS="system"
fi

echo "[Neo11] Extracting partitions ($DUMP_PARTS) via payload-dumper-go..."
payload-dumper-go -c 4 -p "$DUMP_PARTS" -o "$WORK_ROOT/neo11_parts" "$WORK_ROOT/neo11_unzip/payload.bin"
rm -rf "$WORK_ROOT/neo11_unzip"

# Extract nested vgc.img & oem.img payloads
VGC_ZIP="$(find "$WORK_ROOT/neo11_oem_vgc" -maxdepth 3 -name 'vgc_*.zip' | head -n 1 || true)"
OEM_ZIP="$(find "$WORK_ROOT/neo11_oem_vgc" -maxdepth 3 -name 'oem_*.zip' | head -n 1 || true)"
[[ -n "$VGC_ZIP" ]] || { echo "[FATAL] vgc_*.zip not found inside oem_zip/"; exit 1; }
[[ -n "$OEM_ZIP" ]] || { echo "[FATAL] oem_*.zip not found inside oem_zip/"; exit 1; }

mkdir -p "$WORK_ROOT/neo11_vgc_raw" "$WORK_ROOT/neo11_oem_raw"
unzip -o -j "$VGC_ZIP" "payload.bin" -d "$WORK_ROOT/neo11_vgc_raw"
payload-dumper-go -c 2 -p vgc -o "$WORK_ROOT/neo11_vgc_raw/parts" "$WORK_ROOT/neo11_vgc_raw/payload.bin"
rm -f "$WORK_ROOT/neo11_vgc_raw/payload.bin"

unzip -o -j "$OEM_ZIP" "payload.bin" -d "$WORK_ROOT/neo11_oem_raw"
payload-dumper-go -c 2 -p oem -o "$WORK_ROOT/neo11_oem_raw/parts" "$WORK_ROOT/neo11_oem_raw/payload.bin"
rm -f "$WORK_ROOT/neo11_oem_raw/payload.bin"
rm -rf "$WORK_ROOT/neo11_oem_vgc"

VGC_IMG="$(find "$WORK_ROOT/neo11_vgc_raw/parts" -name 'vgc.img' | head -n 1 || true)"
if [[ -z "$VGC_IMG" ]]; then
  VGC_IMG="$(find "$WORK_ROOT/neo11_vgc_raw/parts" -name '*.img' ! -name 'vbmeta*' | head -n 1 || true)"
fi
OEM_IMG="$(find "$WORK_ROOT/neo11_oem_raw/parts" -name 'oem.img' | head -n 1 || true)"
if [[ -z "$OEM_IMG" ]]; then
  OEM_IMG="$(find "$WORK_ROOT/neo11_oem_raw/parts" -name '*.img' ! -name 'vbmeta*' | head -n 1 || true)"
fi
[[ -n "$VGC_IMG" && -f "$VGC_IMG" ]] || { echo "[FATAL] vgc.img not found in neo11_vgc_raw/parts!"; ls -la "$WORK_ROOT/neo11_vgc_raw/parts"; exit 1; }
[[ -n "$OEM_IMG" && -f "$OEM_IMG" ]] || { echo "[FATAL] oem.img not found in neo11_oem_raw/parts!"; ls -la "$WORK_ROOT/neo11_oem_raw/parts"; exit 1; }
echo "[Neo11] Nested images ready: vgc=$(basename "$VGC_IMG") ($(du -h "$VGC_IMG" | awk '{print $1}')), oem=$(basename "$OEM_IMG") ($(du -h "$OEM_IMG" | awk '{print $1}'))"
file "$VGC_IMG" "$OEM_IMG" || true
df -h "$WORK_ROOT"

# ------------------------------------------------------------------------------
# PHASE C: Stage, Inspect, Debloat, Inject /oem & /vgc, Patch Props & Pack system
# ------------------------------------------------------------------------------
echo ""
echo ">>> [Phase C] Staging & patching system.img..."
MNT_SYS="$WORK_ROOT/mnt/neo11_system"
MNT_VGC="$WORK_ROOT/mnt/neo11_vgc"
MNT_OEM="$WORK_ROOT/mnt/neo11_oem"
STAGE_SYS="$WORK_ROOT/stage/system"

mount_erofs_ro "$WORK_ROOT/neo11_parts/system.img" "$MNT_SYS"
mount_erofs_ro "$VGC_IMG" "$MNT_VGC"
mount_erofs_ro "$OEM_IMG" "$MNT_OEM"

# Capture useful diagnostic logs for Stage 3 tuning
echo "[Diag] Recording /system/custom/app & vivo init.rc contents into build report..."
{
  echo "=== /system/custom/app ==="
  sudo find "$MNT_SYS/system/custom/app" -mindepth 1 -maxdepth 1 -exec du -sm {} + 2>/dev/null | sort -rn || true
  echo ""
  echo "=== /system/custom/priv-app ==="
  sudo find "$MNT_SYS/system/custom/priv-app" -mindepth 1 -maxdepth 1 -exec du -sm {} + 2>/dev/null | sort -rn || true
} > "$REPORT_DIR/neo11_custom_apps.txt"

{
  for rc in \
    gppservice.rc dcdiming.rc blank_screen.rc init.touch.fw.rc vspr.rc \
    vivocameraserver.rc vivonrtservice.rc vivoperfservice.rc \
    vendor.vivo.hardware.nativecamera.provider@1.0-service.rc \
    vendor.vivo.hardware.camera.cameralog@1.0-service.rc \
    vendor.factory.hardware.vivoatcmd-service.rc \
    customcenter.rc roundphone.rc; do
    if sudo test -f "$MNT_SYS/system/etc/init/$rc"; then
      echo "### $rc ###"
      sudo cat "$MNT_SYS/system/etc/init/$rc"
      echo ""
    fi
  done
} > "$REPORT_DIR/neo11_vivo_init_rc_dump.txt"

# Record original xattrs on vgc & oem root/props
{
  echo "=== VGC/OEM original SELinux xattrs ==="
  sudo python3 - "$MNT_VGC" "$MNT_OEM" <<'PYEOF'
import os, sys
for root in sys.argv[1:]:
    print("---", root)
    for cur, dirs, files in os.walk(root):
        for p in [cur] + [os.path.join(cur, f) for f in files[:5]]:
            try:
                se = os.getxattr(p, "security.selinux", follow_symlinks=False).rstrip(b"\x00").decode()
            except Exception as e:
                se = f"ERR:{e}"
            print(f"  {os.path.relpath(p, root)} -> {se}")
        break
PYEOF
} > "$REPORT_DIR/vgc_oem_orig_xattrs.txt"

# Lossless copy of entire SAR system partition (preserving UID/GID/mode/SELinux/caps)
sudo rm -rf "$STAGE_SYS"
sudo python3 "$REPO_ROOT/scripts/erofs_repack.py" copy "$MNT_SYS" "$STAGE_SYS"

# Immediately unmount and delete source system.img to reclaim 10 GB disk!
umount_erofs "$MNT_SYS"
rm -f "$WORK_ROOT/neo11_parts/system.img"

# --- C1. Apply config/remove_list.txt ([system] section) ---
echo "[Patch] Applying debloat & conflict removal list ([system])..."
REMOVED_LOG="$REPORT_DIR/removed_items.txt"
: > "$REMOVED_LOG"
apply_remove_list "system" "$STAGE_SYS" "$REMOVED_LOG"

# --- C2. Populate /vgc inside SAR system root ---
echo "[Patch] Injecting Neo 11 /vgc into SAR system root (selinux=u:object_r:system_file:s0)..."
sudo mkdir -p "$STAGE_SYS/vgc"
sudo python3 "$REPO_ROOT/scripts/erofs_repack.py" copy "$MNT_VGC" "$STAGE_SYS/vgc" --override-selinux "u:object_r:system_file:s0"
umount_erofs "$MNT_VGC"
rm -rf "$WORK_ROOT/neo11_vgc_raw"

# --- C3. Populate /oem inside SAR system root (retail China variant flattened) ---
echo "[Patch] Injecting Neo 11 /oem (variant=$VIVO_OEM_VARIANT) into SAR system root..."
if sudo test -L "$STAGE_SYS/oem"; then
  sudo rm -f "$STAGE_SYS/oem"
fi
sudo mkdir -p "$STAGE_SYS/oem"
sudo chown 0:0 "$STAGE_SYS/oem"
sudo chmod 0755 "$STAGE_SYS/oem"
sudo python3 -c 'import os,sys; os.setxattr(sys.argv[1],"security.selinux",b"u:object_r:system_file:s0\x00")' "$STAGE_SYS/oem"
if sudo test -d "$MNT_OEM/etc"; then
  sudo python3 "$REPO_ROOT/scripts/erofs_repack.py" copy "$MNT_OEM/etc" "$STAGE_SYS/oem/etc" --override-selinux "u:object_r:system_file:s0"
fi
if sudo test -d "$MNT_OEM/$VIVO_OEM_VARIANT"; then
  sudo python3 "$REPO_ROOT/scripts/erofs_repack.py" copy "$MNT_OEM/$VIVO_OEM_VARIANT" "$STAGE_SYS/oem/$VIVO_OEM_VARIANT" --override-selinux "u:object_r:system_file:s0"
else
  echo "[FATAL] OEM variant directory not found in oem.img: $VIVO_OEM_VARIANT"
  exit 1
fi

# Flatten base oem.prop + variant oem.prop into /oem/oem.prop so init's `import /oem/oem.prop`
# loads all retail China OriginOS 7 identity/region properties natively!
sudo rm -f "$STAGE_SYS/oem/oem.prop"
sudo python3 - "$MNT_OEM/oem.prop" "$MNT_OEM/$VIVO_OEM_VARIANT/oem.prop" "$STAGE_SYS/oem/oem.prop" "$VIVO_OEM_VARIANT" <<'PYEOF'
import os, sys

base_p, var_p, out_p, var_name = sys.argv[1:5]
kv = {}
order = []

def load(path):
    if not os.path.isfile(path):
        return
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            s = raw.strip()
            if not s or s.startswith("#") or "=" not in s:
                continue
            k, v = s.split("=", 1)
            k, v = k.strip(), v.strip()
            if k not in kv:
                order.append(k)
            kv[k] = v

load(base_p)
load(var_p)
if "ro.vivo.default.oem.name" not in kv:
    order.append("ro.vivo.default.oem.name")
kv["ro.vivo.default.oem.name"] = var_name

with open(out_p, "w", encoding="utf-8") as f:
    f.write(f"# Flattened /oem/oem.prop for REDMI K90 OriginOS 7 Port ({var_name})\n")
    for k in order:
        f.write(f"{k}={kv[k]}\n")

os.chown(out_p, 0, 0)
os.chmod(out_p, 0o644)
os.setxattr(out_p, "security.selinux", b"u:object_r:system_file:s0\x00", follow_symlinks=False)
print(f"[OK] Wrote flattened {out_p} ({len(order)} properties)")
PYEOF

umount_erofs "$MNT_OEM"
rm -rf "$WORK_ROOT/neo11_oem_raw"

# --- C4. Patch /system/build.prop (and /system/etc/prop.default if present) ---
echo "[Patch] Patching system/system/build.prop..."
PATCH_ARGS=(--prop "$STAGE_SYS/system/build.prop" --config "$REPO_ROOT/config/prop_override.conf")
if [[ "$DEBUG_ADB" == "true" ]]; then
  PATCH_ARGS+=(--debug-adb)
fi
sudo python3 "$REPO_ROOT/scripts/patch_props.py" "${PATCH_ARGS[@]}"

if [[ "$DEBUG_ADB" == "true" ]] && sudo test -f "$STAGE_SYS/system/etc/prop.default" && ! sudo test -L "$STAGE_SYS/system/etc/prop.default"; then
  echo "[Patch] Also overriding ADB debug keys inside system/system/etc/prop.default..."
  sudo python3 - "$STAGE_SYS/system/etc/prop.default" <<'PYEOF'
import os, sys

p = sys.argv[1]
overrides = {
    "ro.adb.secure": "0",
    "ro.debuggable": "1",
    "ro.force.debuggable": "1",
    "persist.sys.usb.config": "mtp,adb",
}
st = os.lstat(p)
xa = {}
try:
    for k in os.listxattr(p, follow_symlinks=False):
        xa[k] = os.getxattr(p, k, follow_symlinks=False)
except OSError:
    pass

with open(p, "r", encoding="utf-8", errors="surrogateescape") as f:
    lines = f.readlines()

out = []
seen = set()
for line in lines:
    s = line.strip()
    if s and not s.startswith("#") and "=" in s:
        k = s.split("=", 1)[0].strip()
        if k in overrides:
            if k not in seen:
                out.append(f"{k}={overrides[k]}\n")
                seen.add(k)
            continue
    out.append(line)

with open(p, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.writelines(out)

os.chown(p, st.st_uid, st.st_gid)
os.chmod(p, st.st_mode & 0o7777)
for k, v in xa.items():
    os.setxattr(p, k, v, follow_symlinks=False)
print(f"[OK] Updated prop.default keys: {sorted(seen)}")
PYEOF
fi

# Optional pre-authorized ADB public key (belt-and-suspenders for v1 logcat)
# NOTE: In SAR system.img, /adb_keys is often a pre-existing dangling symlink (e.g. -> /data/misc/adb/adb_keys),
# so we MUST unlink any symlink first before writing regular files!
if [[ -n "${ADB_PUBLIC_KEY:-}" ]]; then
  echo "[Patch] Baking pre-authorized ADB public key into /adb_keys & /system/etc/security/adb_keys..."
  sudo mkdir -p "$STAGE_SYS/system/etc/security"
  sudo rm -f "$STAGE_SYS/adb_keys" "$STAGE_SYS/system/etc/security/adb_keys"
  printf '%s\n' "${ADB_PUBLIC_KEY//$'\r'/}" | sudo tee "$STAGE_SYS/adb_keys" "$STAGE_SYS/system/etc/security/adb_keys" >/dev/null
  sudo chown 0:0 "$STAGE_SYS/adb_keys" "$STAGE_SYS/system/etc/security/adb_keys"
  sudo chmod 0644 "$STAGE_SYS/adb_keys" "$STAGE_SYS/system/etc/security/adb_keys"
  sudo python3 -c 'import os,sys; os.setxattr(sys.argv[1],"security.selinux",b"u:object_r:adb_keys_file:s0\x00")' "$STAGE_SYS/adb_keys"
  sudo python3 -c 'import os,sys; os.setxattr(sys.argv[1],"security.selinux",b"u:object_r:system_file:s0\x00")' "$STAGE_SYS/system/etc/security/adb_keys"
fi

# Audit critical/reboot/mount init.rc rules (including /vgc/vgc.rc & securemount.rc)
{
  echo "=== Services marked critical / reboot in /system/etc/init ==="
  sudo grep -rnE '^\s*(critical|reboot|mount )' "$STAGE_SYS/system/etc/init/" 2>/dev/null || true
  echo ""
  echo "=== /system/etc/init/securemount.rc ==="
  sudo cat "$STAGE_SYS/system/etc/init/securemount.rc" 2>/dev/null || true
  echo ""
  echo "=== /vgc/vgc.rc ==="
  sudo cat "$STAGE_SYS/vgc/vgc.rc" 2>/dev/null || true
} > "$REPORT_DIR/neo11_critical_rc_audit.txt"

# --- C4.4. Apply optional pinned SEPolicy shims (works in BOTH full & system_only modes!) ---
if [[ -f "$REPO_ROOT/config/sepolicy_shims.cil" ]]; then
  SHIM_DST="$STAGE_SYS/system/etc/selinux/mapping/202404.cil"
  if sudo test -f "$SHIM_DST"; then
    echo "[SEPolicy] Applying pinned shims from config/sepolicy_shims.cil -> mapping/202404.cil..."
    sudo python3 - "$SHIM_DST" "$REPO_ROOT/config/sepolicy_shims.cil" <<'PYEOF'
import os, sys
dst, src = sys.argv[1:3]
st = os.lstat(dst)
xa = {k: os.getxattr(dst, k, follow_symlinks=False) for k in os.listxattr(dst, follow_symlinks=False)}
with open(src, "r", encoding="utf-8") as sf:
    extra = sf.read().strip()
if extra:
    with open(dst, "a", encoding="utf-8") as df:
        df.write("\n;; === Pinned K90 SEPolicy Shims (config/sepolicy_shims.cil) ===\n")
        df.write(extra + "\n")
    os.chown(dst, st.st_uid, st.st_gid)
    os.chmod(dst, st.st_mode & 0o7777)
    for k, v in xa.items():
        os.setxattr(dst, k, v, follow_symlinks=False)
    print(f"[OK] Appended pinned shims to {dst}")
PYEOF
  fi
fi

# --- C4.5. REAL secilc Split SEPolicy Pre-Flight Gate (Neo 11 FW + K90 Vendor/ODM) ---
if [[ -d "$WORK_ROOT/k90_sepolicy/vendor" ]]; then
  echo ""
  echo ">>> [SEPolicy Gate] Running real secilc on Neo 11 (system+ext+product) + K90 (vendor+odm)..."
  mkdir -p "$WORK_ROOT/neo11_sepolicy"
  if [[ -f "$WORK_ROOT/neo11_parts/system_ext.img" ]]; then
    mount_erofs_ro "$WORK_ROOT/neo11_parts/system_ext.img" "$WORK_ROOT/mnt/neo11_ext_se"
    if sudo test -d "$WORK_ROOT/mnt/neo11_ext_se/etc/selinux"; then
      sudo cp -r "$WORK_ROOT/mnt/neo11_ext_se/etc/selinux" "$WORK_ROOT/neo11_sepolicy/system_ext"
    fi
    umount_erofs "$WORK_ROOT/mnt/neo11_ext_se"
  fi
  if [[ -f "$WORK_ROOT/neo11_parts/product.img" ]]; then
    mount_erofs_ro "$WORK_ROOT/neo11_parts/product.img" "$WORK_ROOT/mnt/neo11_prod_se"
    if sudo test -d "$WORK_ROOT/mnt/neo11_prod_se/etc/selinux"; then
      sudo cp -r "$WORK_ROOT/mnt/neo11_prod_se/etc/selinux" "$WORK_ROOT/neo11_sepolicy/product"
    fi
    umount_erofs "$WORK_ROOT/mnt/neo11_prod_se"
  fi

  sudo python3 "$REPO_ROOT/scripts/check_sepolicy.py" \
    --sys-se "$STAGE_SYS/system/etc/selinux" \
    --ext-se "$WORK_ROOT/neo11_sepolicy/system_ext" \
    --prod-se "$WORK_ROOT/neo11_sepolicy/product" \
    --vnd-se "$WORK_ROOT/k90_sepolicy/vendor" \
    --odm-se "$WORK_ROOT/k90_sepolicy/odm" \
    --k90-fw-se "$WORK_ROOT/k90_sepolicy/system" \
    --k90-fw-se "$WORK_ROOT/k90_sepolicy/system_ext" \
    --k90-fw-se "$WORK_ROOT/k90_sepolicy/product" \
    --report "$REPORT_DIR/sepolicy_check.txt"
  sudo rm -rf "$WORK_ROOT/neo11_sepolicy" "$WORK_ROOT/k90_sepolicy"
else
  echo "[WARN] Skipping live secilc check (system_only mode has no K90 vendor/odm CILs). Ensure any required shims from full build are pinned in config/sepolicy_shims.cil!"
fi

# --- C4.6. K90-BASE ALIGNMENT: 把 framework VINTF / SEPolicy 换回 K90 原厂 ---
# 依据：这两个东西描述的是 vendor 侧的形状，必须与 vendor 同源。混用外来 system 的
# 矩阵+策略，必然出现：system_server CheckCompatibility FATAL；或 init 在
# selinux_android_load_policy() 失败后 Freeze() 死循环（卡 logo / 无 kmsg / 无 panic）。
ALIGN_LOG="$REPORT_DIR/k90_base_alignment.txt"
{
  echo "=== K90 base alignment ==="
  echo "ALIGN_K90_BASE    = $ALIGN_K90_BASE"
  echo "ALIGN_K90_VINTF   = $ALIGN_K90_VINTF"
  echo "ALIGN_K90_SELINUX = $ALIGN_K90_SELINUX"
  echo "MASK_DEVICE       = $MASK_DEVICE"
  echo ""
  echo "NOTE: sepolicy_check.txt 里的跨厂 secilc 合编结果仅供诊断参考。"
  echo "      最终部署到镜像的是 K90 原厂策略组合（plat/vendor/odm/system_ext/product 同源），"
  echo "      这样 precompiled_sepolicy 的 sha256 侧文件才能全部命中，init 不会 fallback 到运行时编译。"
  echo ""
} > "$ALIGN_LOG"

if [[ "$ALIGN_K90_VINTF" == "true" ]]; then
  if sudo test -d "$WORK_ROOT/k90_assets/vintf"; then
    echo ">>> [Align][VINTF] Replacing foreign system/etc/vintf with K90 stock..."
    sudo rm -rf "$STAGE_SYS/system/etc/vintf"
    sudo cp -a "$WORK_ROOT/k90_assets/vintf" "$STAGE_SYS/system/etc/vintf"
    # 注：system_ext / product 属于独立分区，其 etc/vintf 的清理分别在 Phase D2 / Phase D 处理
    echo "[Align][VINTF] Deployed K90 stock vintf:" | tee -a "$ALIGN_LOG"
    sudo find "$STAGE_SYS/system/etc/vintf" -maxdepth 2 -type f | sed "s|$STAGE_SYS/||" | sort | tee -a "$ALIGN_LOG"
  else
    echo "[FATAL] ALIGN_K90_VINTF=true but $WORK_ROOT/k90_assets/vintf missing." | tee -a "$ALIGN_LOG"
    echo "        Run with build_scope=full once, or set ALIGN_K90_BASE=selinux|none." | tee -a "$ALIGN_LOG"
    exit 1
  fi
fi

if [[ "$ALIGN_K90_SELINUX" == "true" ]]; then
  if sudo test -d "$WORK_ROOT/k90_assets/selinux"; then
    echo ">>> [Align][SELinux] Replacing foreign system/etc/selinux with K90 stock..."
    sudo rm -rf "$STAGE_SYS/system/etc/selinux"
    sudo cp -a "$WORK_ROOT/k90_assets/selinux" "$STAGE_SYS/system/etc/selinux"
    # 注：system_ext / product 的 etc/selinux 属于独立分区，清理见 Phase D2 / Phase D
    echo "[Align][SELinux] Deployed K90 stock selinux:" | tee -a "$ALIGN_LOG"
    sudo find "$STAGE_SYS/system/etc/selinux" -maxdepth 2 -type f | sed "s|$STAGE_SYS/||" | sort | tee -a "$ALIGN_LOG"
    if sudo test -f "$STAGE_SYS/system/etc/selinux/plat_sepolicy_vers.txt"; then
      echo "[Align][SELinux] plat_sepolicy_vers = $(sudo cat "$STAGE_SYS/system/etc/selinux/plat_sepolicy_vers.txt")" | tee -a "$ALIGN_LOG"
    fi
    if sudo test -f "$STAGE_SYS/system/etc/selinux/mapping/202404.cil"; then
      echo "[Align][SELinux] mapping/202404.cil present (matches K90 vendor)" | tee -a "$ALIGN_LOG"
    fi
  else
    echo "[FATAL] ALIGN_K90_SELINUX=true but $WORK_ROOT/k90_assets/selinux missing." | tee -a "$ALIGN_LOG"
    echo "        Run with build_scope=full once, or set ALIGN_K90_BASE=vintf|none." | tee -a "$ALIGN_LOG"
    exit 1
  fi
fi

# Save final patched props snapshot to report
sudo cp "$STAGE_SYS/system/build.prop" "$REPORT_DIR/patched_system_build.prop"
sudo cp "$STAGE_SYS/oem/oem.prop" "$REPORT_DIR/patched_oem.prop"
sudo cp "$STAGE_SYS/vgc/vgc.prop" "$REPORT_DIR/patched_vgc.prop"

# Ensure 100% SELinux labeling across staging tree
sudo python3 "$REPO_ROOT/scripts/erofs_repack.py" fixup "$STAGE_SYS" --default-selinux "u:object_r:system_file:s0"

# --- C5. Repack & Verify system.img ---
echo "[Pack] Repacking system.img with mkfs.erofs -z$EROFS_COMPRESS..."
sudo rm -f "$OUT_DIR/system.img"
sudo mkfs.erofs -z"$EROFS_COMPRESS" -T "$EROFS_TIMESTAMP" "$OUT_DIR/system.img" "$STAGE_SYS"
sudo rm -rf "$STAGE_SYS"

echo "[Verify] Mounting & checking repacked system.img..."
sudo python3 "$REPO_ROOT/scripts/erofs_repack.py" verify "$OUT_DIR/system.img" \
  --expect-file "system/build.prop" \
  --expect-file "system/bin/init" \
  --expect-file "system/bin/surfaceflinger" \
  --expect-file "oem/oem.prop" \
  --expect-file "vgc/vgc.prop" \
  --min-selinux-ratio 0.999 | tee "$REPORT_DIR/verify_system.txt"

# ------------------------------------------------------------------------------
# PHASE D: Patch product.img, passthrough system_ext.img, create empty mi_ext/mi_product
# ------------------------------------------------------------------------------
if [[ "$BUILD_SCOPE" == "full" ]]; then
  echo ""
  echo ">>> [Phase D] Staging & patching product.img..."
  MNT_PROD="$WORK_ROOT/mnt/neo11_product"
  STAGE_PROD="$WORK_ROOT/stage/product"

  mount_erofs_ro "$WORK_ROOT/neo11_parts/product.img" "$MNT_PROD"
  sudo rm -rf "$STAGE_PROD"
  sudo python3 "$REPO_ROOT/scripts/erofs_repack.py" copy "$MNT_PROD" "$STAGE_PROD"
  umount_erofs "$MNT_PROD"
  rm -f "$WORK_ROOT/neo11_parts/product.img"

  apply_remove_list "product" "$STAGE_PROD" "$REMOVED_LOG"

  # --- D1a. product 侧外来 VINTF/SEPolicy 换成 K90 原厂 ---
  # init 会同时读取 /system、/system_ext、/product、/vendor 的 etc/{vintf,selinux}。
  # 这里选择"替换"而不是"删除"：K90 的 precompiled_sepolicy 配套了一组
  # *_sepolicy.cil.sha256 侧文件，文件集合必须与底包完全一致才会被直接采用；
  # 一旦缺文件，libselinux 会 fallback 到运行时 secilc，失败即 init Freeze()。
  if [[ "$ALIGN_K90_VINTF" == "true" ]]; then
    if sudo test -d "$WORK_ROOT/k90_assets/product_vintf"; then
      sudo rm -rf "$STAGE_PROD/etc/vintf"
      sudo cp -a "$WORK_ROOT/k90_assets/product_vintf" "$STAGE_PROD/etc/vintf"
      echo "[Align][VINTF] product/etc/vintf <- K90 stock" | tee -a "$ALIGN_LOG"
    else
      while IFS= read -r f; do
        sudo rm -f "$f"
        echo "[Align][VINTF] Removed foreign device matrix: product/${f#$STAGE_PROD/}" | tee -a "$ALIGN_LOG"
      done < <(sudo find "$STAGE_PROD/etc/vintf" -maxdepth 1 -type f -name '*device*.xml' 2>/dev/null || true)
    fi
  fi
  if [[ "$ALIGN_K90_SELINUX" == "true" ]]; then
    if sudo test -d "$WORK_ROOT/k90_assets/product_selinux"; then
      sudo rm -rf "$STAGE_PROD/etc/selinux"
      sudo cp -a "$WORK_ROOT/k90_assets/product_selinux" "$STAGE_PROD/etc/selinux"
      echo "[Align][SELinux] product/etc/selinux <- K90 stock" | tee -a "$ALIGN_LOG"
    elif sudo test -d "$STAGE_PROD/etc/selinux"; then
      sudo rm -rf "$STAGE_PROD/etc/selinux"
      echo "[Align][SELinux] Removed foreign CIL tree: product/etc/selinux" | tee -a "$ALIGN_LOG"
    fi
  fi

  # --- D1b. Device identity masking: 让 ro.product.product.* 报告 K90 (annibale) ---
  # init 的 property_source_order 默认以 product 分区为第一来源，vivo 的 product
  # build.prop 会把 ro.product.device 变成 PD2520，导致 K90 vendor 侧按设备名
  # 查找的显示/触控/热配置全部落空。
  if [[ "$MASK_DEVICE" != "none" ]] && sudo test -f "$STAGE_PROD/build.prop"; then
    echo ">>> [Align][Device] Masking product/build.prop as $MASK_DEVICE..."
    sudo python3 - "$WORK_ROOT/k90_assets/k90_product_build.prop" \
      "$STAGE_PROD/build.prop" "$MASK_DEVICE" "$DEVICE_MARKETNAME" <<'PYEOF' | tee -a "$ALIGN_LOG"
import os, re, sys

ref_p, dst_p, device, marketname = sys.argv[1:5]
KEYS = [
    "ro.product.product.device",
    "ro.product.product.name",
    "ro.product.product.model",
    "ro.product.product.brand",
    "ro.product.product.manufacturer",
]
FALLBACK = {
    "ro.product.product.device": device,
    "ro.product.product.name": device if device != "annibale" else "annibale",
    "ro.product.product.model": marketname or device,
    "ro.product.product.brand": "Redmi" if device == "annibale" else device,
    "ro.product.product.manufacturer": "Xiaomi" if device == "annibale" else device,
}

ref = {}
if ref_p and os.path.isfile(ref_p):
    with open(ref_p, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            s = raw.strip()
            if s and not s.startswith("#") and "=" in s:
                k, v = s.split("=", 1)
                ref[k.strip()] = v.strip()

want = {}
for k in KEYS:
    v = ref.get(k) or FALLBACK.get(k)
    if v:
        want[k] = v

if not want:
    print("[Align][Device] nothing to mask")
    sys.exit(0)

st = os.lstat(dst_p)
xa = {}
try:
    for k in os.listxattr(dst_p, follow_symlinks=False):
        xa[k] = os.getxattr(dst_p, k, follow_symlinks=False)
except OSError:
    pass

with open(dst_p, "r", encoding="utf-8", errors="replace") as f:
    lines = f.read().splitlines()

seen = set()
out = []
for raw in lines:
    s = raw.strip()
    if s and not s.startswith("#") and "=" in s:
        k = s.split("=", 1)[0].strip()
        if k in want:
            if k not in seen:
                out.append(f"{k}={want[k]}")
                seen.add(k)
            continue
    out.append(raw)
for k, v in want.items():
    if k not in seen:
        out.append(f"{k}={v}")

with open(dst_p, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
os.chown(dst_p, 0, 0)
os.chmod(dst_p, st.st_mode & 0o7777)
for k, v in xa.items():
    try:
        os.setxattr(dst_p, k, v, follow_symlinks=False)
    except OSError:
        pass
for k, v in want.items():
    print(f"[Align][Device] {k}={v}")
PYEOF
    sudo cp "$STAGE_PROD/build.prop" "$REPORT_DIR/patched_product_build.prop"
  else
    echo "[WARN] MASK_DEVICE=$MASK_DEVICE but product/build.prop not found; skipped"
  fi

  # Ensure /product/vm-system mountpoint exists for K90 vendor/etc/fstab.qcom (vm-bootsys, no 'nofail'!)
  if sudo test -L "$STAGE_PROD/vm-system"; then
    sudo rm -f "$STAGE_PROD/vm-system"
  fi
  if ! sudo test -d "$STAGE_PROD/vm-system"; then
    echo "[Patch] Creating /product/vm-system mountpoint for K90 fstab.qcom..."
    sudo mkdir -p "$STAGE_PROD/vm-system"
    sudo chown 0:0 "$STAGE_PROD/vm-system"
    sudo chmod 0755 "$STAGE_PROD/vm-system"
    sudo python3 -c 'import os,sys; os.setxattr(sys.argv[1],"security.selinux",b"u:object_r:system_file:s0\x00")' "$STAGE_PROD/vm-system"
  fi

  if [[ -n "$K90_EXTRACTED_DC" && -f "$K90_EXTRACTED_DC" ]]; then
    echo "[Patch] Injecting K90 displayconfig XML into product/$K90_PRODUCT_DISPLAYCONFIG..."
    DC_PARENT="$STAGE_PROD/$(dirname "$K90_PRODUCT_DISPLAYCONFIG")"
    if sudo test -L "$DC_PARENT"; then
      sudo rm -f "$DC_PARENT"
    fi
    sudo mkdir -p "$DC_PARENT"
    sudo rm -f "$STAGE_PROD/$K90_PRODUCT_DISPLAYCONFIG"
    sudo cp "$K90_EXTRACTED_DC" "$STAGE_PROD/$K90_PRODUCT_DISPLAYCONFIG"
    sudo chown 0:0 "$STAGE_PROD/$K90_PRODUCT_DISPLAYCONFIG"
    sudo chmod 0644 "$STAGE_PROD/$K90_PRODUCT_DISPLAYCONFIG"
    sudo python3 -c 'import os,sys; os.setxattr(sys.argv[1],"security.selinux",b"u:object_r:system_file:s0\x00")' "$STAGE_PROD/$K90_PRODUCT_DISPLAYCONFIG"
  fi

  sudo python3 "$REPO_ROOT/scripts/erofs_repack.py" fixup "$STAGE_PROD" --default-selinux "u:object_r:system_file:s0"

  echo "[Pack] Repacking product.img with mkfs.erofs -z$EROFS_COMPRESS..."
  sudo rm -f "$OUT_DIR/product.img"
  sudo mkfs.erofs -z"$EROFS_COMPRESS" -T "$EROFS_TIMESTAMP" "$OUT_DIR/product.img" "$STAGE_PROD"
  sudo rm -rf "$STAGE_PROD"

  sudo python3 "$REPO_ROOT/scripts/erofs_repack.py" verify "$OUT_DIR/product.img" \
    --expect-file "etc/build.prop" \
    --expect-file "$K90_PRODUCT_DISPLAYCONFIG" \
    --min-selinux-ratio 0.999 | tee "$REPORT_DIR/verify_product.txt"

  echo ""
  echo ">>> [Phase D2] system_ext.img: 对齐外来 VINTF/SEPolicy..."
  MNT_EXT="$WORK_ROOT/mnt/neo11_system_ext"
  mount_erofs_ro "$WORK_ROOT/neo11_parts/system_ext.img" "$MNT_EXT"
  EXT_ACTION=""
  # 注意：不要用 `find ... | grep -q .`，pipefail 下 grep 提前退出会让 find 收到
  # SIGPIPE（141）从而把整条管道判为失败，导致漏判。这里取首个匹配结果再判空。
  EXT_DEV_XML="$(sudo find "$MNT_EXT/etc/vintf" -maxdepth 1 -type f -name '*device*.xml' 2>/dev/null | head -n 1 || true)"
  if [[ "$ALIGN_K90_VINTF" == "true" ]]; then
    if sudo test -d "$WORK_ROOT/k90_assets/system_ext_vintf"; then
      EXT_ACTION="vintf<-k90"
    elif [[ -n "$EXT_DEV_XML" ]]; then
      EXT_ACTION="vintf:drop-device"
    fi
  fi
  if [[ "$ALIGN_K90_SELINUX" == "true" ]]; then
    if sudo test -d "$WORK_ROOT/k90_assets/system_ext_selinux"; then
      EXT_ACTION="${EXT_ACTION:+$EXT_ACTION,}selinux<-k90"
    elif sudo test -d "$MNT_EXT/etc/selinux"; then
      EXT_ACTION="${EXT_ACTION:+$EXT_ACTION,}selinux:drop"
    fi
  fi
  umount_erofs "$MNT_EXT"

  if [[ -z "$EXT_ACTION" ]]; then
    echo "[Align] system_ext 无需对齐，保持原样 passthrough（免一次 8 分钟的 EROFS 重打包）"
    mv "$WORK_ROOT/neo11_parts/system_ext.img" "$OUT_DIR/system_ext.img"
  else
    echo "[Align] system_ext 需要对齐（$EXT_ACTION），改为重建（其余内容保持不变）"
    STAGE_EXT="$WORK_ROOT/stage/system_ext"
    mount_erofs_ro "$WORK_ROOT/neo11_parts/system_ext.img" "$MNT_EXT"
    sudo rm -rf "$STAGE_EXT"
    sudo python3 "$REPO_ROOT/scripts/erofs_repack.py" copy "$MNT_EXT" "$STAGE_EXT"
    umount_erofs "$MNT_EXT"
    rm -f "$WORK_ROOT/neo11_parts/system_ext.img"
    if [[ "$ALIGN_K90_VINTF" == "true" ]]; then
      if sudo test -d "$WORK_ROOT/k90_assets/system_ext_vintf"; then
        sudo rm -rf "$STAGE_EXT/etc/vintf"
        sudo cp -a "$WORK_ROOT/k90_assets/system_ext_vintf" "$STAGE_EXT/etc/vintf"
        echo "[Align][VINTF] system_ext/etc/vintf <- K90 stock" | tee -a "$ALIGN_LOG"
      else
        while IFS= read -r f; do
          sudo rm -f "$f"
          echo "[Align][VINTF] Removed foreign device matrix: system_ext/${f#$STAGE_EXT/}" | tee -a "$ALIGN_LOG"
        done < <(sudo find "$STAGE_EXT/etc/vintf" -maxdepth 1 -type f -name '*device*.xml' 2>/dev/null || true)
      fi
    fi
    if [[ "$ALIGN_K90_SELINUX" == "true" ]]; then
      if sudo test -d "$WORK_ROOT/k90_assets/system_ext_selinux"; then
        sudo rm -rf "$STAGE_EXT/etc/selinux"
        sudo cp -a "$WORK_ROOT/k90_assets/system_ext_selinux" "$STAGE_EXT/etc/selinux"
        echo "[Align][SELinux] system_ext/etc/selinux <- K90 stock" | tee -a "$ALIGN_LOG"
      elif sudo test -d "$STAGE_EXT/etc/selinux"; then
        sudo rm -rf "$STAGE_EXT/etc/selinux"
        echo "[Align][SELinux] Removed foreign CIL tree: system_ext/etc/selinux" | tee -a "$ALIGN_LOG"
      fi
    fi
    sudo python3 "$REPO_ROOT/scripts/erofs_repack.py" fixup "$STAGE_EXT" --default-selinux "u:object_r:system_file:s0"
    sudo rm -f "$OUT_DIR/system_ext.img"
    sudo mkfs.erofs -z"$EROFS_COMPRESS" -T "$EROFS_TIMESTAMP" "$OUT_DIR/system_ext.img" "$STAGE_EXT"
    sudo rm -rf "$STAGE_EXT"
  fi
  sudo python3 "$REPO_ROOT/scripts/erofs_repack.py" verify "$OUT_DIR/system_ext.img" \
    --expect-file "etc/build.prop" \
    --min-selinux-ratio 0.999 | tee "$REPORT_DIR/verify_system_ext.txt"

  echo ""
  echo ">>> [Phase D3] Building empty anti-hijack mi_ext.img & mi_product.img..."
  EMPTY_DIR="$WORK_ROOT/stage/empty_erofs"
  sudo rm -rf "$EMPTY_DIR"
  sudo mkdir -p "$EMPTY_DIR"
  sudo chown 0:0 "$EMPTY_DIR"
  sudo chmod 0755 "$EMPTY_DIR"
  sudo python3 -c 'import os,sys; os.setxattr(sys.argv[1],"security.selinux",b"u:object_r:system_file:s0\x00")' "$EMPTY_DIR"
  sudo rm -f "$OUT_DIR/mi_ext.img" "$OUT_DIR/mi_product.img"
  sudo mkfs.erofs -z"$EROFS_COMPRESS" -T "$EROFS_TIMESTAMP" "$OUT_DIR/mi_ext.img" "$EMPTY_DIR"
  sudo mkfs.erofs -z"$EROFS_COMPRESS" -T "$EROFS_TIMESTAMP" "$OUT_DIR/mi_product.img" "$EMPTY_DIR"
  sudo rm -rf "$EMPTY_DIR"
  sudo python3 "$REPO_ROOT/scripts/erofs_repack.py" verify "$OUT_DIR/mi_ext.img" --min-selinux-ratio 0.99 | tee "$REPORT_DIR/verify_mi_ext.txt"
fi

sudo chown -R "$(id -u):$(id -g)" "$OUT_DIR" "$REPORT_DIR"

# ------------------------------------------------------------------------------
# PHASE E: Hard Capacity Gate (Must fit inside K90 qti_dynamic_partitions_a!)
# ------------------------------------------------------------------------------
echo ""
echo ">>> [Phase E] Checking K90 super partition capacity gate..."
python3 - "$OUT_DIR" "$REPORT_DIR/capacity_summary.txt" "$BUILD_SCOPE" \
  "$SUPER_GROUP_MAX_BYTES" "$SUPER_SAFETY_MARGIN_BYTES" "$K90_KEPT_PARTITIONS_BYTES" <<'PYEOF'
import os, sys

out_dir, report_path, scope, group_max, margin, kept = (
    sys.argv[1], sys.argv[2], sys.argv[3],
    int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]),
)

def sz(name, fallback=0):
    p = os.path.join(out_dir, name)
    return os.path.getsize(p) if os.path.isfile(p) else fallback

sys_b  = sz("system.img")
prod_b = sz("product.img", 408100864)      # fallback to measured Neo 11 size in system_only mode
ext_b  = sz("system_ext.img", 215228416)
mi_e   = sz("mi_ext.img", 16384)
mi_p   = sz("mi_product.img", 16384)

port_total = sys_b + prod_b + ext_b + mi_e + mi_p
grand_total = kept + port_total
allowed_max = group_max - margin
remaining = group_max - grand_total

def mib(x): return x / (1024 * 1024)
def gib(x): return x / (1024 ** 3)

lines = [
    f"Build Scope                 : {scope}",
    f"K90 Super Group Max         : {group_max:>13,d} B ({gib(group_max):.3f} GiB)",
    f"K90 Kept (odm+vendor+dlkm)  : {kept:>13,d} B ({mib(kept):8.2f} MiB)",
    f"Port system.img             : {sys_b:>13,d} B ({mib(sys_b):8.2f} MiB)",
    f"Port product.img            : {prod_b:>13,d} B ({mib(prod_b):8.2f} MiB)",
    f"Port system_ext.img         : {ext_b:>13,d} B ({mib(ext_b):8.2f} MiB)",
    f"Port mi_ext + mi_product    : {mi_e+mi_p:>13,d} B ({mib(mi_e+mi_p):8.2f} MiB)",
    f"-----------------------------------------------------------------",
    f"Total Super Allocation      : {grand_total:>13,d} B ({gib(grand_total):.3f} GiB)",
    f"Free Headroom Remaining     : {remaining:>13,d} B ({mib(remaining):8.2f} MiB)",
]
text = "\n".join(lines) + "\n"
print(text)
with open(report_path, "w") as f:
    f.write(text)

if grand_total > allowed_max:
    print(f"[FATAL] Super capacity exceeded! Need to trim at least {mib(grand_total - allowed_max):.2f} MiB!", file=sys.stderr)
    sys.exit(1)
print("[PASS] Super capacity gate PASSED with healthy headroom!")
PYEOF

# ------------------------------------------------------------------------------
# PHASE F: Generate macOS fastbootd Flash Script + SHA256SUMS + BUILD_INFO
# ------------------------------------------------------------------------------
echo ""
echo ">>> [Phase F] Generating flash_port_mac.sh & SHA256SUMS.txt..."

cat > "$OUT_DIR/BUILD_INFO.txt" <<EOF
Project       : vivo OriginOS 7 (iQOO Neo 11 PD2520) -> REDMI K90 (annibale)
Build Tag     : $BUILD_TAG
Build Scope   : $BUILD_SCOPE
Debug ADB     : $DEBUG_ADB
EROFS Compress: $EROFS_COMPRESS
Build Date UTC: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Base ROM      : REDMI K90 HyperOS 4 (OS4.0.6.0.XPKCNXM / Android 17 / Vendor API 202404)
Port ROM      : iQOO Neo 11 OriginOS 7 (PD2520_A_17.1.15.2.W10.V000L1 / Android 17)
OEM Variant   : $VIVO_OEM_VARIANT
K90 Align     : $ALIGN_K90_BASE (vintf=$ALIGN_K90_VINTF selinux=$ALIGN_K90_SELINUX)
Device Mask   : $MASK_DEVICE
EOF
cat "$REPORT_DIR/capacity_summary.txt" >> "$OUT_DIR/BUILD_INFO.txt"

cat > "$OUT_DIR/flash_port_mac.sh" <<'FLASH_EOF'
#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# REDMI K90 (annibale) - OriginOS 7 fastbootd Flasher for macOS
#
# Safety guarantees:
#   - Verifies SHA256 checksums of all images BEFORE touching the phone
#   - NEVER touches vendor, odm, vendor_dlkm, system_dlkm, modem, persist, efs
#   - Shrinks old HyperOS product/system_ext/mi_ext BEFORE flashing system so
#     fastbootd always has contiguous space inside super
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=================================================================="
echo "  OriginOS 7 -> REDMI K90 (annibale) fastbootd Flasher"
echo "=================================================================="
if [[ -f BUILD_INFO.txt ]]; then
  cat BUILD_INFO.txt
fi
echo "=================================================================="

command -v fastboot >/dev/null || { echo "[ERROR] fastboot not found! Run: brew install android-platform-tools"; exit 1; }

echo ""
echo "[1/7] Verifying local image SHA256 checksums..."
if command -v shasum >/dev/null; then
  shasum -a 256 -c SHA256SUMS.txt
else
  sha256sum -c SHA256SUMS.txt
fi
echo "[OK] All image checksums verified."

echo ""
echo "[2/7] Detecting connected REDMI K90 in Fastboot / Fastbootd..."
fastboot devices
PRODUCT="$(fastboot getvar product 2>&1 | awk -F': ' '/^product:/{print $2}' | tr -d '\r' | head -n 1)"
if [[ "$PRODUCT" != "annibale" ]]; then
  echo "[FATAL] Connected device product is '${PRODUCT:-unknown}', expected 'annibale' (REDMI K90)!"
  exit 1
fi

SLOT="$(fastboot getvar current-slot 2>&1 | awk -F': ' '/^current-slot:/{print $2}' | tr -d '\r' | head -n 1)"
if [[ "$SLOT" != "a" && "$SLOT" != "b" ]]; then
  echo "[FATAL] Could not determine valid current-slot (got '${SLOT:-empty}')"
  exit 1
fi
echo "[OK] Verified device=annibale, active slot=${SLOT}"

IS_USERSPACE="$(fastboot getvar is-userspace 2>&1 | awk -F': ' '/^is-userspace:/{print $2}' | tr -d '\r' | head -n 1 || true)"
echo ""
echo "[3/7] Ensuring device is in fastbootd BEFORE disabling AVB..."
# IMPORTANT (verified on real REDMI K90 SM8750 hardware):
# K90 ABL refuses to boot recovery/fastbootd if vbmeta has --disable-verification written first!
# Therefore we MUST enter fastbootd with stock unmodified vbmeta first, flash dynamic partitions,
# and ONLY disable AVB in bootloader mode right before booting Android.
if [[ "$IS_USERSPACE" != "yes" ]]; then
  if [[ -f vbmeta.img ]]; then
    echo "  -> Restoring unmodified stock vbmeta_${SLOT} & marking slot ${SLOT} active so fastbootd boots cleanly..."
    fastboot flash "vbmeta_${SLOT}" vbmeta.img
  fi
  fastboot set_active "${SLOT}"
  echo "  -> Rebooting from bootloader into fastbootd (userspace fastboot)..."
  fastboot reboot fastboot
  echo "  Waiting for fastbootd..."
  sleep 4
  IS_USERSPACE="$(fastboot getvar is-userspace 2>&1 | awk -F': ' '/^is-userspace:/{print $2}' | tr -d '\r' | head -n 1 || true)"
  if [[ "$IS_USERSPACE" != "yes" ]]; then
    echo "[FATAL] Device did not enter fastbootd (is-userspace='${IS_USERSPACE:-unknown}')! Aborting safely."
    exit 1
  fi
fi
echo "[OK] Confirmed device is in fastbootd (is-userspace=yes)."

echo ""
echo "[4/7] Cancelling any pending Virtual A/B snapshot updates & checking for unmerged -cow partitions..."
fastboot snapshot-update cancel 2>/dev/null || true
LEFTOVER_COWS="$(fastboot getvar all 2>&1 | grep -E "partition-size:(vendor|odm|vendor_dlkm|system_dlkm)_${SLOT}-cow:" || true)"
if [[ -n "$LEFTOVER_COWS" ]]; then
  echo "[WARN] Detected unmerged Virtual A/B -cow partitions on slot _${SLOT}:"
  echo "$LEFTOVER_COWS"
  echo "[WARN] Wiping /metadata while vendor/odm -cow snapshots remain unmerged will corrupt vendor/odm!"
  echo "[WARN] Recommended: merge OTA first (boot stock OS once) or re-flash clean stock vendor/odm/dlkm images."
fi

if [[ -f product.img && -f system_ext.img && -f mi_ext.img && -f mi_product.img ]]; then
  echo ""
  echo "[5/7] Resizing dynamic partitions on slot _${SLOT} & flashing FULL OriginOS 7 bundle..."
  echo "      (vendor_${SLOT}, odm_${SLOT}, vendor_dlkm_${SLOT}, system_dlkm_${SLOT} are NOT touched!)"
  # Shrink old large HyperOS partitions to 0 first (preserving qti_dynamic_partitions group!)
  for p in product system_ext mi_ext mi_product; do
    fastboot delete-logical-partition "${p}_${SLOT}-cow" 2>/dev/null || true
    fastboot resize-logical-partition "${p}_${SLOT}" 0 2>/dev/null || {
      fastboot delete-logical-partition "${p}_${SLOT}" 2>/dev/null || true
      fastboot create-logical-partition "${p}_${SLOT}" 0
    }
  done
  fastboot delete-logical-partition "system_${SLOT}-cow" 2>/dev/null || true

  echo "  -> Flashing empty anti-hijack mi_ext_${SLOT} & mi_product_${SLOT}..."
  fastboot flash "mi_ext_${SLOT}" mi_ext.img
  fastboot flash "mi_product_${SLOT}" mi_product.img

  echo "  -> Flashing product_${SLOT}..."
  fastboot flash "product_${SLOT}" product.img

  echo "  -> Flashing system_ext_${SLOT}..."
  fastboot flash "system_ext_${SLOT}" system_ext.img

  echo "  -> Flashing system_${SLOT} (largest partition, ~8 GB)..."
  fastboot flash "system_${SLOT}" system.img
else
  echo ""
  echo "[5/7] Flashing system-only update to system_${SLOT}..."
  fastboot flash "system_${SLOT}" system.img
fi

if [[ -f vbmeta.img && -f vbmeta_system.img ]]; then
  echo ""
  echo "[6/7] Rebooting to bootloader to disable AVB dm-verity (--disable-verity) on vbmeta_${SLOT}..."
  # IMPORTANT (verified on real REDMI K90 SM8750 hardware):
  # Using --disable-verification (flags=3) causes K90 ABL to skip loading init_boot/vendor_boot/dtbo/pvmfw
  # and bounce straight back to red FASTBOOT. Using --disable-verity (flags=1) keeps boot/init_boot/vendor_boot
  # loading intact while disabling dm-verity hashtree checks on unsigned EROFS system/product/system_ext/mi_ext.
  fastboot reboot bootloader
  sleep 4
  fastboot --disable-verity flash "vbmeta_${SLOT}" vbmeta.img
  fastboot flash "vbmeta_system_${SLOT}" vbmeta_system.img
  fastboot set_active "${SLOT}"
else
  echo ""
  echo "[6/7] System-only mode: skipping vbmeta AVB re-flash."
fi

echo ""
echo "[7/7] Wipe userdata/metadata? (REQUIRED on first switch from HyperOS -> OriginOS!)"
read -r -p "Run 'fastboot -w' (ERASES ALL USER DATA)? Type YES to wipe, or Enter to skip: " WIPE_ANS
if [[ "$WIPE_ANS" == "YES" ]]; then
  echo "  -> Wiping userdata & metadata..."
  if ! fastboot -w; then
    echo "  [WARN] 'fastboot -w' failed; falling back to erasing metadata & userdata (fstab marks both formattable)..."
    fastboot erase metadata
    fastboot erase userdata
  fi
else
  echo "  -> Skipped fastboot -w."
fi

echo ""
echo "=================================================================="
echo "  FLASH COMPLETE!"
echo "  Run 'fastboot reboot' when ready, and watch logs with:"
echo "    adb wait-for-device && adb logcat -b all > boot_logcat.txt"
echo "=================================================================="
read -r -p "Reboot device now? [y/N]: " REBOOT_ANS
if [[ "$REBOOT_ANS" == "y" || "$REBOOT_ANS" == "Y" ]]; then
  fastboot reboot
fi
FLASH_EOF
chmod +x "$OUT_DIR/flash_port_mac.sh"

(
  cd "$OUT_DIR"
  sha256sum *.img > SHA256SUMS.txt
)
cp "$OUT_DIR/BUILD_INFO.txt" "$REPORT_DIR/BUILD_INFO.txt"
cp "$OUT_DIR/SHA256SUMS.txt" "$REPORT_DIR/SHA256SUMS.txt"
cp "$OUT_DIR/flash_port_mac.sh" "$REPORT_DIR/flash_port_mac.sh"

echo ""
echo "=================================================================="
echo "  [DONE] Output bundle contents ($OUT_DIR):"
ls -lh "$OUT_DIR"
echo "=================================================================="
