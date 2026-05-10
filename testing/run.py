"""End-to-end test of the gitblob smart-HTTP server.

Drives a real `git` client against an already-running gitblob server through
the seven scenarios verified by hand (initial push, additional branch, clone,
force-push, fetch after force-push, ref delete, thin-pack push) and exits
non-zero if any check fails.

Each run uses a fresh, randomly-named repo on the server so reruns and
parallel runs don't collide.

Usage:
    uv run gitblob-e2e <url>          # e.g. http://127.0.0.1:8080
    uv run gitblob-e2e <url> --repo my-test   # pin the repo name

KEEP=1 in the env preserves the temp client workdir on exit (for debugging).
"""

from __future__ import annotations

import argparse
import os
import secrets
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

import fixture

# Same isolation we use in the fixture, plus prompt suppression for the
# git CLI so a missing credential helper can't hang the test.
CLIENT_ENV = {
    **fixture.FIXTURE_ENV,
    "GIT_TERMINAL_PROMPT": "0",
    "GIT_AUTHOR_NAME": "gitblob test",
    "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "gitblob test",
    "GIT_COMMITTER_EMAIL": "test@example.com",
}


# ── tty-aware reporting ─────────────────────────────────────────────────────

USE_COLOR = sys.stdout.isatty()


def _c(code: str, s: str) -> str:
    return f"\x1b[{code}m{s}\x1b[0m" if USE_COLOR else s


def section(msg: str) -> None:
    print(f"\n{_c('1', msg)}")


def note(msg: str = "") -> None:
    print(msg)


class Reporter:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0

    def ok(self, msg: str) -> None:
        print(f"  {_c('32', 'PASS')} {msg}")
        self.passed += 1

    def ng(self, msg: str) -> None:
        print(f"  {_c('31', 'FAIL')} {msg}")
        self.failed += 1

    def expect(self, cond: bool, msg: str) -> None:
        (self.ok if cond else self.ng)(msg)


# ── git helpers ────────────────────────────────────────────────────────────


def git(*args: str, cwd: Path | None = None, log: Path | None = None) -> int:
    """Run git, append stdout+stderr to `log`, return exit code (no raise)."""
    env = {**os.environ, **CLIENT_ENV}
    out = subprocess.DEVNULL if log is None else open(log, "ab")
    try:
        return subprocess.run(
            ["git", *args], cwd=cwd, env=env, stdout=out, stderr=out
        ).returncode
    finally:
        if log is not None:
            out.close()  # type: ignore[union-attr]


def git_out(*args: str, cwd: Path) -> str:
    env = {**os.environ, **CLIENT_ENV}
    return subprocess.check_output(["git", *args], cwd=cwd, env=env, text=True).strip()


def http_get(url: str) -> tuple[int, bytes]:
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


# ── scenarios ──────────────────────────────────────────────────────────────


def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument(
        "url", help="base URL of a running gitblob server (e.g. http://127.0.0.1:8080)"
    )
    p.add_argument(
        "--repo",
        default=f"e2e-{secrets.token_hex(4)}",
        help="repo name on the server (default: random)",
    )
    args = p.parse_args()

    base = args.url.rstrip("/")
    repo_url = f"{base}/{args.repo}.git"

    # Confirm the server is reachable before we start setting up state.
    try:
        urllib.request.urlopen(base, timeout=2)
    except urllib.error.HTTPError:
        pass  # any HTTP response means it's listening
    except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
        print(f"{_c('31', 'cannot reach server')} at {base}: {e}", file=sys.stderr)
        return 2

    workdir = Path(tempfile.mkdtemp(prefix="gitblob-test."))
    keep = os.environ.get("KEEP") == "1"
    client_log = workdir / "client.log"
    src_repo = workdir / "src"
    clone_dir = workdir / "clone"

    note(f"server : {base}")
    note(f"repo   : {args.repo}.git")
    note(f"workdir: {workdir}")
    fixture.build(src_repo)
    orig_main_oid = git_out("rev-parse", "main", cwd=src_repo)

    r = Reporter()
    try:
        # 1. initial push (auto-create repo)
        section("1. push origin main  (initial — repo auto-created)")
        git("remote", "remove", "origin", cwd=src_repo)  # ignore failure
        r.expect(
            git("remote", "add", "origin", repo_url, cwd=src_repo, log=client_log) == 0,
            "git remote add",
        )
        r.expect(
            git("push", "--quiet", "origin", "main", cwd=src_repo, log=client_log) == 0,
            "git push origin main",
        )
        # Server-side check: info/refs for the new repo now answers 200.
        status, _ = http_get(f"{repo_url}/info/refs?service=git-upload-pack")
        r.expect(status == 200, f"info/refs returns 200 (got {status})")

        # 2. push additional branch
        section("2. push origin feature  (additional branch)")
        r.expect(
            git("push", "--quiet", "origin", "feature", cwd=src_repo, log=client_log)
            == 0,
            "git push origin feature",
        )

        # 3. clone
        section(f"3. git clone {repo_url}")
        r.expect(
            git("clone", "--quiet", repo_url, str(clone_dir), log=client_log) == 0,
            "git clone",
        )
        r.expect(
            git_out("rev-parse", "main", cwd=clone_dir) == orig_main_oid,
            "clone main matches source",
        )
        branches = subprocess.check_output(
            ["git", "branch", "-r"],
            cwd=clone_dir,
            text=True,
            env={**os.environ, **CLIENT_ENV},
        )
        r.expect("origin/feature" in branches, "clone advertises origin/feature")

        # 4. force-push main (non-fast-forward)
        section("4. push --force origin main  (non-fast-forward)")
        amend_env = {
            **os.environ,
            **CLIENT_ENV,
            "GIT_AUTHOR_DATE": "2026-02-01T00:00:00+00:00",
            "GIT_COMMITTER_DATE": "2026-02-01T00:00:00+00:00",
        }
        subprocess.run(
            ["git", "commit", "--amend", "--no-edit", "--quiet"],
            cwd=src_repo,
            env=amend_env,
            check=True,
        )
        new_main_oid = git_out("rev-parse", "main", cwd=src_repo)
        r.expect(new_main_oid != orig_main_oid, "amend produced a new oid (test setup)")
        r.expect(
            git(
                "push",
                "--force",
                "--quiet",
                "origin",
                "main",
                cwd=src_repo,
                log=client_log,
            )
            == 0,
            "git push --force origin main",
        )

        # 5. incremental fetch — server falls back to full pack
        section("5. git fetch  (incremental — server returns full pack)")
        r.expect(
            git("fetch", "--quiet", "origin", "main", cwd=clone_dir, log=client_log)
            == 0,
            "git fetch origin main",
        )
        r.expect(
            git_out("rev-parse", "origin/main", cwd=clone_dir) == new_main_oid,
            "origin/main advanced to new oid",
        )

        # 6. delete remote ref
        section("6. push --delete origin feature")
        r.expect(
            git(
                "push",
                "--quiet",
                "origin",
                "--delete",
                "feature",
                cwd=src_repo,
                log=client_log,
            )
            == 0,
            "git push --delete feature",
        )
        _, adv = http_get(f"{repo_url}/info/refs?service=git-upload-pack")
        r.expect(
            b"refs/heads/feature" not in adv,
            "feature gone from info/refs advertisement",
        )

        # 7. follow-up push that produces a thin pack. Two pushes:
        #   7a seeds a large, low-redundancy blob the server now owns;
        #   7b makes a tiny in-place edit, so git ships the new blob as a
        #     delta against the seed (which lives in the server's ODB).
        # Whole-blob zlib won't beat the delta for incompressible content,
        # so pack-objects picks --thin. Earlier steps don't exercise this:
        # they only add whole new objects.
        section("7a. push origin main  (seed blob for thin-pack repro)")
        big = src_repo / "bigdata.bin"
        big.write_text(secrets.token_hex(32768))  # ~64 KiB random hex
        env = {**os.environ, **CLIENT_ENV}
        subprocess.run(["git", "add", "bigdata.bin"], cwd=src_repo, env=env, check=True)
        subprocess.run(
            ["git", "commit", "-q", "-m", "seed big blob"],
            cwd=src_repo,
            env=env,
            check=True,
        )
        r.expect(
            git("push", "--quiet", "origin", "main", cwd=src_repo, log=client_log) == 0,
            "git push origin main (seed)",
        )

        section("7b. push origin main  (follow-up — exercises thin-pack indexing)")
        data = big.read_text()
        big.write_text(data[:100] + "EDIT" + data[100:])
        subprocess.run(["git", "add", "bigdata.bin"], cwd=src_repo, env=env, check=True)
        subprocess.run(
            ["git", "commit", "-q", "-m", "tweak big blob"],
            cwd=src_repo,
            env=env,
            check=True,
        )
        r.expect(
            git("push", "--quiet", "origin", "main", cwd=src_repo, log=client_log) == 0,
            "git push origin main (thin pack)",
        )
        followup_oid = git_out("rev-parse", "main", cwd=src_repo)
        _, adv = http_get(f"{repo_url}/info/refs?service=git-upload-pack")
        r.expect(
            followup_oid.encode() in adv, "advertisement carries follow-up commit oid"
        )

    except Exception as exc:
        r.ng(f"unexpected error: {exc!r}")

    note()
    summary = f"passed: {r.passed}  failed: {r.failed}"
    print(
        _c("32", "all green") + "  " + summary
        if r.failed == 0
        else _c("31", "failures") + "  " + summary
    )

    if r.failed and client_log.exists() and client_log.stat().st_size:
        note()
        note(_c("2", "---- client log ----"))
        sys.stdout.write(client_log.read_text(errors="replace"))

    if keep:
        note(f"\npreserving {workdir} (KEEP=1)")
    else:
        import shutil

        shutil.rmtree(workdir, ignore_errors=True)

    return 1 if r.failed else 0


if __name__ == "__main__":
    sys.exit(main())
