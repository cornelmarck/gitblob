"""Build a deterministic local git repo for the gitblob tests.

Creates `main` (two commits) and `feature` (one extra commit) at the
target path. OIDs are stable across runs because every author/committer
field — including dates — is pinned via env vars.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

FIXTURE_ENV = {
    "GIT_AUTHOR_NAME": "gitblob fixture",
    "GIT_AUTHOR_EMAIL": "fixture@example.com",
    "GIT_COMMITTER_NAME": "gitblob fixture",
    "GIT_COMMITTER_EMAIL": "fixture@example.com",
    "GIT_AUTHOR_DATE": "2026-01-01T00:00:00+00:00",
    "GIT_COMMITTER_DATE": "2026-01-01T00:00:00+00:00",
    # Isolate from the host's git config so OIDs stay stable.
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_SYSTEM": "/dev/null",
}


def git(*args: str, cwd: Path) -> None:
    env = {**os.environ, **FIXTURE_ENV}
    subprocess.run(["git", *args], cwd=cwd, env=env, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def build(dest: Path) -> None:
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)

    git("init", "-q", "-b", "main", cwd=dest)
    git("config", "user.name",  FIXTURE_ENV["GIT_AUTHOR_NAME"], cwd=dest)
    git("config", "user.email", FIXTURE_ENV["GIT_AUTHOR_EMAIL"], cwd=dest)

    (dest / "README").write_text("hello, gitblob\n")
    git("add", "README", cwd=dest)
    git("commit", "-q", "-m", "init", cwd=dest)

    (dest / "README").write_text("hello, gitblob\nsecond line\n")
    git("add", "README", cwd=dest)
    git("commit", "-q", "-m", "extend", cwd=dest)

    git("checkout", "-q", "-b", "feature", cwd=dest)
    (dest / "feature.txt").write_text("feature work\n")
    git("add", "feature.txt", cwd=dest)
    git("commit", "-q", "-m", "feature: add file", cwd=dest)

    git("checkout", "-q", "main", cwd=dest)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("dest", type=Path, help="target directory (will be wiped)")
    args = p.parse_args()
    build(args.dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
