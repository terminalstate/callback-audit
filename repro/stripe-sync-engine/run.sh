#!/bin/bash
# stripe/sync-engine service: a live webhook batch whose pipeline_sync ends with a failed eof is dropped, after the webhook
# endpoint has already answered Stripe 200. The repository's Temporal workflow code (TypeScript stripped, nothing else
# changed) runs under @temporalio/testing's local server, as in apps/service/src/__tests__/workflow.test.ts; only the
# pipelineSync activity is a stub that fails the first live batch.
# Needs Node 22+, npm and git (~450 MB in WORK_DIR, including the Temporal dev server download). Run: bash run.sh [WORK_DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"
COMMIT="${SYNC_ENGINE_COMMIT:-0cb8ca453d7ad266de714f83838f4e38565e8a57}"   # dev on 2026-10-20 (0.48.5)
mkdir -p "$WORK/tmp" && WORK="$(cd "$WORK" && pwd)" && cd "$WORK"
export TMPDIR="$WORK/tmp"
if [ ! -d sync-engine/.git ]; then
  git init -q sync-engine; git -C sync-engine remote add origin https://github.com/stripe/sync-engine
  git -C sync-engine fetch -q --depth 1 origin "$COMMIT"; git -C sync-engine checkout -q FETCH_HEAD
fi
cp "$HERE/package.json" "$HERE/build.mjs" "$HERE/live-batch.test.mjs" .
[ -d node_modules ] || npm install --no-audit --no-fund >/dev/null
mkdir -p node_modules/@stripe/sync-protocol
WF=apps/service/src/temporal/workflows/pipeline-lifecycle.ts
git -C sync-engine checkout -q -- "$WF"
echo "== workflow at $(git -C sync-engine log -1 --format='%h %cs')"
SYNC_ENGINE_ROOT="$WORK/sync-engine" node build.mjs && npx vitest run live-batch.test.mjs || true
echo "== with fix.patch"
git -C sync-engine apply "$HERE/fix.patch"
SYNC_ENGINE_ROOT="$WORK/sync-engine" node build.mjs && npx vitest run live-batch.test.mjs
git -C sync-engine checkout -q -- "$WF"
