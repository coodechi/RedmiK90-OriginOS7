#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Cloud Uploader: Package port bundle (.tar.zst), auto-split into 2000 MiB parts
# with SHA256 manifest (.parts.json), and upload to ModelScope Private Dataset.
#
# Usage:
#   05_upload_ms.sh <bundle_dir> <ms_dataset_repo_id> <archive_base_name> [remote_subdir]
# Requires env:
#   MODELSCOPE_API_TOKEN
# ==============================================================================

BUNDLE_DIR="${1:?Usage: 05_upload_ms.sh <bundle_dir> <ms_repo_id> <archive_base_name> [remote_subdir]}"
MS_REPO_ID="${2:?Missing ModelScope dataset repo id}"
ARCHIVE_NAME="${3:?Missing archive base name (e.g. OriginOS7_K90_v0.1.tar.zst)}"
REMOTE_SUBDIR="${4:-builds}"

if [[ -z "${MODELSCOPE_API_TOKEN:-}" ]]; then
  echo "[FATAL] MODELSCOPE_API_TOKEN is not set!"
  exit 1
fi

WORK_ROOT="${WORK_ROOT:-/tmp/rom_work}"
STAGE_ARCHIVE="$WORK_ROOT/${ARCHIVE_NAME}"
PARTS_DIR="$WORK_ROOT/ms_upload_parts"
rm -rf "$PARTS_DIR" "$STAGE_ARCHIVE"
mkdir -p "$PARTS_DIR"

echo "[Upload] Archiving $BUNDLE_DIR -> $STAGE_ARCHIVE (zstd -T0 -3)..."
tar -C "$(dirname "$BUNDLE_DIR")" -cf - "$(basename "$BUNDLE_DIR")" | zstd -T0 -3 -o "$STAGE_ARCHIVE"
ls -lh "$STAGE_ARCHIVE"

# Split into 2000 MiB chunks (< 5 GB ModelScope OSS single-PUT limit, also < 2 GiB)
python3 - "$STAGE_ARCHIVE" "$PARTS_DIR" "$ARCHIVE_NAME" <<'PYEOF'
import hashlib, json, os, sys

src, parts_dir, base_name = sys.argv[1:4]
chunk_size = 2000 * 1024 * 1024  # 2000 MiB
total_size = os.path.getsize(src)
print(f"[Split] {base_name}: {total_size / (1024**3):.2f} GiB -> 2000 MiB chunks")

full_sha = hashlib.sha256()
parts_meta = []
idx = 0

with open(src, "rb") as fin:
    while True:
        part_name = f"{base_name}.part{idx:02d}"
        part_path = os.path.join(parts_dir, part_name)
        part_sha = hashlib.sha256()
        written = 0
        with open(part_path, "wb") as fout:
            while written < chunk_size:
                buf = fin.read(min(8 * 1024 * 1024, chunk_size - written))
                if not buf:
                    break
                fout.write(buf)
                full_sha.update(buf)
                part_sha.update(buf)
                written += len(buf)
        if written == 0:
            os.remove(part_path)
            break
        parts_meta.append({
            "name": part_name,
            "size": written,
            "sha256": part_sha.hexdigest(),
        })
        print(f"  [Part {idx:02d}] {part_name} ({written / (1024**2):.1f} MiB) sha256={part_sha.hexdigest()[:12]}...")
        idx += 1

manifest = {
    "original_name": base_name,
    "total_size": total_size,
    "total_sha256": full_sha.hexdigest(),
    "chunk_size": chunk_size,
    "parts": parts_meta,
}
manifest_path = os.path.join(parts_dir, f"{base_name}.parts.json")
with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
print(f"[OK] Wrote manifest {os.path.basename(manifest_path)} ({len(parts_meta)} parts)")
PYEOF

# Delete unsplit archive immediately to keep runner disk low
rm -f "$STAGE_ARCHIVE"

# Upload all parts + manifest to ModelScope Private Dataset via modelscope-hub with retries
python3 - "$MS_REPO_ID" "$PARTS_DIR" "$REMOTE_SUBDIR" "$ARCHIVE_NAME" <<'PYEOF'
import os, sys, time
from modelscope_hub import HubApi

repo_id, parts_dir, subdir, archive_name = sys.argv[1:5]
token = os.environ["MODELSCOPE_API_TOKEN"]
endpoint = os.environ.get("MODELSCOPE_ENDPOINT") or "https://modelscope.cn"
api = HubApi(token=token, endpoint=endpoint)

files = sorted(os.listdir(parts_dir))
# Upload manifest LAST so its presence confirms all parts finished
manifest_name = f"{archive_name}.parts.json"
ordered = [f for f in files if f != manifest_name] + [manifest_name]

for i, fname in enumerate(ordered, 1):
    local_p = os.path.join(parts_dir, fname)
    remote_p = f"{subdir.strip('/')}/{fname}" if subdir else fname
    size_mb = os.path.getsize(local_p) / (1024 * 1024)
    print(f"[{i}/{len(ordered)}] Uploading {fname} ({size_mb:.1f} MiB) -> {remote_p} ...", flush=True)
    for attempt in range(1, 6):
        try:
            api.upload_file(repo_id, "dataset", local_p, remote_p, commit_message=f"Upload build artifact {fname}")
            print(f"  [OK] Uploaded {fname}", flush=True)
            break
        except Exception as e:
            print(f"  [WARN] Attempt {attempt}/5 failed for {fname}: {e}", flush=True)
            if attempt == 5:
                raise
            time.sleep(attempt * 6)

print("[DONE] All build chunks + manifest uploaded to ModelScope!")
PYEOF

rm -rf "$PARTS_DIR"
