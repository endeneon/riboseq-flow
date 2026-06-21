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
