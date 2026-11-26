#!/usr/bin/env bash
set -euo pipefail

# Helper script to upload a local ROM file from macOS to a Hugging Face Private Dataset
# Supports resumable chunked uploads for 10GB+ files (far more reliable than browser upload!).
#
# Usage:
#   export HF_TOKEN="hf_xxxxxxxxxxxxxxxx"
#   # Optional (if uploading from Mainland China without proxy):
#   # export HF_ENDPOINT="https://hf-mirror.com"
#   bash scripts/local_upload_hf.sh <owner/dataset_repo> <local_file> [remote_filename]

REPO_ID="${1:?Usage: $0 <owner/dataset_repo> <local_file> [remote_filename]}"
LOCAL_FILE="${2:?Missing local file path}"
REMOTE_NAME="${3:-$(basename "$LOCAL_FILE")}"

if [ -z "${HF_TOKEN:-}" ]; then
  echo "ERROR: Please set HF_TOKEN environment variable first (export HF_TOKEN='hf_...')." >&2
  exit 1
fi

if [ ! -f "$LOCAL_FILE" ]; then
  echo "ERROR: Local file not found: $LOCAL_FILE" >&2
  exit 1
fi

if ! python3 -c "import huggingface_hub" >/dev/null 2>&1; then
  echo "Installing huggingface_hub into user Python environment..."
  python3 -m pip install --user -U huggingface_hub
fi

echo "Uploading '$LOCAL_FILE' -> Hugging Face Dataset '$REPO_ID' (path: '$REMOTE_NAME') ..."
python3 - "$REPO_ID" "$LOCAL_FILE" "$REMOTE_NAME" <<'PYEOF'
import os, sys
from huggingface_hub import HfApi

repo_id, local_file, remote_name = sys.argv[1:4]
api = HfApi(token=os.environ["HF_TOKEN"])

# Create private dataset automatically if it doesn't exist yet
api.create_repo(repo_id=repo_id, repo_type="dataset", private=True, exist_ok=True)

api.upload_file(
    path_or_fileobj=local_file,
    path_in_repo=remote_name,
    repo_id=repo_id,
    repo_type="dataset",
    commit_message=f"Upload {remote_name}",
)
print(f"\nUpload complete! Use this in GitHub Actions:\n  hf://{repo_id}/{remote_name}")
PYEOF
