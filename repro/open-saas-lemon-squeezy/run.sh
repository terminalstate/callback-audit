#!/bin/bash
# Open SaaS (wasp-lang/open-saas, template/app): a Lemon Squeezy credits purchase by a customer who has no subscription is
# answered 400 on every delivery and the credits are never granted — order_created fetches the customer portal URL first and
# throws when Lemon Squeezy returns it as null. Runs the template's real webhook handler with the real Lemon Squeezy SDK under
# vitest; Wasp's generated modules are stand-ins (mocks/), and only Lemon Squeezy's API is faked (fetch). The request is
# signed with real HMAC. Needs git, Node 20+ and npm (~60 MB). Run: bash run.sh [WORK_DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"
COMMIT="${OPENSAAS_COMMIT:-c2c6285bdb14b040584505372ad9bb062a0bca11}"   # main on 2026-10-28
mkdir -p "$WORK" && WORK="$(cd "$WORK" && pwd)" && cd "$WORK"
if [ ! -d src/.git ]; then
  git init -q src; git -C src remote add origin https://github.com/wasp-lang/open-saas
  git -C src config core.sparseCheckout true
  printf 'template/app/src/payment/\ntemplate/app/src/shared/\n' > src/.git/info/sparse-checkout
  git -C src fetch -q --depth 1 --filter=blob:none origin "$COMMIT"; git -C src checkout -q FETCH_HEAD
fi
rm -rf app && mkdir -p app && cp -r src/template/app/src app/src
cp -r "$HERE/mocks" "$HERE/tests" "$HERE/vitest.config.ts" .
[ -f package.json ] || echo '{"name":"open-saas-ls-stand","private":true,"type":"module"}' > package.json
[ -d node_modules/vitest ] || npm install --silent --no-audit --no-fund --legacy-peer-deps \
  vitest@4.1.12 zod@4 express@5 @lemonsqueezy/lemonsqueezy.js@3.3.1
echo "== open-saas at $(git -C src log -1 --format='%h %cs'), @lemonsqueezy/lemonsqueezy.js $(node -p "require('./node_modules/@lemonsqueezy/lemonsqueezy.js/package.json').version")"
npx vitest run tests/lemonSqueezyCredits.test.ts || true
echo "== subscription_updated with status expired (template docs list no subscription_expired)"
npx vitest run tests/lemonSqueezyExpired.test.ts || true
echo "== with fix.patch"
(cd app && git init -q && git apply -p3 "$HERE/fix.patch")
npx vitest run tests/lemonSqueezyCredits.test.ts
