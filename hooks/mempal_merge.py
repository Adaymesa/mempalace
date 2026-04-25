#!/usr/bin/env python3
"""
mempal_merge.py — Merge a peer MemPalace into the local one.

Idempotent merge of the `mempalace_drawers` ChromaDB collection. Drawer IDs in
MemPalace are deterministic (sha256 of wing+room+content[:100]), so the same
content on both machines maps to the same ID and we can skip re-embedding by
checking which IDs already exist locally.

Usage:
    python mempal_merge.py <path-to-peer-palace>

Where <path-to-peer-palace> is the directory that contains chroma.sqlite3
(the value of `palace_path` in ~/.mempalace/config.json on the peer).
"""

import json
import os
import sys
from pathlib import Path

import chromadb

COLLECTION = "mempalace_drawers"
PAGE = 500


def load_local_palace_path() -> str:
    cfg = Path.home() / ".mempalace" / "config.json"
    if cfg.exists():
        return json.loads(cfg.read_text()).get(
            "palace_path", str(Path.home() / ".mempalace" / "palace")
        )
    return str(Path.home() / ".mempalace" / "palace")


def merge(peer_path: str, local_path: str) -> dict:
    peer = chromadb.PersistentClient(path=peer_path).get_or_create_collection(COLLECTION)
    local = chromadb.PersistentClient(path=local_path).get_or_create_collection(COLLECTION)

    seen_peer = 0
    new_to_local = 0
    offset = 0
    while True:
        page = peer.get(include=["documents", "metadatas"], limit=PAGE, offset=offset)
        ids = page["ids"]
        if not ids:
            break
        seen_peer += len(ids)

        # Cheap existence check: include=[] returns ids only.
        existing = set(local.get(ids=ids, include=[])["ids"])
        new_idx = [i for i, did in enumerate(ids) if did not in existing]
        if new_idx:
            local.upsert(
                ids=[ids[i] for i in new_idx],
                documents=[page["documents"][i] for i in new_idx],
                metadatas=[page["metadatas"][i] for i in new_idx],
            )
            new_to_local += len(new_idx)

        offset += PAGE

    return {"peer_drawers_seen": seen_peer, "imported_to_local": new_to_local}


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    peer_path = os.path.abspath(os.path.expanduser(sys.argv[1]))
    if not os.path.isdir(peer_path):
        print(f"peer palace path not a directory: {peer_path}", file=sys.stderr)
        sys.exit(1)
    local_path = load_local_palace_path()
    if os.path.realpath(peer_path) == os.path.realpath(local_path):
        print(f"refusing to merge palace into itself ({peer_path})", file=sys.stderr)
        sys.exit(1)

    result = merge(peer_path, local_path)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
