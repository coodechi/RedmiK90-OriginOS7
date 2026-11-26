#!/usr/bin/env python3
"""
Download a chunked ROM (.parts.json + .partXX) from ModelScope Private Dataset
in parallel (6 workers), verify SHA256 of every chunk, and write the manifest
filename to --manifest-out so GitHub Actions can upload all assets to a Private
GitHub Release.
"""

import argparse
import concurrent.futures
import hashlib
import json
import os
import shutil
import sys
import time
from modelscope_hub import HubApi


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="ms://<owner>/<dataset>/<path/to/file.parts.json>")
    ap.add_argument("--mirror-dir", required=True, help="Output directory for verified assets")
    ap.add_argument("--cache-dir", required=True, help="Temporary download cache directory")
    ap.add_argument("--manifest-out", required=True, help="File path to write manifest basename")
    args = ap.parse_args()

    if not args.src.startswith("ms://"):
        raise SystemExit("Invalid source URI: expected ms://<owner>/<dataset>/<path>.parts.json")

    rest = args.src[len("ms://"):]
    parts_split = rest.split("/", 2)
    if len(parts_split) < 3:
        raise SystemExit("Invalid ms:// URI: expected ms://<owner>/<dataset>/<path>")

    repo_id = f"{parts_split[0]}/{parts_split[1]}"
    file_path = parts_split[2]
    if not file_path.endswith(".parts.json"):
        raise SystemExit("Expected a .parts.json chunked manifest on ModelScope!")

    token = os.environ.get("MODELSCOPE_API_TOKEN")
    if not token:
        raise SystemExit("MODELSCOPE_API_TOKEN env var is required")
    endpoint = os.environ.get("MODELSCOPE_ENDPOINT") or "https://modelscope.cn"

    os.makedirs(args.mirror_dir, exist_ok=True)
    os.makedirs(args.cache_dir, exist_ok=True)

    api = HubApi(token=token, endpoint=endpoint)
    manifest_name = os.path.basename(file_path)
    print(f"[Mirror] Fetching manifest {manifest_name} ...", flush=True)
    m_local = str(api.download_file(repo_id, "dataset", file_path, revision="master", local_dir=args.cache_dir))
    shutil.copy2(m_local, os.path.join(args.mirror_dir, manifest_name))

    with open(m_local, "r", encoding="utf-8") as f:
        meta = json.load(f)

    chunk_list = meta["parts"]
    remote_dir = os.path.dirname(file_path)
    workers = min(6, len(chunk_list))
    print(f"[Mirror] Downloading {len(chunk_list)} chunks in parallel (workers={workers})...", flush=True)

    def dl_one(idx_part):
        idx, p = idx_part
        fname = p.get("name") or p.get("filename")
        candidates = [f"parts/{fname}"]
        if remote_dir:
            candidates.append(f"{remote_dir}/{fname}")
        candidates.append(fname)

        for attempt in range(1, 5):
            local_api = HubApi(token=token, endpoint=endpoint)
            last_err = None
            for rpath in candidates:
                try:
                    t0 = time.time()
                    print(f"  [{idx}/{len(chunk_list)}] Downloading {fname} (attempt {attempt})...", flush=True)
                    lp = str(
                        local_api.download_file(
                            repo_id, "dataset", rpath, revision="master", local_dir=args.cache_dir
                        )
                    )
                    h = hashlib.sha256()
                    with open(lp, "rb") as fp:
                        for blk in iter(lambda: fp.read(8 * 1024 * 1024), b""):
                            h.update(blk)
                    if h.hexdigest() != p["sha256"]:
                        raise RuntimeError(f"SHA256 mismatch on {fname}")
                    dst = os.path.join(args.mirror_dir, fname)
                    shutil.move(lp, dst)
                    dt = max(time.time() - t0, 0.1)
                    sz_mb = os.path.getsize(dst) / (1024 * 1024)
                    print(f"  [{idx}/{len(chunk_list)}] Verified {fname} ({sz_mb:.1f} MiB in {dt:.1f}s)", flush=True)
                    return fname
                except Exception as e:
                    last_err = e
                    continue
            print(f"  [WARN] {fname} attempt {attempt}/4 failed: {last_err}", flush=True)
            if attempt == 4:
                raise last_err
            time.sleep(attempt * 5)

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        futs = [ex.submit(dl_one, (i, p)) for i, p in enumerate(chunk_list, 1)]
        for fut in concurrent.futures.as_completed(futs):
            fut.result()

    with open(args.manifest_out, "w", encoding="utf-8") as mf:
        mf.write(manifest_name + "\n")
    print(f"[Mirror] All {len(chunk_list)} chunks + manifest ready in {args.mirror_dir}", flush=True)


if __name__ == "__main__":
    main()
