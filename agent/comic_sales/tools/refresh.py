"""refresh_sales — app-triggered eBay sales refresh (Phase 3 step 4).

The "$" Update Sales footer icon in the app dispatches a request that lands here. This
launches the existing standalone eBay scraper (`agent/tools/backfill_sales.py`) as a
DETACHED background process and returns IMMEDIATELY — a full incremental sweep paces one
book per ~15 min (~3 hrs wall-clock), far longer than an A2A turn can block.

Local-only by construction: the scraper needs a RESIDENTIAL IP (eBay/Imperva blocks
datacenter/Cloud Run IPs), so this tool only makes sense on the developer's Mac. It wraps
the run in `caffeinate -i` so the machine doesn't idle-sleep mid-sweep.

A lock (PID file) prevents a second concurrent sweep — two scrapers hammering eBay from one
IP trips the rate limiter and gets the IP flagged.
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# agent/comic_sales/tools/refresh.py -> agent/
_AGENT_ROOT = Path(__file__).resolve().parents[2]
_BACKFILL = _AGENT_ROOT / "tools" / "backfill_sales.py"
_RUN_DIR = _AGENT_ROOT / "comic_sales" / ".refresh"
_PID_FILE = _RUN_DIR / "refresh.pid"


def _pid_alive(pid: int) -> bool:
    """True if a process with this pid currently exists (signal 0 probes without killing)."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # It exists but we don't own it — treat as alive (good enough for the lock).
        return True
    return True


def _running_pid() -> int | None:
    """The pid of an in-flight refresh, or None if there's no live run.

    A stale PID file (process already exited) is treated as 'not running'."""
    if not _PID_FILE.exists():
        return None
    try:
        pid = int(_PID_FILE.read_text().strip())
    except (ValueError, OSError):
        return None

    # The refresh is launched as a direct child of this (agent) process. When it finishes
    # it lingers as a ZOMBIE until reaped — and a zombie still answers os.kill(pid, 0), so
    # without reaping the lock would never release within one agent lifetime. Reap it here
    # (non-blocking): a reaped or finished child is no longer running. If it isn't our child
    # (e.g. it outlived an agent restart), waitpid raises and we fall back to the kill probe.
    try:
        reaped, _status = os.waitpid(pid, os.WNOHANG)
        if reaped == pid:
            return None  # the child had exited; now reaped
    except ChildProcessError:
        pass  # not our child this process lifetime — probe by signal instead
    except OSError:
        pass
    return pid if _pid_alive(pid) else None


def refresh_sales() -> dict:
    """Launch a background refresh of eBay sales for the whole watchlist.

    Scrapes only NEW sales since the last refresh (incremental) for every watched comic and
    writes them to Firestore. Runs detached in the background and returns immediately; the
    sweep itself takes a few hours because it is paced to stay under eBay's rate limit. Call
    this when the user asks to update, refresh, or fetch the latest sales/market data.

    Returns one of:
      {"status": "started", "message": ..., "log": ...}
      {"status": "already_running", "message": ..., "pid": ...}
      {"status": "error", "error": ...}
    """
    try:
        # Already in flight? Don't launch a second scraper against the same IP.
        existing = _running_pid()
        if existing is not None:
            return {
                "status": "already_running",
                "pid": existing,
                "message": (
                    "A sales refresh is already running in the background. It paces itself "
                    "to stay under eBay's rate limit, so give it a little while to finish "
                    "before starting another."
                ),
            }

        if not _BACKFILL.exists():
            return {"status": "error",
                    "error": f"Scraper not found at {_BACKFILL}. Cannot refresh sales."}

        # The scraper needs the [backfill] extra (curl_cffi). Fail loudly here rather than
        # launching a detached process that dies on import with no visible error.
        if importlib.util.find_spec("curl_cffi") is None:
            return {"status": "error",
                    "error": ("The eBay scraper dependencies aren't installed in this "
                              "environment (run `uv sync --extra backfill`).")}

        _RUN_DIR.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        log_path = _RUN_DIR / f"refresh-{stamp}.log"

        # Routine refresh: incremental (only sales newer than what we have), classifier on,
        # committing to Firestore, default 900s/book pacing.
        scraper_cmd = [
            sys.executable, str(_BACKFILL),
            "--incremental", "--classify", "--commit", "--max-pages", "1",
        ]
        # caffeinate -i keeps the Mac awake (no idle sleep) for the duration of the sweep.
        caffeinate = shutil.which("caffeinate")
        cmd = [caffeinate, "-i", *scraper_cmd] if caffeinate else scraper_cmd

        log_fh = open(log_path, "w")  # noqa: SIM115 — handed to the child; closed on its exit
        log_fh.write(
            f"# refresh_sales launched {stamp}\n# cmd: {' '.join(cmd)}\n\n"
        )
        log_fh.flush()

        # start_new_session detaches the child into its own session so it outlives this
        # A2A turn (and the agent process). stdin from /dev/null; output to the log file.
        proc = subprocess.Popen(  # noqa: S603
            cmd,
            cwd=str(_AGENT_ROOT),
            stdin=subprocess.DEVNULL,
            stdout=log_fh,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        log_fh.close()  # the child holds its own dup'd fd; our copy isn't needed

        _PID_FILE.write_text(str(proc.pid))

        # Tiny grace window to surface an immediate crash (bad interpreter, missing file)
        # as an error instead of a misleading "started".
        time.sleep(0.3)
        if proc.poll() is not None and proc.returncode != 0:
            return {"status": "error",
                    "error": (f"The refresh process exited immediately (code "
                              f"{proc.returncode}). See {log_path.name} for details.")}

        return {
            "status": "started",
            "log": str(log_path),
            "message": (
                "Started refreshing sales in the background. I'm checking every comic on "
                "your watchlist for new eBay sales since the last update. This runs at a "
                "steady, polite pace to stay under eBay's limits, so it can take a while — "
                "your prices will fill in as it goes. You can keep using the app meanwhile."
            ),
        }
    except Exception as exc:  # noqa: BLE001 — a raised tool aborts the A2A turn silently
        return {"status": "error", "error": f"Could not start the refresh: {exc}"}
