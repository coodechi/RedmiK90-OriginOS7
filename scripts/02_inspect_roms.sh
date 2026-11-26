#!/usr/bin/env bash
set -euo pipefail

# Inspect both K90 stock Fastboot .tgz and iQOO Neo 11 OriginOS 7 full .zip
# Uses read-only kernel EROFS mounts (0 extra disk space!) and deletes large archives immediately.

REPO_ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
WORK_ROOT="${WORK_ROOT:?WORK_ROOT must be set}"
STOCK_SOURCE="${STOCK_SOURCE:?STOCK_SOURCE must be set}"
PORT_SOURCE="${PORT_SOURCE:?PORT_SOURCE must be set}"

REPORT_DIR="$WORK_ROOT/report"
DL_DIR="$WORK_ROOT/dl"
MNT_DIR="$WORK_ROOT/mnt"
mkdir -p "$REPORT_DIR"/{k90,neo11,k90_vintf,neo11_vintf} "$DL_DIR" "$MNT_DIR"

mount_ro() {
  local img="$1"
  local target="$2"
  mkdir -p "$target"
  if sudo mount -t erofs -o ro,loop "$img" "$target" 2>/dev/null; then
    echo "Mounted EROFS: $img -> $target"
  elif sudo mount -o ro,loop "$img" "$target" 2>/dev/null; then
    echo "Mounted generic FS: $img -> $target"
  else
    echo "ERROR: Failed to mount $img" >&2
    file "$img" || true
    dump.erofs "$img" || true
    return 1
  fi
}

umount_safe() {
  local target="$1"
  if mountpoint -q "$target" 2>/dev/null; then
    sudo umount "$target" || true
  fi
}

echo "=========================================="
echo "[Phase 1] Inspecting Redmi K90 Stock ROM"
echo "=========================================="
STOCK_TGZ="$DL_DIR/stock_k90.tgz"
bash "$REPO_ROOT/scripts/01_fetch_rom.sh" "$STOCK_SOURCE" "$STOCK_TGZ"

K90_EXT="$WORK_ROOT/k90_ext"
mkdir -p "$K90_EXT"
echo "Extracting ONLY super.img + small metadata from K90 tgz..."
tar -xzf "$STOCK_TGZ" -C "$K90_EXT" \
  --wildcards \
  '*/images/super.img' \
  '*/images/vbmeta*.img' \
  '*/images/boot.img' \
  '*/images/init_boot.img' \
  '*/images/vendor_boot.img' \
  '*/images/rawprogram0.xml' \
  '*/images/platform_security_patch.txt' \
  '*/images/anti_version.txt' \
  '*/misc.txt'
rm -f "$STOCK_TGZ"
df -h "$WORK_ROOT"

K90_IMG_DIR=$(find "$K90_EXT" -type d -name images | head -n 1)
cp -f "$K90_IMG_DIR/rawprogram0.xml" "$REPORT_DIR/k90/" 2>/dev/null || true
cp -f "$K90_IMG_DIR/platform_security_patch.txt" "$REPORT_DIR/k90/" 2>/dev/null || true
cp -f "$K90_IMG_DIR/../misc.txt" "$REPORT_DIR/k90/" 2>/dev/null || true

echo "Converting sparse super.img -> super_raw.img..."
simg2img "$K90_IMG_DIR/super.img" "$WORK_ROOT/k90_super_raw.img"
rm -f "$K90_IMG_DIR/super.img"

echo "Dumping K90 super layout..."
python3 "$REPO_ROOT/scripts/lp_tools.py" dump "$WORK_ROOT/k90_super_raw.img" | tee "$REPORT_DIR/k90/k90_super_layout.txt"

K90_PARTS="$WORK_ROOT/k90_parts"
echo "Unpacking K90 logical partitions..."
python3 "$REPO_ROOT/scripts/lp_tools.py" unpack "$WORK_ROOT/k90_super_raw.img" "$K90_PARTS"
rm -f "$WORK_ROOT/k90_super_raw.img"
df -h "$WORK_ROOT"

# Record filesystem details (erofs flags/compression) of each K90 logical partition
{
  echo "=== K90 Logical Partition FS Details ==="
  for img in "$K90_PARTS"/*.img; do
    [ -f "$img" ] || continue
    echo "--- $(basename "$img") ($(stat -c%s "$img") bytes) ---"
    file "$img" || true
    dump.erofs "$img" 2>/dev/null | head -n 20 || true
  done
} > "$REPORT_DIR/k90/k90_fs_details.txt"

# Inspect K90 vendor & odm (handle both vendor.img and vendor_a.img naming)
for base in vendor odm product system_ext system; do
  img=""
  for cand in "$K90_PARTS/${base}_a.img" "$K90_PARTS/${base}.img"; do
    if [ -f "$cand" ]; then img="$cand"; break; fi
  done
  [ -n "$img" ] || continue

  mp="$MNT_DIR/k90_$base"
  if mount_ro "$img" "$mp"; then
    # Collect build.prop files
    find "$mp" -maxdepth 3 -name "*build.prop" -o -name "prop.default" 2>/dev/null | while read -r pf; do
      rel="${pf#$mp/}"
      echo "### K90 $base/$rel ###" >> "$REPORT_DIR/k90/k90_${base}_props.txt"
      cat "$pf" >> "$REPORT_DIR/k90/k90_${base}_props.txt" 2>/dev/null || true
      echo "" >> "$REPORT_DIR/k90/k90_${base}_props.txt"
    done

    # Collect fstab
    find "$mp" -maxdepth 3 -name "fstab*" 2>/dev/null | while read -r ff; do
      echo "### K90 $base/${ff#$mp/} ###" >> "$REPORT_DIR/k90/k90_fstab.txt"
      cat "$ff" >> "$REPORT_DIR/k90/k90_fstab.txt" 2>/dev/null || true
      echo "" >> "$REPORT_DIR/k90/k90_fstab.txt"
    done

    # Collect VINTF XMLs from vendor & odm
    if [ "$base" = "vendor" ] || [ "$base" = "odm" ]; then
      if [ -d "$mp/etc/vintf" ]; then
        mkdir -p "$REPORT_DIR/k90_vintf/$base"
        cp -a "$mp/etc/vintf/." "$REPORT_DIR/k90_vintf/$base/" || true
      fi
    fi

    # List overlays & apex
    if [ -d "$mp/overlay" ]; then
      find "$mp/overlay" -maxdepth 3 -ls > "$REPORT_DIR/k90/k90_${base}_overlays.txt" 2>/dev/null || true
    fi
    if [ -d "$mp/apex" ] || [ -d "$mp/system/apex" ]; then
      find "$mp" -maxdepth 3 -path "*/apex/*" -ls > "$REPORT_DIR/k90/k90_${base}_apex.txt" 2>/dev/null || true
    fi

    # Collect display config XMLs if present
    find "$mp" -maxdepth 4 -name "display_id_*.xml" -o -name "displayconfig*" 2>/dev/null >> "$REPORT_DIR/k90/k90_display_files.txt" || true

    umount_safe "$mp"
  fi
done

# Free all K90 unpacked partitions before downloading Neo 11
rm -rf "$K90_PARTS" "$K90_EXT"
echo "K90 inspection complete. Disk space after cleanup:"
df -h "$WORK_ROOT"

echo "=========================================="
echo "[Phase 2] Inspecting iQOO Neo 11 Port ROM"
echo "=========================================="
PORT_ZIP="$DL_DIR/port_neo11.zip"
bash "$REPO_ROOT/scripts/01_fetch_rom.sh" "$PORT_SOURCE" "$PORT_ZIP"

PORT_OEM="$WORK_ROOT/port_oem"
PORT_PARTS="$WORK_ROOT/port_parts"
mkdir -p "$PORT_OEM" "$PORT_PARTS"

# Extract metadata & nested oem_zip archives first
unzip -o "$PORT_ZIP" \
  "META-INF/com/android/metadata" \
  "oem_zip/vgc_V000_PD2520MA.zip" \
  "oem_zip/oem_PD2520_ALL_IN_ONE_02.zip" \
  "oem_zip/dyn_PD2520_NULL.zip" \
  -d "$PORT_OEM" || true

cp -f "$PORT_OEM/META-INF/com/android/metadata" "$REPORT_DIR/neo11/metadata.txt" 2>/dev/null || true

# Dump ONLY system, system_ext, product directly from zip (no extra copy of 10GB payload.bin!)
echo "Extracting system, system_ext, product via payload-dumper-go..."
payload-dumper-go -p system,system_ext,product -o "$PORT_PARTS" "$PORT_ZIP"
rm -f "$PORT_ZIP"
df -h "$WORK_ROOT"

# Also dump nested vgc & oem small payload.bin images
for sub in vgc_V000_PD2520MA oem_PD2520_ALL_IN_ONE_02; do
  subzip="$PORT_OEM/oem_zip/${sub}.zip"
  if [ -f "$subzip" ]; then
    mkdir -p "$PORT_OEM/$sub"
    unzip -o "$subzip" -d "$PORT_OEM/$sub" >/dev/null
    find "$PORT_OEM/$sub" -name "*.prop" | while read -r pf; do
      echo "### $sub :: ${pf#$PORT_OEM/$sub/} ###" >> "$REPORT_DIR/neo11/neo11_oem_vgc_props.txt"
      cat "$pf" >> "$REPORT_DIR/neo11/neo11_oem_vgc_props.txt" || true
      echo "" >> "$REPORT_DIR/neo11/neo11_oem_vgc_props.txt"
    done
    if [ -f "$PORT_OEM/$sub/payload.bin" ]; then
      mkdir -p "$PORT_OEM/${sub}_imgs"
      payload-dumper-go -o "$PORT_OEM/${sub}_imgs" "$PORT_OEM/$sub/payload.bin" || true
      for img in "$PORT_OEM/${sub}_imgs"/*.img; do
        [ -f "$img" ] || continue
        mp="$MNT_DIR/neo11_$(basename "$img" .img)"
        if mount_ro "$img" "$mp"; then
          find "$mp" -maxdepth 4 > "$REPORT_DIR/neo11/files_${sub}_$(basename "$img" .img).txt" 2>/dev/null || true
          umount_safe "$mp"
        fi
      done
    fi
  fi
done

# Record Neo 11 FS details
{
  echo "=== Neo 11 Partition FS Details ==="
  for img in "$PORT_PARTS"/*.img; do
    [ -f "$img" ] || continue
    echo "--- $(basename "$img") ($(stat -c%s "$img") bytes) ---"
    file "$img" || true
    dump.erofs "$img" 2>/dev/null | head -n 20 || true
  done
} > "$REPORT_DIR/neo11/neo11_fs_details.txt"

# Inspect Neo 11 system, system_ext, product via read-only EROFS mounts
for base in system system_ext product; do
  img="$PORT_PARTS/${base}.img"
  [ -f "$img" ] || continue
  mp="$MNT_DIR/neo11_$base"
  if mount_ro "$img" "$mp"; then
    # Props
    find "$mp" -maxdepth 4 \( -name "*build.prop" -o -name "prop.default" \) 2>/dev/null | while read -r pf; do
      echo "### Neo11 $base/${pf#$mp/} ###" >> "$REPORT_DIR/neo11/neo11_${base}_props.txt"
      cat "$pf" >> "$REPORT_DIR/neo11/neo11_${base}_props.txt" 2>/dev/null || true
      echo "" >> "$REPORT_DIR/neo11/neo11_${base}_props.txt"
    done

    # VINTF compatibility matrices
    for vdir in "$mp/etc/vintf" "$mp/system/etc/vintf"; do
      if [ -d "$vdir" ]; then
        mkdir -p "$REPORT_DIR/neo11_vintf/$base"
        cp -a "$vdir/." "$REPORT_DIR/neo11_vintf/$base/" || true
      fi
    done

    # Top space consumers (critical for planning debloat to fit K90 12.50 GiB super!)
    {
      echo "=== Top directories in $base (depth 2) ==="
      sudo du -h --max-depth=2 "$mp" 2>/dev/null | sort -hr | head -n 40
      echo ""
      echo "=== Top 120 largest apps/items in app/priv-app/data-app/preload ==="
      for adir in "$mp/app" "$mp/priv-app" "$mp/data-app" "$mp/preload" "$mp/system/app" "$mp/system/priv-app" "$mp/system/data-app" "$mp/system/preload" "$mp/system/custom" "$mp/media"; do
        if [ -d "$adir" ]; then
          sudo du -sm "$adir"/* 2>/dev/null || true
        fi
      done | sort -nr | head -n 120
    } > "$REPORT_DIR/neo11/neo11_${base}_space.txt"

    # Search for Q2 / iris / memc / Vivo3rdAlgo / vibrator / fingerprint / display services
    {
      echo "=== Special hardware / Q2 / Vivo3rdAlgo matches in $base ==="
      find "$mp" -maxdepth 5 \( \
        -iname "*iris*" -o -iname "*pixelworks*" -o -iname "*memc*" \
        -o -iname "*q2*" -o -iname "*Vivo3rdAlgo*" -o -iname "*VivoFrameworksRes*" \
        -o -iname "*fingerprint*" -o -iname "*vibrat*" -o -iname "*display*" \
      \) 2>/dev/null | sort
    } > "$REPORT_DIR/neo11/neo11_${base}_hardware_refs.txt"

    # List init rc files & apex
    find "$mp" -maxdepth 4 -path "*/etc/init/*.rc" 2>/dev/null | sort > "$REPORT_DIR/neo11/neo11_${base}_init_rc.txt" || true
    find "$mp" -maxdepth 3 -path "*/apex/*" -ls 2>/dev/null > "$REPORT_DIR/neo11/neo11_${base}_apex.txt" || true
    find "$mp" -maxdepth 4 -path "*/overlay/*" -ls 2>/dev/null > "$REPORT_DIR/neo11/neo11_${base}_overlays.txt" || true

    umount_safe "$mp"
  fi
done

rm -rf "$PORT_PARTS" "$PORT_OEM"

echo "=========================================="
echo "[Phase 3] Automated VINTF Compatibility Diff"
echo "=========================================="
python3 "$REPO_ROOT/scripts/vintf_diff.py" "$REPORT_DIR/k90_vintf" "$REPORT_DIR/neo11_vintf" | tee "$REPORT_DIR/vintf_diff_summary.txt"

# Build GitHub Actions Step Summary for instant review in browser
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## 红米 K90 + iQOO Neo 11 OriginOS 7 云端体检摘要"
    echo ""
    echo "### 1. 红米 K90 \`super\` 分区精确布局"
    echo '```text'
    cat "$REPORT_DIR/k90/k90_super_layout.txt"
    echo '```'
    echo ""
    echo "### 2. VINTF 强依赖差异（Neo 11 要求但 K90 缺失的 HAL）"
    echo '```text'
    cat "$REPORT_DIR/vintf_diff_summary.txt"
    echo '```'
    echo ""
    echo "### 3. Neo 11 \`system\` 占用前 30 目录/大包（精简瘦身参考）"
    echo '```text'
    head -n 45 "$REPORT_DIR/neo11/neo11_system_space.txt" || true
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "Inspection report ready at: $REPORT_DIR"
du -sh "$REPORT_DIR"
