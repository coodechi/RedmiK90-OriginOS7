#!/usr/bin/env bash
set -euo pipefail

# Unified ROM fetcher with automatic protocol detection & ModelScope .parts.json merge.
# Usage: 01_fetch_rom.sh <source> <output_file>
#
# Supported <source> formats:
#   1. ms://<owner>/<dataset_repo>/<path/to/file>            (Single file OR *.parts.json manifest!)
#   2. https://modelscope.cn/datasets/<owner>/<repo>/...     (ModelScope Dataset web/resolve URL)
#   3. hf://<owner>/<dataset_repo>/<path/to/file>            (Hugging Face Dataset)
#   4. https://... or http://...                             (Direct URL via aria2c, 16 connections)
#   5. rclone://<remote>:<path/to/file>                      (rclone remote)

SOURCE="${1:?Missing source URI or URL}"
OUTFILE="${2:?Missing output file path}"

mkdir -p "$(dirname "$OUTFILE")"

download_ms() {
  local repo_id="$1"
  local filename="$2"
  local revision="${3:-master}"

  echo "Fetching from ModelScope Dataset (rev=${revision}, file=$(basename "$filename"))"
  python3 - "$repo_id" "$filename" "$revision" "$OUTFILE" <<'PYEOF'
import hashlib, json, os, shutil, sys
from modelscope_hub import HubApi

repo_id, filename, revision, outfile = sys.argv[1:5]
token = os.environ.get("MODELSCOPE_API_TOKEN") or None
endpoint = os.environ.get("MODELSCOPE_ENDPOINT") or "https://modelscope.cn"
dl_dir = os.path.join(os.path.dirname(outfile), ".ms_cache")
os.makedirs(dl_dir, exist_ok=True)

api = HubApi(token=token, endpoint=endpoint)

if filename.endswith(".parts.json"):
    manifest_path = str(api.download_file(repo_id, "dataset", filename, revision=revision, local_dir=dl_dir))
    with open(manifest_path, "r", encoding="utf-8") as mf:
        manifest = json.load(mf)
    parts = manifest["parts"]
    expected_total_sha = manifest.get("total_sha256")
    print(f"Detected chunked manifest: {len(parts)} parts, total {manifest['total_size']} bytes")

    total_hash = hashlib.sha256()
    with open(outfile, "wb") as out_f:
        for i, part in enumerate(parts, 1):
            pname = part["name"]
            remote_part = f"parts/{pname}"
            print(f"[{i}/{len(parts)}] Downloading {remote_part} ({part['size']/1024**2:.2f} MiB)...")
            p_local = str(api.download_file(repo_id, "dataset", remote_part, revision=revision, local_dir=dl_dir))
            p_hash = hashlib.sha256()
            with open(p_local, "rb") as pf:
                while True:
                    chunk = pf.read(16 * 1024 * 1024)
                    if not chunk:
                        break
                    out_f.write(chunk)
                    p_hash.update(chunk)
                    total_hash.update(chunk)
            if p_hash.hexdigest() != part["sha256"]:
                raise RuntimeError(f"SHA256 mismatch for {pname}: got {p_hash.hexdigest()}, expected {part['sha256']}")
            os.remove(p_local)
            print(f"  Verified & appended {pname} (deleted temp part to save disk)")

    if expected_total_sha and total_hash.hexdigest() != expected_total_sha:
        raise RuntimeError(f"Merged file SHA256 mismatch: got {total_hash.hexdigest()}, expected {expected_total_sha}")
    shutil.rmtree(dl_dir, ignore_errors=True)
    print(f"Successfully merged and verified {outfile} (sha256={total_hash.hexdigest()[:16]}...)")
else:
    downloaded = api.download_file(
        repo_id,
        "dataset",
        filename,
        revision=revision,
        local_dir=dl_dir,
    )
    shutil.move(str(downloaded), outfile)
    shutil.rmtree(dl_dir, ignore_errors=True)
    print(f"Moved ModelScope download to {outfile}")
PYEOF
}

download_hf() {
  local repo_id="$1"
  local filename="$2"
  local revision="${3:-main}"

  echo "Fetching from Hugging Face Dataset (rev=${revision}, file=$(basename "$filename"))"
  python3 - "$repo_id" "$filename" "$revision" "$OUTFILE" <<'PYEOF'
import os, shutil, sys
from huggingface_hub import hf_hub_download

repo_id, filename, revision, outfile = sys.argv[1:5]
token = os.environ.get("HF_TOKEN") or None
cache_dir = os.path.join(os.path.dirname(outfile), ".hf_cache")
os.makedirs(cache_dir, exist_ok=True)

downloaded = hf_hub_download(
    repo_id=repo_id,
    filename=filename,
    repo_type="dataset",
    revision=revision,
    token=token,
    local_dir=cache_dir,
)
shutil.move(downloaded, outfile)
shutil.rmtree(cache_dir, ignore_errors=True)
print(f"Moved HF download to {outfile}")
PYEOF
}

if [[ "$SOURCE" == ms://* ]]; then
  rest="${SOURCE#ms://}"
  owner="${rest%%/*}"; rest="${rest#*/}"
  repo="${rest%%/*}"; filepath="${rest#*/}"
  if [ -z "$owner" ] || [ -z "$repo" ] || [ -z "$filepath" ] || [ "$filepath" = "$repo" ]; then
    echo "ERROR: Invalid ms:// URI '$SOURCE'. Expected ms://<owner>/<dataset_repo>/<path/to/file>" >&2
    exit 1
  fi
  download_ms "${owner}/${repo}" "$filepath" "master"

elif [[ "$SOURCE" =~ ^https?://(www\.)?modelscope\.(cn|ai)/datasets/([^/]+/[^/]+)/(resolve|file/view)/([^/]+)/(.+)$ ]]; then
  repo_id="${BASH_REMATCH[3]}"
  revision="${BASH_REMATCH[5]}"
  filepath="${BASH_REMATCH[6]}"
  filepath="${filepath%%\?*}"
  download_ms "$repo_id" "$filepath" "$revision"

elif [[ "$SOURCE" == hf://* ]]; then
  rest="${SOURCE#hf://}"
  owner="${rest%%/*}"; rest="${rest#*/}"
  repo="${rest%%/*}"; filepath="${rest#*/}"
  if [ -z "$owner" ] || [ -z "$repo" ] || [ -z "$filepath" ] || [ "$filepath" = "$repo" ]; then
    echo "ERROR: Invalid hf:// URI '$SOURCE'. Expected hf://<owner>/<dataset_repo>/<path/to/file>" >&2
    exit 1
  fi
  download_hf "${owner}/${repo}" "$filepath" "main"

elif [[ "$SOURCE" =~ ^https?://(huggingface\.co|hf-mirror\.com)/datasets/([^/]+/[^/]+)/(resolve|blob)/([^/]+)/(.+)$ ]]; then
  repo_id="${BASH_REMATCH[2]}"
  revision="${BASH_REMATCH[4]}"
  filepath="${BASH_REMATCH[5]}"
  filepath="${filepath%%\?*}"
  download_hf "$repo_id" "$filepath" "$revision"

elif [[ "$SOURCE" == rclone://* ]]; then
  remote_path="${SOURCE#rclone://}"
  if [ ! -f "$HOME/.config/rclone/rclone.conf" ]; then
    echo "ERROR: ~/.config/rclone/rclone.conf not found. Please set GitHub Secret RCLONE_CONF." >&2
    exit 1
  fi
  echo "Fetching via rclone: $remote_path -> $OUTFILE"
  rclone copyto "$remote_path" "$OUTFILE" \
    --transfers 4 \
    --multi-thread-streams 8 \
    --retries 5 \
    --low-level-retries 10 \
    --stats 15s \
    --stats-one-line

elif [[ "$SOURCE" == http://* || "$SOURCE" == https://* ]]; then
  echo "Fetching via aria2c: $SOURCE -> $OUTFILE"
  aria2c \
    --allow-overwrite=true \
    --auto-file-renaming=false \
    --max-connection-per-server=16 \
    --split=16 \
    --min-split-size=10M \
    --max-tries=5 \
    --retry-wait=5 \
    --console-log-level=warn \
    --summary-interval=15 \
    -d "$(dirname "$OUTFILE")" \
    -o "$(basename "$OUTFILE")" \
    "$SOURCE"
else
  echo "ERROR: Unsupported source format '$SOURCE'. Use ms://..., https://..., hf://..., or rclone://..." >&2
  exit 1
fi

if [ ! -s "$OUTFILE" ]; then
  echo "ERROR: Downloaded file is missing or empty: $OUTFILE" >&2
  exit 1
fi

SIZE_BYTES=$(stat -c%s "$OUTFILE")
echo "Downloaded $(basename "$OUTFILE"): $SIZE_BYTES bytes"

# Sanity check: catch accidental HTML error/auth page downloads (< 100 MB)
if [ "$SIZE_BYTES" -lt 104857600 ]; then
  echo "ERROR: File size ($SIZE_BYTES bytes) is < 100 MB. Likely an HTML/auth error page instead of a ROM!" >&2
  file "$OUTFILE" || true
  head -c 512 "$OUTFILE" || true
  exit 1
fi
