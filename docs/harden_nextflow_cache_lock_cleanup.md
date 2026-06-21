# Hardening Nextflow Cache‑Lock Cleanup (Session Summary)

> Repository scope: **`endeneon/riboseq-flow`** fork, branch `main`.
> A companion copy of this document lives in the `endeneon/riboseq` fork
> (nf‑core/riboseq), because the same hardened helper was added to both pipelines.

## Session Metadata

- **Date:** 2026-06-20
- **User:** szhang37 (St. Jude HPC, LSF cluster `hpcf_research_cluster`)
- **Project working dir (launch dir):** `/research/groups/tayl1grp/projects/tayl1grp_cab/common/TAYL1-870795-STRANDED`
  (also reachable as `/research_jude/rgs01_jude/groups/tayl1grp/.../TAYL1-870795-STRANDED` — the two paths resolve to the **same physical directory**).
- **Pipeline repo (this doc):** `/research_jude/rgs01_jude/groups/cab/projects/automapper/common/szhang37/pulled_git_repos/riboseq-flow` (`endeneon/riboseq-flow`, `main`).
- **Goal of session:** Make it safe to run multiple Nextflow pipelines concurrently from the same launch directory by giving riboseq‑flow a hardened stale cache‑lock cleanup mechanism at the pipeline level (it previously had none).

## Why this matters for riboseq‑flow

`bsub_riboseq_flow_run.sh` launches this pipeline from the **same** physical directory as the
nf‑core/riboseq submission scripts, so both share `.nextflow/history` and the
`.nextflow/cache/` parent. The nf‑core/riboseq forward/reverse scripts contained a
stale‑LOCK cleanup loop that globbed **every** `.nextflow/cache/*/db/LOCK` and used shell
`flock --nonblock`. A non‑destructive probe proved `flock` reports a **live** running job's
lock as `FREE`, so that loop could delete the live cache lock of a running riboseq‑flow job.
This session fixed the detection logic and gave riboseq‑flow its own (now safe) cleanup step,
which it previously lacked entirely.

## Tasks Completed

1. **Diagnosed an unrelated nf‑core/riboseq failure** (context only; that run is in the
   sibling pipeline). A forward run failed at the `RIBOWALTZ` publish step because stale
   output files on the NFSv4‑ACL `/research_jude` filesystem could not be overwritten
   (`java.nio.file.AccessDeniedException` on delete). After the user unlocked the files, the
   run resumed cleanly from cache.

2. **Analyzed concurrency between the two submission scripts.**
   - Safely separated: Nextflow work dirs, `--outdir`, run‑state files, logs, and LevelDB
     cache **session UUIDs** ⇒ no cache‑data collision.
   - **Shared:** `.nextflow/history` and the `.nextflow/cache/` parent (same launch dir).
   - **Hazard:** the sibling pipeline's `flock`‑based lock cleanup could delete a live
     riboseq‑flow cache lock; and riboseq‑flow had **no** stale‑lock cleanup of its own, so a
     leftover lock from an aborted riboseq‑flow run would make a later `-resume` fail with
     `Unable to acquire lock on session ...`.

3. **Added a hardened stale‑lock cleanup at the pipeline level** (this repo's code change).
   - Added `bin/clean_stale_nextflow_locks.py` to this fork. It probes each
     `.nextflow/cache/*/db/LOCK` with a non‑blocking **POSIX `fcntl`/`lockf`** lock — the
     same lock space LevelDB uses — so it distinguishes a dead lock from one held by a live
     run, including jobs on other cluster nodes.
   - Wired `bsub_riboseq_flow_run.sh` to call the helper before `nextflow run` (this script
     previously had no cleanup at all).

4. **Validated the change.**
   - `bash -n` passes on all edited submission scripts.
   - End‑to‑end: the helper, run from the login node (`noderome173`), correctly **kept** the
     live lock of a sibling job running on `noderome111` (`removed=0, kept=1`). The old
     `flock` check had called the same lock `FREE`.
   - Synthetic test: a genuinely stale lock (no owner) was removed (`removed=1, kept=0`).

## Key Decisions & Rationale

- **Cleanup must run before `nextflow run`.** Nextflow acquires the session/cache lock before
  any `main.nf`/DSL code executes, so stale‑lock cleanup cannot be embedded in the pipeline
  DSL. The maximally "pipeline‑level" form is a **versioned helper shipped in the fork's
  `bin/`**, invoked by the launcher script after the conda env is activated.
- **Use POSIX `fcntl`/`lockf`, not BSD `flock`.**
  - LevelDB holds a POSIX `fcntl` (`F_SETLK`) write lock on `db/LOCK`. On Linux, `flock(2)`
    and `fcntl(2)` are **independent lock spaces**, so a shell `flock` test never sees
    LevelDB's lock and reports live locks as free.
  - On NFS, `flock` is not coherent across nodes, whereas POSIX `fcntl` locks are coherent
    across cluster nodes via the NFS lock manager. A cross‑node probe confirmed `fcntl`
    correctly reports a remote live lock as held (`EAGAIN`).
- **Fail safe.** On any uncertainty (cannot open the file, unexpected errno) the helper keeps
  the lock rather than risk deleting a live one.
- **Correct liveness detection alone fixes the cross‑pipeline hazard.** Because the helper
  never deletes a lock held by any live run, riboseq‑flow and nf‑core/riboseq can safely share
  this launch dir's `.nextflow/cache`.

## Code Changes

### New file (this repo): `bin/clean_stale_nextflow_locks.py`

```python
#!/usr/bin/env python3
"""Remove ONLY genuinely-stale Nextflow LevelDB cache locks.

Nextflow stores its `-resume` cache as LevelDB databases under
``<launch_dir>/.nextflow/cache/<session-uuid>/db/``. While a Nextflow run is
alive it holds a POSIX (``fcntl``/``F_SETLK``) write lock on that database's
``LOCK`` file. A killed/aborted run can leave the ``LOCK`` file behind with no
live owner, and a later ``-resume`` then fails with
``Unable to acquire lock on session ...``.

The safe way to tell a *stale* lock from a *live* one is to attempt the SAME
kind of lock Nextflow/LevelDB uses -- a POSIX ``fcntl`` lock -- in non-blocking
mode:

* acquire succeeds  -> no live owner  -> lock is stale -> delete it
* acquire fails     -> a live run holds it -> leave it alone

Why not shell ``flock``? On Linux ``flock(2)`` (BSD) and ``fcntl(2)`` (POSIX)
are independent lock spaces, so ``flock`` never sees LevelDB's POSIX lock and
reports a live lock as free -- which makes a ``flock``-based cleanup delete the
locks of RUNNING jobs. On NFS, ``flock`` is also not coherent across nodes,
whereas POSIX ``fcntl`` locks are coherent across cluster nodes via the NFS lock
manager. ``fcntl``/``lockf`` is therefore both the correct lock space and
cluster-safe, so this helper never deletes a lock held by another live run
(including a different pipeline that shares this launch dir's ``.nextflow/cache``).

Usage:
    clean_stale_nextflow_locks.py <path/to/.nextflow/cache>
"""

import errno
import fcntl
import glob
import os
import sys


def is_lock_live(lock_path):
    """Return True if a live process holds the POSIX lock on ``lock_path``.

    Returns None if the lock state cannot be determined (treated as "live" by
    the caller so we never delete a lock we are unsure about).
    """
    try:
        fd = os.open(lock_path, os.O_RDWR)
    except OSError:
        # Cannot open (perms / vanished) -> be conservative, do not delete.
        return None
    try:
        try:
            fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            if exc.errno in (errno.EACCES, errno.EAGAIN):
                return True  # held by a live Nextflow process
            return None  # unexpected error -> be conservative
        # We acquired it -> no live owner. Release before returning.
        fcntl.lockf(fd, fcntl.LOCK_UN)
        return False
    finally:
        os.close(fd)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write(
            "usage: clean_stale_nextflow_locks.py <.nextflow/cache dir>\n"
        )
        return 2

    cache_dir = argv[1]
    if not os.path.isdir(cache_dir):
        print("[clean-locks] no cache dir yet (%s); nothing to do" % cache_dir)
        return 0

    removed = 0
    kept = 0
    for lock_path in sorted(glob.glob(os.path.join(cache_dir, "*", "db", "LOCK"))):
        live = is_lock_live(lock_path)
        if live is None:
            print("[clean-locks] undetermined, keeping: %s" % lock_path)
            kept += 1
            continue
        if live:
            print("[clean-locks] live run, keeping:    %s" % lock_path)
            kept += 1
            continue
        try:
            os.remove(lock_path)
            removed += 1
            print("[clean-locks] removed stale lock:   %s" % lock_path)
        except OSError as exc:
            sys.stderr.write(
                "[clean-locks] could not remove %s: %s\n" % (lock_path, exc)
            )

    print("[clean-locks] done (removed=%d, kept=%d)" % (removed, kept))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

### Submission script that invokes this repo (located in the project working dir, not in the repo)

Path: `/research/groups/tayl1grp/projects/tayl1grp_cab/common/TAYL1-870795-STRANDED/bsub_riboseq_flow_run.sh`

This script previously had **no** stale‑lock cleanup. The following block was **added**
immediately after the run is marked in‑progress and before `nextflow run`:

```bash
# Mark run as in-progress before launching
echo "running" >"${RUN_STATE_FILE}"

# Remove ONLY genuinely-stale Nextflow cache LOCK files left by aborted runs.
# Hardened, pipeline-shipped helper (bin/clean_stale_nextflow_locks.py): it
# probes each .nextflow/cache/*/db/LOCK with a non-blocking POSIX fcntl lock --
# the same lock LevelDB uses -- so it can tell a dead lock from one held by a
# RUNNING job, including jobs on other cluster nodes and OTHER pipelines
# (e.g. nf-core/riboseq) that share this launch dir's .nextflow/cache. Requires
# python3 (provided by the conda env activated above).
python3 "${pipeline_dir}/bin/clean_stale_nextflow_locks.py" "${work_dir}/.nextflow/cache" ||
	echo "WARN: stale-lock cleanup helper failed; continuing without it." >&2
```

The helper is called **after** the script activates the conda env (which provides `python3`)
and **before** `nextflow run`. `${pipeline_dir}` already points at this repo.

## Outstanding Issues / Next Steps

- **Commit the new helper.** `bin/clean_stale_nextflow_locks.py` is a new, uncommitted file in
  this fork. Commit/push so the mechanism travels with the pipeline.
- **Shared `.nextflow/history`.** Concurrent runs from the same launch dir still append to one
  history file; this is benign and already mitigated by each script's per‑pipeline
  session‑selection logic, but launching each pipeline from its own directory would remove even
  this minor shared state.
- **Sibling pipeline.** The identical helper was added to `endeneon/riboseq`, and its
  `bsub_riboseq_ribo_forward.sh`/`_reverse.sh` scripts were rewired to call it in place of the
  unsafe `flock` loop.

## Context for LLM Handoff

A St. Jude riboseq project (`TAYL1-870795-STRANDED`) runs two unrelated Nextflow pipelines from
one launch directory: riboseq‑flow (fork `endeneon/riboseq-flow`, used by
`bsub_riboseq_flow_run.sh`) and nf‑core/riboseq (fork `endeneon/riboseq`, used by
`bsub_riboseq_ribo_forward.sh`/`_reverse.sh`). Because both launch from the same physical dir,
they share `.nextflow/history` and `.nextflow/cache/`. The nf‑core/riboseq scripts cleaned stale
cache locks with shell `flock`, which cannot see LevelDB's POSIX `fcntl` lock and could delete a
live riboseq‑flow cache lock; riboseq‑flow itself had no cleanup. The fix added a hardened,
pipeline‑shipped helper `bin/clean_stale_nextflow_locks.py` (POSIX `fcntl`/`lockf` liveness
probe, cross‑node coherent on NFS) to **both** forks and wired all three submission scripts to
call it (riboseq‑flow gains cleanup it never had; riboseq replaces its unsafe `flock` loop). The
helper was validated against a live running job (kept) and a synthetic stale lock (removed).
Remaining follow‑ups: commit the helper in both forks, and optionally isolate each pipeline in
its own launch dir to avoid sharing `.nextflow/history`.
