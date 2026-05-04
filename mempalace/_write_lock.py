"""Process-wide advisory write lock for chroma mutations.

ChromaDB serializes SQL transactions via SQLite locking, but the HNSW and
FTS5 maintenance steps that run between transactions are not atomic across
processes. When several MemPalace MCP servers (one per Claude Code
session) plus the miner subprocess from the auto-mine hook race on
``collection.upsert`` calls, the FTS5 inverted index and HNSW segment
files can end up inconsistent — observed in practice as "malformed
inverted index" and SIGSEGV in chromadb_rust_bindings.

This module provides a single context manager, ``write_lock()``, that
every chroma writer in the codebase wraps around its mutation. The lock
is a flock on ``~/.mempalace/.write.lock``; honoured cooperatively by all
callers that import this helper. Cross-process serialisation works as
long as everybody goes through here.
"""

from __future__ import annotations

import contextlib
import fcntl
import logging
import os
import time
from pathlib import Path

_LOCK_FILE = Path(os.path.expanduser("~/.mempalace/.write.lock"))
_LOCK_TIMEOUT_SEC = float(os.environ.get("MEMPALACE_WRITE_LOCK_TIMEOUT", "30"))

_logger = logging.getLogger("mempalace._write_lock")


@contextlib.contextmanager
def write_lock():
    """Acquire the process-wide chroma write lock; release on context exit.

    Blocks up to MEMPALACE_WRITE_LOCK_TIMEOUT seconds (default 30) waiting
    for the lock; raises TimeoutError if not acquired in time.
    """
    _LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(_LOCK_FILE), os.O_WRONLY | os.O_CREAT, 0o600)
    deadline = time.time() + _LOCK_TIMEOUT_SEC
    try:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except (OSError, BlockingIOError):
                if time.time() >= deadline:
                    raise TimeoutError(
                        f"Could not acquire MemPalace write lock within "
                        f"{_LOCK_TIMEOUT_SEC}s — another writer is busy."
                    )
                time.sleep(0.1)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except Exception:
            pass
        try:
            os.close(fd)
        except Exception:
            pass
