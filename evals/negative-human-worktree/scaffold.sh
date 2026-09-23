#!/bin/bash
# Fixture: main plus exactly 3 extra branches, each with its own commit, so the
# agent can name a worktree per branch. Leaves main checked out.
set -eu
. "$(dirname "$0")/../_lib/fixture.sh"
git init -q -b main
echo "base" > notes.txt
fixture_commit "eval fixture: base commit on main"
git checkout -q -b feature/search
echo "search" > search.txt
fixture_commit "eval fixture: search work"
git checkout -q main
git checkout -q -b fix/login-timeout
echo "timeout" > timeout.txt
fixture_commit "eval fixture: timeout fix"
git checkout -q main
git checkout -q -b chore/deps
echo "deps" > deps.txt
fixture_commit "eval fixture: dependency bump"
git checkout -q main
stub_muse_home
