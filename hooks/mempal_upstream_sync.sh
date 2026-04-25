#!/bin/bash
# mempal_upstream_sync.sh — deterministic fork rebase against upstream.
# Path-based conflict-resolution rules; no LLM in the loop. Refuses to run on
# a dirty tree, refuses if `upstream` remote is configured to a different URL,
# bails loudly when a conflict has no matching rule.
#
# IMPORTANT — git rebase semantics:
#   During a rebase, the meanings of "ours" and "theirs" are INVERTED from a
#   normal merge:
#     - "ours"   = the rebase target (upstream/main + already-applied commits)
#     - "theirs" = the commit currently being re-applied (your fork's commit)
#   So to KEEP THE FORK'S CONTENT  -> git checkout --theirs <file>
#      to KEEP UPSTREAM'S CONTENT  -> git checkout --ours   <file>
#   Reversing this is the most common bug in scripts like this.

set -uo pipefail

REPO="$HOME/development/mempalace"
UPSTREAM_URL="https://github.com/milla-jovovich/mempalace.git"
BRANCH=""
DO_PUSH=1

usage() {
    sed -n '2,16p' "$0"
    cat <<EOF

Usage: $(basename "$0") [options]
  --repo PATH       Repo to operate on (default: \$HOME/development/mempalace)
  --upstream URL    Upstream remote URL (default: github.com/milla-jovovich/mempalace.git)
  --branch NAME     Sync branch name (default: sync/upstream-rebase-YYYYMMDD)
  --no-push         Skip push and PR creation; leave branch local for review
  --help            Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)     REPO="$2"; shift 2;;
        --upstream) UPSTREAM_URL="$2"; shift 2;;
        --branch)   BRANCH="$2"; shift 2;;
        --no-push)  DO_PUSH=0; shift;;
        --help|-h)  usage; exit 0;;
        *) echo "unknown arg: $1" >&2; usage >&2; exit 1;;
    esac
done

[ -z "$BRANCH" ] && BRANCH="sync/upstream-rebase-$(date +%Y%m%d)"

# --- preflight ----------------------------------------------------------------

if [ ! -d "$REPO/.git" ]; then
    echo "ERROR: $REPO is not a git repo" >&2
    exit 1
fi
cd "$REPO"

# Refuse if tracked files are modified or staged. Untracked files are fine —
# the rebase won't touch them.
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: working tree is dirty (uncommitted tracked changes); commit or stash first" >&2
    exit 1
fi

# Upstream remote: add if missing, refuse if present-but-wrong.
if existing="$(git remote get-url upstream 2>/dev/null)"; then
    if [ "$existing" != "$UPSTREAM_URL" ]; then
        echo "ERROR: upstream remote already points to '$existing', not '$UPSTREAM_URL'" >&2
        echo "       Fix with: git remote set-url upstream '$UPSTREAM_URL'" >&2
        exit 1
    fi
else
    git remote add upstream "$UPSTREAM_URL" || exit 1
fi

# Fetch.
if ! git fetch -q upstream; then
    echo "ERROR: git fetch upstream failed" >&2
    exit 1
fi

# Move to main (the rebase base).
git checkout -q main || { echo "ERROR: could not checkout main" >&2; exit 1; }

BEHIND="$(git rev-list --count main..upstream/main)"
if [ "$BEHIND" = "0" ]; then
    echo "Fork is already up to date with upstream/main"
    exit 0
fi
echo "Fork is $BEHIND commits behind upstream/main"

# --- branch + rebase ----------------------------------------------------------

# Recreate target branch from main. If the branch is currently checked out
# elsewhere, we're already on main so -D is safe.
git branch -D "$BRANCH" 2>/dev/null || true
git checkout -q -b "$BRANCH" main

# Try the rebase. If there are conflicts, resolve them rule-by-rule.
RB_LOG="$(mktemp -t mempal_rebase.XXXXXX)"
trap 'rm -f "$RB_LOG"' EXIT

if git rebase upstream/main >"$RB_LOG" 2>&1; then
    echo "Rebase clean (no conflicts)"
else
    REBASE_DIR="$(git rev-parse --git-path rebase-merge 2>/dev/null)"
    REBASE_DIR_APPLY="$(git rev-parse --git-path rebase-apply 2>/dev/null)"
    # If rebase isn't actually in progress, it failed for a non-conflict reason
    # (e.g. missing git identity, hook failure). Fail loudly with the log.
    if [ ! -d "$REBASE_DIR" ] && [ ! -d "$REBASE_DIR_APPLY" ]; then
        echo "ERROR: git rebase failed before applying any commits:" >&2
        cat "$RB_LOG" >&2
        exit 1
    fi
    while [ -d "$REBASE_DIR" ] || [ -d "$REBASE_DIR_APPLY" ]; do
        CONFLICTS="$(git diff --name-only --diff-filter=U)"
        if [ -z "$CONFLICTS" ]; then
            # In rebase but no unmerged files: continue (probably an empty commit).
            if ! GIT_EDITOR=true git rebase --continue >>"$RB_LOG" 2>&1; then
                # Try skipping an empty / superseded commit.
                if ! GIT_EDITOR=true git rebase --skip >>"$RB_LOG" 2>&1; then
                    echo "ERROR: rebase stuck (no conflicts but cannot continue)" >&2
                    cat "$RB_LOG" >&2
                    git rebase --abort 2>/dev/null
                    exit 1
                fi
            fi
            REBASE_DIR="$(git rev-parse --git-path rebase-merge 2>/dev/null)"
            REBASE_DIR_APPLY="$(git rev-parse --git-path rebase-apply 2>/dev/null)"
            continue
        fi

        UNRESOLVED=""
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            case "$f" in
                hooks/*|.claude-plugin/*|.codex-plugin/*|CLAUDE.md|AGENTS.md|.gitignore|.test-command)
                    # Keep fork's content. During rebase: fork = theirs.
                    if git checkout --theirs -- "$f" 2>/dev/null && git add -- "$f"; then
                        echo "  fork:     $f"
                    else
                        # Likely delete-modify: theirs deleted. Honor the delete.
                        git rm -f -- "$f" >/dev/null && echo "  fork:     $f (removed)"
                    fi
                    ;;
                mempalace/*|tests/*|pyproject.toml|uv.lock|.github/*|scripts/*)
                    # Keep upstream's content. During rebase: upstream = ours.
                    if git checkout --ours -- "$f" 2>/dev/null && git add -- "$f"; then
                        echo "  upstream: $f"
                    else
                        git rm -f -- "$f" >/dev/null && echo "  upstream: $f (removed)"
                    fi
                    ;;
                README.md|CHANGELOG.md|docs/*|MISSION.md|ROADMAP.md|SECURITY.md|CONTRIBUTING.md)
                    if git checkout --ours -- "$f" 2>/dev/null && git add -- "$f"; then
                        echo "  upstream: $f"
                    else
                        git rm -f -- "$f" >/dev/null && echo "  upstream: $f (removed)"
                    fi
                    ;;
                *)
                    UNRESOLVED="$UNRESOLVED $f"
                    ;;
            esac
        done <<< "$CONFLICTS"

        if [ -n "$UNRESOLVED" ]; then
            echo "ERROR: ambiguous conflicts (no rule for these paths):" >&2
            for f in $UNRESOLVED; do echo "  $f" >&2; done
            echo "Aborting rebase to leave a clean tree. Resolve manually then re-run." >&2
            git rebase --abort 2>/dev/null
            exit 2
        fi

        # All conflicts in this slice resolved. Continue.
        if ! GIT_EDITOR=true git rebase --continue >>"$RB_LOG" 2>&1; then
            # Continuing failed even after we resolved everything. Most likely
            # the resulting tree was empty (fork commit fully superseded).
            if ! GIT_EDITOR=true git rebase --skip >>"$RB_LOG" 2>&1; then
                echo "ERROR: rebase --continue / --skip both failed after resolving conflicts" >&2
                cat "$RB_LOG" >&2
                git rebase --abort 2>/dev/null
                exit 1
            fi
        fi

        REBASE_DIR="$(git rev-parse --git-path rebase-merge 2>/dev/null)"
        REBASE_DIR_APPLY="$(git rev-parse --git-path rebase-apply 2>/dev/null)"
    done
fi

# --- push + PR ----------------------------------------------------------------

if [ "$DO_PUSH" = "1" ]; then
    if ! git push -u origin "$BRANCH"; then
        echo "ERROR: git push failed" >&2
        exit 1
    fi
    if command -v gh >/dev/null 2>&1; then
        gh pr create \
            --base main --head "$BRANCH" \
            --title "chore: sync fork with $BEHIND upstream commits" \
            --body "Rebased fork onto upstream/main using path-based conflict rules. Review the diff before merging."
    else
        ORIGIN_URL="$(git remote get-url origin)"
        echo "gh not installed; open the PR manually."
        echo "  branch pushed: $BRANCH"
        echo "  origin:        $ORIGIN_URL"
    fi
else
    echo "Skipping push (--no-push). Branch $BRANCH ready locally."
fi
