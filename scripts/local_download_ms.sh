#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# macOS Local Helper: Fast parallel download of built OriginOS 7 ROM bundle
# from ModelScope Private Dataset, SHA256 verify, merge & extract.
# Supports both Python 3.9 (modelscope) and Python 3.10+ (modelscope-hub).
#
# Usage:
#   MODELSCOPE_API_TOKEN=xxx bash scripts/local_download_ms.sh <ms_repo_id> <remote_manifest_path> [out_dir]
# Example:
#   MODELSCOPE_API_TOKEN=xxx bash scripts/local_download_ms.sh \
#     myuser/redmi-k90-roms \
#     builds/v0.1-bringup/OriginOS7_RedmiK90_v0.1-bringup_full.tar.zst.parts.json \
#     out/v0.1-bringup
# ==============================================================================

MS_REPO_ID="${1:?Usage: local_download_ms.sh <ms_repo_id> <remote_parts_json_path> [out_dir]}"
REMOTE_MANIFEST="${2:?Missing remote .parts.json path (e.g. builds/v0.1-bringup/OriginOS7_RedmiK90_v0.1-bringup_full.tar.zst.parts.json)}"
DEST_DIR="${3:-out/latest_port}"

if [[ -z "${MODELSCOPE_API_TOKEN:-}" ]]; then
  echo "[ERROR] Please export MODELSCOPE_API_TOKEN first."
  exit 1
fi

command -v zstd >/dev/null || { echo "[ERROR] zstd not found! Run: brew install zstd"; exit 1; }

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

mkdir -p "$DEST_DIR"
TMP_DL="$DEST_DIR/.dl_cache"
mkdir -p "$TMP_DL"

python3 - "$MS_REPO_ID" "$REMOTE_MANIFEST" "$TMP_DL" "$DEST_DIR" "$PY_OK_310" <<'PYEOF'
import concurrent.futures, hashlib, json, os, sys, time

repo_id, remote_manifest, tmp_dl, dest_dir, py_ok_310 = sys.argv[1:6]
token = os.environ["MODELSCOPE_API_TOKEN"]
endpoint = os.environ.get("MODELSCOPE_ENDPOINT") or "https://modelscope.cn"

if py_ok_310 == "1":
    from modelscope_hub import HubApi
    def fetch_ms(rpath):
        api = HubApi(token=token, endpoint=endpoint)
        return str(api.download_file(repo_id, "dataset", rpath, revision="master", local_dir=tmp_dl))
else:
    from modelscope.hub.api import HubApi
    from modelscope.hub.file_download import dataset_file_download
    api = HubApi()
    api.login(token)
    def fetch_ms(rpath):
        return str(dataset_file_download(dataset_id=repo_id, file_path=rpath, cache_dir=tmp_dl))

print(f"[1/4] Downloading manifest {remote_manifest} ...", flush=True)
manifest_local = fetch_ms(remote_manifest)
with open(manifest_local, "r", encoding="utf-8") as f:
    meta = json.load(f)

orig_name = meta.get("original_name") or meta.get("original_filename") or os.path.basename(remote_manifest).replace(".parts.json", "")
parts = meta["parts"]
remote_dir = os.path.dirname(remote_manifest)
workers = min(6, len(parts))
print(f"[2/4] Downloading {len(parts)} chunks in parallel (workers={workers}) for {orig_name} ...", flush=True)

def dl_one(idx_part):
    idx, p = idx_part
    fname = p.get("name") or p.get("filename")
    rpath = f"{remote_dir}/{fname}" if remote_dir else fname
    for attempt in range(1, 5):
        try:
            lp = fetch_ms(rpath)
            h = hashlib.sha256()
            with open(lp, "rb") as fp:
                for blk in iter(lambda: fp.read(8 * 1024 * 1024), b""):
                    h.update(blk)
            if h.hexdigest() != p["sha256"]:
                raise RuntimeError(f"SHA256 mismatch on {fname}")
            print(f"  [{idx}/{len(parts)}] Verified {fname}", flush=True)
            return idx, lp
        except Exception as e:
            print(f"  [WARN] {fname} attempt {attempt}/4 failed: {e}", flush=True)
            if attempt == 4:
                raise
            time.sleep(attempt * 3)

results = {}
with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
    futs = [ex.submit(dl_one, (i, p)) for i, p in enumerate(parts, 1)]
    for fut in concurrent.futures.as_completed(futs):
        idx, lp = fut.result()
        results[idx] = lp

merged = os.path.join(dest_dir, orig_name)
print(f"[3/4] Merging {len(parts)} chunks -> {merged} ...", flush=True)
total_sha = hashlib.sha256()
with open(merged, "wb") as fout:
    for i in range(1, len(parts) + 1):
        with open(results[i], "rb") as fin:
            while True:
                buf = fin.read(8 * 1024 * 1024)
                if not buf:
                    break
                fout.write(buf)
                total_sha.update(buf)

if meta.get("total_sha256") and total_sha.hexdigest() != meta["total_sha256"]:
    raise RuntimeError("FATAL: Merged archive SHA256 mismatch!")
print(f"[OK] Merged archive verified: sha256={total_sha.hexdigest()[:16]}...")
PYEOF

ARCHIVE_FILE="$(find "$DEST_DIR" -maxdepth 1 -name '*.tar.zst' | head -n 1)"
echo "[4/4] Extracting $ARCHIVE_FILE -> $DEST_DIR ..."
zstd -d -c "$ARCHIVE_FILE" | tar -xf - -C "$DEST_DIR"
rm -rf "$TMP_DL" "$ARCHIVE_FILE"

echo ""
echo "=================================================================="
echo "  [READY] Extracted to: $DEST_DIR/port_bundle"
echo "  To flash REDMI K90, run:"
echo "    cd $DEST_DIR/port_bundle && bash flash_port_mac.sh"
echo "=================================================================="
