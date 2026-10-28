#!/bin/bash
# Saleor Stripe app (saleor/apps, apps/stripe): a transient Stripe error in TRANSACTION_PROCESS_SESSION is answered with a final
# CHARGE_FAILURE on the PaymentIntent id, and the later payment_intent.succeeded is reported with an older time, so Saleor does
# not count the charge. Runs the app's own use cases in its vitest unit project; only Stripe's HTTP (fetch) and the outgoing
# Saleor call are faked, and the Stripe webhook is signed and verified for real.
# Needs git, Node 22 or 24 with corepack (pnpm comes from the repo's packageManager), about 1 GB. Run: bash run.sh [WORK_DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"
COMMIT="${SALEOR_APPS_COMMIT:-f001ac7eae74ff44d63c053e08e58e3e051a0da3}"   # main on 2026-10-28
TEST=src/app/api/webhooks/saleor/transaction-process-session/transient-stripe-error-masks-webhook-success.test.ts
mkdir -p "$WORK" && WORK="$(cd "$WORK" && pwd)" && cd "$WORK"
if [ ! -d apps-src/.git ]; then
  git init -q apps-src && git -C apps-src remote add origin https://github.com/saleor/apps
  git -C apps-src fetch -q --depth 1 origin "$COMMIT" && git -C apps-src checkout -q FETCH_HEAD
fi
cd apps-src
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
corepack pnpm install --filter "saleor-app-payment-stripe..." --frozen-lockfile >/dev/null
cp "$HERE/transient-stripe-error-masks-webhook-success.test.ts" "apps/stripe/$TEST"
cd apps/stripe
echo "== saleor/apps at $(git log -1 --format='%h %cs'), stripe $(node -p "JSON.parse(require('fs').readFileSync('node_modules/stripe/package.json')).version")"
# Expected while the bug is there: 3 passed. "if fixed" is an it.fails test, so it passes as long as the failure is final.
corepack pnpm exec vitest run --project unit "$TEST"
