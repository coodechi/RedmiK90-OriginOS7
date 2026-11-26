#!/usr/bin/env bash
set -euo pipefail

# Helper script to upload a local 10GB+ ROM from macOS to a ModelScope Private Dataset.
# Why automatic 2GB chunking:
#   ModelScope's single-PUT LFS endpoint resets connections on single files > 5GB
#   (ConnectionResetError 54). Splitting into 2GB parts + uploading a .parts.json manifest
#   avoids the 5GB PUT limit, enables per-part resume (SHA256 dedup), and works cleanly
#   with scripts/01_fetch_rom.sh on GitHub Actions!
#
# Usage:
#   export MODELSCOPE_API_TOKEN="你的魔搭SDK令牌"
#   bash scripts/local_upload_ms.sh <魔搭用户名>/<数据集名> <本地文件> [远端前缀名]

REPO_ID="${1:?Usage: $0 <owner/dataset_repo> <local_file> [remote_name]}"
LOCAL_FILE="${2:?Missing local file path}"
REMOTE_NAME="${3:-$(basename "$LOCAL_FILE")}"
SPLIT_THRESHOLD_BYTES=$((3500 * 1024 * 1024)) # 3.5 GB
PART_SIZE_MB=2000                             # 2 GB per part (safely under 5 GB OSS PUT limit)

if [ -z "${MODELSCOPE_API_TOKEN:-}" ]; then
  echo "ERROR: Please export MODELSCOPE_API_TOKEN first." >&2
  echo "Get your Write token at: https://modelscope.cn/my/myaccesstoken" >&2
  exit 1
fi

if [ ! -f "$LOCAL_FILE" ]; then
  echo "ERROR: Local file not found: $LOCAL_FILE" >&2
  exit 1
fi

PY_OK_310=$(python3 -c 'import sys; print(1 if sys.version_info >= (3, 10) else 0)')
if [ "$PY_OK_310" = "1" ]; then
  if ! python3 -c "import modelscope_hub" >/dev/null 2>&1; then
    python3 -m pip install --user -U modelscope-hub -i https://mirrors.aliyun.com/pypi/simple/
  fi
else
  if ! python3 -c "from modelscope.hub.api import HubApi" >/dev/null 2>&1; then
    python3 -m pip install --user -U modelscope -i https://mirrors.aliyun.com/pypi/simple/
  fi
fi

FILE_SIZE=$(stat -f%z "$LOCAL_FILE" 2>/dev/null || stat -c%s "$LOCAL_FILE")
echo "File: $LOCAL_FILE ($FILE_SIZE bytes)"

upload_one_file() {
  local local_path="$1"
  local remote_path="$2"
  local attempt=1
  local max_attempts=5

  while [ "$attempt" -le "$max_attempts" ]; do
    echo "Uploading [attempt $attempt/$max_attempts]: $(basename "$local_path") -> ms://${REPO_ID}/${remote_path}"
    if python3 - "$REPO_ID" "$local_path" "$remote_path" "$PY_OK_310" <<'PYEOF'
import os, sys
repo_id, local_path, remote_path, py_ok_310 = sys.argv[1:5]
token = os.environ["MODELSCOPE_API_TOKEN"]

if py_ok_310 == "1":
    from modelscope_hub import HubApi
    api = HubApi(token=token, endpoint="https://modelscope.cn")
    api.upload_file(repo_id, "dataset", local_path, remote_path, commit_message=f"Upload {remote_path}")
else:
    from modelscope.hub.api import HubApi
    api = HubApi()
    api.login(token)
    api.upload_file(
        path_or_fileobj=local_path,
        path_in_repo=remote_path,
        repo_id=repo_id,
        repo_type="dataset",
        commit_message=f"Upload {remote_path}",
    )
PYEOF
    then
      echo "Uploaded successfully: $remote_path"
      return 0
    fi
    echo "WARN: Upload failed on attempt $attempt, retrying in 8s..." >&2
    sleep 8
    attempt=$((attempt + 1))
  done

  echo "ERROR: Failed to upload $remote_path after $max_attempts attempts." >&2
  return 1
}

if [ "$FILE_SIZE" -le "$SPLIT_THRESHOLD_BYTES" ]; then
  upload_one_file "$LOCAL_FILE" "$REMOTE_NAME"
  echo ""
  echo "=========================================="
  echo "Upload complete! Use this in GitHub Actions:"
  echo "  ms://${REPO_ID}/${REMOTE_NAME}"
  echo "=========================================="
  exit 0
fi

# Large file (> 3.5 GB): split into 2 GB parts + manifest JSON
PARTS_DIR="$(dirname "$LOCAL_FILE")/.ms_parts_${REMOTE_NAME}"
mkdir -p "$PARTS_DIR"
MANIFEST_FILE="${PARTS_DIR}/${REMOTE_NAME}.parts.json"

echo "File exceeds 3.5 GB; splitting into ${PART_SIZE_MB} MB chunks in ${PARTS_DIR} ..."
if [ ! -f "${PARTS_DIR}/${REMOTE_NAME}.part00" ]; then
  rm -f "${PARTS_DIR}/${REMOTE_NAME}.part"*
  # Stream split in pure Python (macOS BSD split lacks -d numeric suffix)
  python3 - "$LOCAL_FILE" "$PARTS_DIR" "$REMOTE_NAME" "$PART_SIZE_MB" <<'PYEOF'
import hashlib, json, os, sys

src, out_dir, base, part_mb = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
part_bytes = part_mb * 1024 * 1024
buf_size = 16 * 1024 * 1024

parts = []
total_hash = hashlib.sha256()
total_size = 0
idx = 0

with open(src, "rb") as f:
    while True:
        part_name = f"{base}.part{idx:02d}"
        part_path = os.path.join(out_dir, part_name)
        part_hash = hashlib.sha256()
        written = 0
        with open(part_path, "wb") as out:
            while written < part_bytes:
                chunk = f.read(min(buf_size, part_bytes - written))
                if not chunk:
                    break
                out.write(chunk)
                part_hash.update(chunk)
                total_hash.update(chunk)
                written += len(chunk)
        if written == 0:
            os.remove(part_path)
            break
        total_size += written
        parts.append({
            "name": part_name,
            "size": written,
            "sha256": part_hash.hexdigest(),
        })
        print(f"  Created {part_name}: {written / 1024**2:.2f} MiB (sha256={parts[-1]['sha256'][:12]}...)")
        idx += 1

manifest = {
    "filename": base,
    "total_size": total_size,
    "total_sha256": total_hash.hexdigest(),
    "parts": parts,
}
manifest_path = os.path.join(out_dir, f"{base}.parts.json")
with open(manifest_path, "w", encoding="utf-8") as mf:
    json.dump(manifest, mf, indent=2)
print(f"Wrote manifest: {manifest_path} ({len(parts)} parts, total {total_size} bytes)")
PYEOF
else
  echo "Reusing existing split parts in ${PARTS_DIR} (resuming upload)..."
fi

for part_file in "${PARTS_DIR}/${REMOTE_NAME}.part"*; do
  part_base="$(basename "$part_file")"
  upload_one_file "$part_file" "parts/${part_base}"
done

upload_one_file "$MANIFEST_FILE" "${REMOTE_NAME}.parts.json"

echo "Cleaning up temporary local parts in ${PARTS_DIR} ..."
rm -rf "$PARTS_DIR"

echo ""
echo "=========================================="
echo "ALL PARTS UPLOADED SUCCESSFULLY!"
echo "Use this as port_rom_source in GitHub Actions:"
echo "  ms://${REPO_ID}/${REMOTE_NAME}.parts.json"
echo "=========================================="
