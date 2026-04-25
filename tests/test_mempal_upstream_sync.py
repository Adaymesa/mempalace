"""
Tests for hooks/mempal_upstream_sync.sh — deterministic upstream-rebase script.

Each test sets up a self-contained pair of git repos (upstream + fork + bare
origin) in a temp dir, plants a specific scenario, runs the script with
--repo pointing at the fork and --no-push to avoid network, and asserts on
exit code, branch state, and file contents.
"""

import os
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "hooks" / "mempal_upstream_sync.sh"


def _git(cwd, *args, check=True, capture=True):
    """Run `git ...` in cwd with isolated identity. Returns CompletedProcess."""
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "test",
        "GIT_AUTHOR_EMAIL": "test@test",
        "GIT_COMMITTER_NAME": "test",
        "GIT_COMMITTER_EMAIL": "test@test",
        "HOME": str(cwd),  # avoid touching real ~/.gitconfig
    }
    return subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        env=env,
        capture_output=capture,
        text=True,
        check=check,
    )


def _commit(repo, path, content, msg):
    full = repo / path
    full.parent.mkdir(parents=True, exist_ok=True)
    full.write_text(content)
    _git(repo, "add", path)
    _git(repo, "commit", "-q", "-m", msg)


def _run_script(repos, *extra_args):
    """Invoke the script under test, wired to the fixture's upstream remote."""
    cmd = [
        str(SCRIPT),
        "--repo", str(repos["fork"]),
        "--upstream", str(repos["upstream"]),
        "--no-push",
        *extra_args,
    ]
    return subprocess.run(cmd, capture_output=True, text=True)


@pytest.fixture
def repos(tmp_path):
    """Create upstream, bare origin, and fork (cloned from upstream).

    After this fixture:
      - upstream/main has 1 initial commit (README.md)
      - origin is a bare repo (so the script can `git push origin` without
        going to GitHub when tests opt in)
      - fork's `origin` points to the bare origin
      - fork has an `upstream` remote pointing at upstream
      - fork's main matches upstream's main
    """
    upstream = tmp_path / "upstream"
    upstream.mkdir()
    _git(upstream, "init", "-q", "-b", "main")
    _git(upstream, "config", "user.email", "test@test")
    _git(upstream, "config", "user.name", "test")
    _commit(upstream, "README.md", "initial\n", "initial")

    origin_bare = tmp_path / "origin.git"
    _git(tmp_path, "clone", "-q", "--bare", str(upstream), str(origin_bare))

    fork = tmp_path / "fork"
    _git(tmp_path, "clone", "-q", str(origin_bare), str(fork))
    # Repo-local identity so the script (invoked without our env vars) can commit.
    _git(fork, "config", "user.email", "test@test")
    _git(fork, "config", "user.name", "test")
    _git(fork, "remote", "add", "upstream", str(upstream))
    _git(fork, "fetch", "-q", "upstream")
    return {"upstream": upstream, "origin": origin_bare, "fork": fork}


# ---------- happy-path / no-op tests --------------------------------------


def test_already_up_to_date(repos):
    """When fork == upstream, script exits 0 with a clear no-op message."""
    out = _run_script(repos)
    assert out.returncode == 0, out.stderr
    assert "up to date" in (out.stdout + out.stderr).lower()


def test_clean_rebase_no_conflicts(repos):
    """Upstream advances, fork has independent commits — clean rebase."""
    fork = repos["fork"]
    upstream = repos["upstream"]

    # Upstream advances on a file the fork doesn't touch.
    _commit(upstream, "mempalace/cli.py", "print('upstream')\n", "upstream cli")
    _commit(upstream, "mempalace/searcher.py", "# searcher\n", "upstream searcher")

    # Fork commits something independent.
    _commit(fork, "hooks/local.sh", "#!/bin/bash\necho local\n", "fork hook")

    out = _run_script(repos)
    assert out.returncode == 0, f"stderr:\n{out.stderr}\nstdout:\n{out.stdout}"

    # Verify: branch was created, fork commit is on top, upstream commits are present.
    log = _git(fork, "log", "--oneline", "-10").stdout
    assert "fork hook" in log
    assert "upstream cli" in log
    assert "upstream searcher" in log

    branches = _git(fork, "branch").stdout
    assert "sync/upstream-rebase" in branches


# ---------- conflict-resolution rule tests --------------------------------


def test_conflict_in_hooks_uses_fork_version(repos):
    """Both sides modify hooks/foo.sh — fork's version wins."""
    fork = repos["fork"]
    upstream = repos["upstream"]

    # Both sides add a file with same name but different content.
    # We need to seed the file first so it's a true modify-modify conflict
    # rather than two independent adds.
    _commit(upstream, "hooks/shared.sh", "BASE\n", "seed shared")

    # Fork pulls the seed, then modifies.
    _git(fork, "fetch", "-q", "upstream")
    _git(fork, "merge", "-q", "upstream/main")
    _commit(fork, "hooks/shared.sh", "FORK_VERSION\n", "fork modifies shared")

    # Upstream modifies in a conflicting way.
    _commit(upstream, "hooks/shared.sh", "UPSTREAM_VERSION\n", "upstream modifies shared")

    out = _run_script(repos)
    assert out.returncode == 0, f"stderr:\n{out.stderr}\nstdout:\n{out.stdout}"

    # Fork's version should have won.
    assert (fork / "hooks" / "shared.sh").read_text() == "FORK_VERSION\n"


def test_conflict_in_mempalace_uses_upstream_version(repos):
    """Both sides modify mempalace/cli.py — upstream wins."""
    fork = repos["fork"]
    upstream = repos["upstream"]

    _commit(upstream, "mempalace/cli.py", "BASE\n", "seed cli")
    _git(fork, "fetch", "-q", "upstream")
    _git(fork, "merge", "-q", "upstream/main")
    _commit(fork, "mempalace/cli.py", "FORK_CLI\n", "fork cli")
    _commit(upstream, "mempalace/cli.py", "UPSTREAM_CLI\n", "upstream cli")

    out = _run_script(repos)
    assert out.returncode == 0, f"stderr:\n{out.stderr}\nstdout:\n{out.stdout}"

    assert (fork / "mempalace" / "cli.py").read_text() == "UPSTREAM_CLI\n"


def test_conflict_in_docs_uses_upstream_version(repos):
    """README.md conflict — upstream wins (docs rule)."""
    fork = repos["fork"]
    upstream = repos["upstream"]

    # README already exists from the initial commit; both modify it differently.
    (fork / "README.md").write_text("FORK_README\n")
    _git(fork, "add", "README.md")
    _git(fork, "commit", "-q", "-m", "fork readme")

    (upstream / "README.md").write_text("UPSTREAM_README\n")
    _git(upstream, "add", "README.md")
    _git(upstream, "commit", "-q", "-m", "upstream readme")

    out = _run_script(repos)
    assert out.returncode == 0, f"stderr:\n{out.stderr}\nstdout:\n{out.stdout}"

    assert (fork / "README.md").read_text() == "UPSTREAM_README\n"


def test_ambiguous_conflict_bails_cleanly(repos):
    """Conflict in a path with no rule — script exits non-zero with the file
    listed; rebase is left aborted (working tree clean) so the user can retry."""
    fork = repos["fork"]
    upstream = repos["upstream"]

    _commit(upstream, "weird/path/x.txt", "BASE\n", "seed weird")
    _git(fork, "fetch", "-q", "upstream")
    _git(fork, "merge", "-q", "upstream/main")
    _commit(fork, "weird/path/x.txt", "FORK\n", "fork weird")
    _commit(upstream, "weird/path/x.txt", "UPSTREAM\n", "upstream weird")

    out = _run_script(repos)
    assert out.returncode != 0, "should fail when conflict has no rule"
    assert "weird/path/x.txt" in (out.stdout + out.stderr)

    # After bail, working tree should be clean (rebase aborted).
    status = _git(fork, "status", "--porcelain").stdout
    assert status == "", f"working tree dirty after bail: {status!r}"


# ---------- preflight tests -----------------------------------------------


def test_dirty_tree_refused(repos):
    """Script refuses to run if working tree is dirty."""
    fork = repos["fork"]
    (fork / "dirty.txt").write_text("uncommitted\n")
    # Untracked file alone shouldn't block (would be too restrictive).
    # But a tracked + modified file should.
    _commit(fork, "tracked.txt", "v1\n", "track")
    (fork / "tracked.txt").write_text("v2\n")  # uncommitted change

    out = _run_script(repos)
    assert out.returncode != 0
    assert "dirty" in (out.stderr + out.stdout).lower() or "uncommitted" in (out.stderr + out.stdout).lower()


def test_upstream_remote_with_wrong_url_refused(repos):
    """If `upstream` remote already exists but points elsewhere, script refuses
    rather than silently using the wrong remote or overwriting it."""
    fork = repos["fork"]
    # Override the existing upstream remote with the wrong URL.
    _git(fork, "remote", "set-url", "upstream", "https://example.com/wrong.git")

    out = subprocess.run(
        [
            str(SCRIPT),
            "--repo", str(fork),
            "--no-push",
            "--upstream", "https://github.com/milla-jovovich/mempalace.git",
        ],
        capture_output=True,
        text=True,
    )
    assert out.returncode != 0
    assert "upstream" in (out.stderr + out.stdout).lower()


def test_upstream_remote_already_correct_is_reused(repos):
    """If `upstream` remote already exists with the right URL, script proceeds."""
    fork = repos["fork"]
    upstream = repos["upstream"]
    # Fixture already added upstream pointing at upstream dir; pass the same URL.
    _commit(upstream, "mempalace/x.py", "u\n", "u")
    _commit(fork, "hooks/y.sh", "f\n", "f")

    out = subprocess.run(
        [
            str(SCRIPT),
            "--repo", str(fork),
            "--no-push",
            "--upstream", str(upstream),
        ],
        capture_output=True,
        text=True,
    )
    assert out.returncode == 0, f"stderr:\n{out.stderr}\nstdout:\n{out.stdout}"


def test_branch_already_exists_is_recreated(repos):
    """If the target sync branch already exists from a prior run, recreate it."""
    fork = repos["fork"]
    upstream = repos["upstream"]
    _commit(upstream, "mempalace/x.py", "u\n", "u")

    # Create a stale branch with an unrelated commit.
    today_branch = subprocess.run(
        ["date", "+sync/upstream-rebase-%Y%m%d"], capture_output=True, text=True
    ).stdout.strip()
    _git(fork, "checkout", "-q", "-b", today_branch)
    _commit(fork, "stale.txt", "stale\n", "stale commit")
    _git(fork, "checkout", "-q", "main")

    out = _run_script(repos)
    assert out.returncode == 0, f"stderr:\n{out.stderr}\nstdout:\n{out.stdout}"

    # Stale commit should NOT be on the recreated branch.
    log = _git(fork, "log", "--oneline", today_branch).stdout
    assert "stale commit" not in log


# ---------- additional edge cases -----------------------------------------


def test_untracked_files_do_not_block(repos):
    """Untracked files in the fork must not trigger the dirty-tree refusal —
    they're not part of the rebase. Real users have scratch files lying around."""
    fork = repos["fork"]
    upstream = repos["upstream"]

    _commit(upstream, "mempalace/y.py", "u\n", "upstream change")
    (fork / "scratch.txt").write_text("untracked\n")
    (fork / "hooks").mkdir(exist_ok=True)
    (fork / "hooks" / "wip.sh").write_text("#!/bin/bash\n# WIP\n")

    out = _run_script(repos)
    assert out.returncode == 0, f"stderr:\n{out.stderr}\nstdout:\n{out.stdout}"
    # Untracked files survive intact (rebase only touches tracked files).
    assert (fork / "scratch.txt").read_text() == "untracked\n"
    assert (fork / "hooks" / "wip.sh").read_text() == "#!/bin/bash\n# WIP\n"


def test_fork_commit_superseded_does_not_break(repos):
    """If a fork commit makes exactly the same change as an upstream commit,
    the resulting rebase commit becomes empty — script must skip it cleanly,
    not exit non-zero or leave the rebase half-done."""
    fork = repos["fork"]
    upstream = repos["upstream"]

    # Both add a file with identical content but in different commits.
    # During rebase, fork's commit becomes empty after upstream's lands.
    _commit(upstream, "mempalace/dup.py", "same content\n", "upstream adds dup")
    _commit(fork, "mempalace/dup.py", "same content\n", "fork adds dup")

    out = _run_script(repos)
    assert out.returncode == 0, f"stderr:\n{out.stderr}\nstdout:\n{out.stdout}"
    # File must still be present in the rebased tree.
    assert (fork / "mempalace" / "dup.py").read_text() == "same content\n"
