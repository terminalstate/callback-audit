#!/usr/bin/env bash
#
# Reproduction stand: evershopcommerce/evershop, a Stripe charge.refunded
# webhook records a refund made in EverShop a second time.
#
# Usage:  ./run.sh [WORK_DIR]
#
#   WORK_DIR  new or empty directory to work in (default: a fresh directory
#             from mktemp). The clone, node_modules and logs stay inside it.
#
# Steps: fetch evershop at the pinned commit, `npm ci`, add the stand's test
# file (new file only), compile the way the repository's `npm test` expects
# (`npm run compile` and `npm run compile:db`), run jest on the Stripe module's
# unit tests, print the result.
#
# Network: GitHub (the pinned commit) and the npm registry.
# Requirements: bash, git, Node.js 22 with npm, about 1.5 GB of free disk.
#
# Another commit, e.g. the current dev branch:
#   EVERSHOP_COMMIT=<sha> bash run.sh

set -euo pipefail

# v2.3.0
COMMIT="${EVERSHOP_COMMIT:-f33f72cd02bc20fd5d9b2b111bdda46b79b77200}"
REPO_URL="${EVERSHOP_REPO:-https://github.com/evershopcommerce/evershop.git}"
TEST_REL=packages/evershop/src/modules/stripe/tests/unit/chargeRefundedWebhook.test.js

STAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK_DIR="${1:-}"
if [ -z "$WORK_DIR" ]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/evershop-refund-stand.XXXXXX")"
fi
mkdir -p "$WORK_DIR"
if [ -n "$(ls -A "$WORK_DIR")" ]; then
  echo "WORK_DIR must be new or empty: $WORK_DIR" >&2
  exit 2
fi
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
REPO="$WORK_DIR/evershop"
LOGS="$WORK_DIR/logs"
mkdir -p "$LOGS"

step() { printf '\n==> %s\n' "$*"; }

for tool in git node npm; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 2; }
done
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 22 ]; then
  echo "Node.js 22 or newer is required (found $(node --version))" >&2
  exit 2
fi

export npm_config_cache="$WORK_DIR/npm-cache"
export npm_config_update_notifier=false
export npm_config_fund=false
export npm_config_audit=false

echo "work dir: $WORK_DIR"

step "1/5 fetch $REPO_URL @ $COMMIT"
git init --quiet "$REPO"
git -C "$REPO" remote add origin "$REPO_URL"
git -C "$REPO" fetch --quiet --depth 1 origin "$COMMIT"
git -C "$REPO" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
if [ "$HEAD_SHA" != "$COMMIT" ]; then
  echo "unexpected HEAD $HEAD_SHA" >&2
  exit 1
fi
echo "HEAD = $HEAD_SHA"

# --ignore-scripts skips only the root `prepare` script (husky install).
step "2/5 npm ci (log: logs/install.log)"
(cd "$REPO" && npm ci --ignore-scripts) >"$LOGS/install.log" 2>&1 || {
  tail -n 30 "$LOGS/install.log" >&2
  exit 1
}

step "3/5 add the test file"
if [ -e "$REPO/$TEST_REL" ]; then
  echo "refusing to overwrite an existing file: $TEST_REL" >&2
  exit 1
fi
cp "$STAND_DIR/tests/$TEST_REL" "$REPO/$TEST_REL"
echo "added $TEST_REL"
echo "tracked files changed in the clone: $(git -C "$REPO" status --porcelain --untracked-files=no | wc -l)"

# The repository's jest config runs the compiled tests in packages/*/dist.
step "4/5 npm run compile && npm run compile:db (log: logs/compile.log)"
(cd "$REPO" && npm run compile && npm run compile:db) >"$LOGS/compile.log" 2>&1 || {
  tail -n 30 "$LOGS/compile.log" >&2
  exit 1
}

step "5/5 jest: packages/evershop/dist/modules/stripe"
set +e
(cd "$REPO" && ALLOW_CONFIG_MUTATIONS=true NODE_OPTIONS=--experimental-vm-modules \
  node node_modules/jest/bin/jest.js --ci --verbose \
  --json --outputFile="$LOGS/jest.json" packages/evershop/dist/modules/stripe) >"$LOGS/jest.txt" 2>&1
JEST_EXIT=$?
set -e

pkg_version() {
  node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version)' \
    "$REPO/node_modules/$1/package.json" 2>/dev/null || echo "?"
}

node - "$LOGS/jest.json" >"$LOGS/summary.txt" <<'EOF'
const fs = require("fs")
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"))
const ours = report.testResults.find((s) => s.name.endsWith("chargeRefundedWebhook.test.js"))
const others = report.testResults.filter((s) => s !== ours)
if (!ours || !ours.assertionResults.length) {
  console.log("The stand's test file did not run. See logs/jest.txt.")
  process.exit(0)
}
for (const a of ours.assertionResults) {
  console.log(`${a.status.padEnd(6)}  ${a.title}`)
}
const byTitle = (t) => ours.assertionResults.find((a) => a.title === t)?.status
const control = byTitle("records a refund made in the Stripe Dashboard once")
const partial = byTitle("does not record a partial refund a second time")
const full = byTitle("does not report a full refund twice")
const otherFailed = others.reduce((n, s) => n + s.assertionResults.filter((a) => a.status === "failed").length, 0)
const otherPassed = others.reduce((n, s) => n + s.assertionResults.filter((a) => a.status === "passed").length, 0)
console.log("")
console.log(`Other tests of the Stripe module: ${otherPassed} passed, ${otherFailed} failed.`)
if (control === "passed" && partial === "failed" && full === "failed") {
  console.log("Verdict: reproduced. The webhook records the refund a second time (partial and full).")
} else if (control === "passed" && partial === "passed" && full === "passed") {
  console.log("Verdict: not reproduced. All three tests pass: the refund is recorded once.")
} else {
  console.log("Verdict: unexpected combination. See logs/jest.txt.")
}
EOF

{
  echo "date (UTC):       $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "evershop commit:  $HEAD_SHA"
  echo "os:               $(uname -srm)"
  echo "node:             $(node --version)"
  echo "npm:              $(npm --version)"
  echo "stripe (node):    $(pkg_version stripe)"
  echo "jest:             $(pkg_version jest)"
  echo "@swc/core:        $(pkg_version @swc/core)"
} >"$LOGS/env.txt"

step "result (evershopcommerce/evershop @ ${HEAD_SHA:0:7})"
cat "$LOGS/summary.txt"
echo
cat "$LOGS/env.txt"
echo
echo "jest exit code: $JEST_EXIT (1 is expected while the bug is present)"
echo "full output: $LOGS"
