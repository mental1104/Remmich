#!/usr/bin/env bash
set -euo pipefail
# 只在独立、干净的工作副本执行；冲突保持现场，不覆盖任何分支历史。
cd "$(git rev-parse --show-toplevel)"
test -z "$(git status --porcelain)" || { echo 'Working tree must be clean' >&2; exit 1; }
git fetch origin main dev
git fetch https://github.com/Ender-Wang/Remmich.git main
target=$(git rev-parse FETCH_HEAD)
sync_id=$(date -u +%Y%m%d%H%M%S)-$$
git switch --create "codex/upstream-sync-$sync_id-main" origin/main
git merge --ff-only "$target"
git push origin HEAD:main
git switch --create "codex/upstream-sync-$sync_id-dev" origin/dev
git merge --no-edit origin/main
echo 'Merged main into integration branch; validate build/tests before pushing HEAD:dev.'
