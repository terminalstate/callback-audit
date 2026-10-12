#!/usr/bin/env bash
#
# Reproduction stand: medusajs/medusa, Stripe webhook signature verified only
# when the queued payment.webhook_received job runs.
#
# Usage:  ./run.sh [WORK_DIR]
#
#   WORK_DIR  new or empty directory to work in (default: a fresh directory
#             from mktemp). Everything the run creates stays inside it:
#             the clone, the corepack shims and cache, the yarn cache and the
#             logs. Remove it afterwards to reclaim the disk space (~3 GB).
#
# Steps: clone medusajs/medusa at the pinned commit, enable yarn 3.2.1 through
# corepack, `yarn install --immutable`, build @medusajs/payment-stripe and its
# workspace dependencies, copy the stand's test files in (new files only),
# run them with each workspace's own jest config, print a result table.
#
# Network: GitHub (fetch of the pinned commit) and the npm registry (yarn
# itself via corepack, and the packages). Tool telemetry is switched off.
#
# Requirements: bash, git, Node.js 22 (the packages declare >=22.22.0) with
# corepack, about 3 GB of free disk space.

set -euo pipefail

# Pinned commit (develop, 2.21.2). Override to run at another commit, e.g. a branch with a fix:
#   MEDUSA_REPO=https://github.com/<fork>/medusa.git MEDUSA_COMMIT=<sha> bash run.sh
COMMIT="${MEDUSA_COMMIT:-146c46b0ad1146b40595c8ef586c4d5890982603}"
REPO_URL="${MEDUSA_REPO:-https://github.com/medusajs/medusa.git}"

STAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK_DIR="${1:-}"
if [ -z "$WORK_DIR" ]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/medusa-webhook-stand.XXXXXX")"
fi
mkdir -p "$WORK_DIR"
if [ -n "$(ls -A "$WORK_DIR")" ]; then
  echo "WORK_DIR must be new or empty: $WORK_DIR" >&2
  exit 2
fi
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
REPO="$WORK_DIR/medusa"
LOGS="$WORK_DIR/logs"
mkdir -p "$LOGS"

step() { printf '\n==> %s\n' "$*"; }

# --- prerequisites ----------------------------------------------------------
for tool in git node corepack; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 2; }
done
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 22 ]; then
  echo "Node.js 22 or newer is required (found $(node --version))" >&2
  exit 2
fi

# --- environment ------------------------------------------------------------
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
# Fetch yarn itself from the npm registry instead of repo.yarnpkg.com.
export COREPACK_NPM_REGISTRY="${COREPACK_NPM_REGISTRY:-https://registry.npmjs.org}"
export COREPACK_HOME="${COREPACK_HOME:-$WORK_DIR/corepack}"
# Keep yarn's cache inside WORK_DIR, as a single copy.
export YARN_GLOBAL_FOLDER="${YARN_GLOBAL_FOLDER:-$WORK_DIR/yarn-global}"
export YARN_ENABLE_GLOBAL_CACHE="${YARN_ENABLE_GLOBAL_CACHE:-true}"
export YARN_ENABLE_TELEMETRY=0
export TURBO_TELEMETRY_DISABLED=1
export DO_NOT_TRACK=1
export MEDUSA_DISABLE_TELEMETRY=true

echo "work dir: $WORK_DIR"
echo "logs:     $LOGS"

# --- 1. clone the pinned commit ---------------------------------------------
step "1/6 fetch $REPO_URL @ $COMMIT"
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

# --- 2. yarn 3.2.1 through corepack -----------------------------------------
step "2/6 enable yarn through corepack (shims in $WORK_DIR/bin)"
mkdir -p "$WORK_DIR/bin"
corepack enable --install-directory "$WORK_DIR/bin" yarn
export PATH="$WORK_DIR/bin:$PATH"
YARN_VERSION="$(cd "$REPO" && yarn --version)"
echo "yarn $YARN_VERSION"

# --- 3. install -------------------------------------------------------------
step "3/6 yarn install --immutable (log: logs/install.log)"
(cd "$REPO" && yarn install --immutable) >"$LOGS/install.log" 2>&1 || {
  tail -n 30 "$LOGS/install.log" >&2
  exit 1
}
tail -n 1 "$LOGS/install.log"

# --- 4. build what the tests import -------------------------------------------
# The tests import the built @medusajs/framework (and, for the route test, the
# built @medusajs/payment-stripe), as the repository's unit tests do after
# `yarn build`. Only payment-stripe and its workspace dependencies are built.
step "4/6 build @medusajs/payment-stripe and its workspace dependencies (log: logs/build.log)"
(cd "$REPO" && yarn turbo run build --filter='@medusajs/payment-stripe...' \
  --concurrency=1 --no-daemon --output-logs=errors-only) >"$LOGS/build.log" 2>&1 || {
  tail -n 40 "$LOGS/build.log" >&2
  exit 1
}
grep -E 'Tasks:' "$LOGS/build.log" || true

# --- 5. add the stand's test files (new files only) -------------------------
step "5/6 copy test files"
TEST_FILES=()
while IFS= read -r rel; do
  rel="${rel#./}"
  if [ -e "$REPO/$rel" ]; then
    echo "refusing to overwrite an existing file: $rel" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$REPO/$rel")"
  cp "$STAND_DIR/tests/$rel" "$REPO/$rel"
  TEST_FILES+=("$rel")
  echo "added $rel"
done < <(cd "$STAND_DIR/tests" && find . -type f -name '*.spec.ts' | sort)
echo "tracked files changed in the clone: $(git -C "$REPO" status --porcelain --untracked-files=no | wc -l)"
git -C "$REPO" status --porcelain >"$LOGS/git-status.txt"

# --- 6. run the tests --------------------------------------------------------
step "6/6 run the tests with each workspace's jest config"
STRIPE_PKG=packages/modules/providers/payment-stripe
MEDUSA_PKG=packages/medusa
STRIPE_TEST=src/core/__tests__/webhook-verification-delay.spec.ts
MEDUSA_TEST=src/api/hooks/__tests__/payment-webhook-verification-delay.spec.ts

set +e
(cd "$REPO/$STRIPE_PKG" && ../../../../node_modules/.bin/jest --ci --verbose \
  --json --outputFile="$LOGS/jest-payment-stripe.json" \
  --runTestsByPath "$STRIPE_TEST") >"$LOGS/jest-payment-stripe.txt" 2>&1
STRIPE_EXIT=$?
(cd "$REPO/$MEDUSA_PKG" && ../../node_modules/.bin/jest --ci --verbose --forceExit \
  --json --outputFile="$LOGS/jest-medusa.json" \
  --runTestsByPath "$MEDUSA_TEST") >"$LOGS/jest-medusa.txt" 2>&1
MEDUSA_EXIT=$?
set -e

for f in "$LOGS/jest-payment-stripe.txt" "$LOGS/jest-medusa.txt"; do
  grep -E '^(PASS|FAIL) |^ +(✓|✕|○)|^Tests:' "$f" || true
done

# --- environment record --------------------------------------------------------
pkg_version() {
  node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version)' \
    "$REPO/node_modules/$1/package.json" 2>/dev/null || echo "?"
}
{
  echo "date (UTC):           $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "medusa commit:        $HEAD_SHA"
  echo "os:                   $(uname -srm)"
  echo "node:                 $(node --version)"
  echo "corepack:             $(corepack --version)"
  echo "yarn:                 $YARN_VERSION"
  echo "stripe (stripe-node): $(pkg_version stripe)"
  echo "jest:                 $(pkg_version jest)"
  echo "@swc/jest:            $(pkg_version @swc/jest)"
  echo "@swc/core:            $(pkg_version @swc/core)"
  echo "typescript:           $(pkg_version typescript)"
  echo "turbo:                $(pkg_version turbo)"
} >"$LOGS/env.txt"

# --- result table -------------------------------------------------------------
node - "$LOGS/jest-payment-stripe.json" "$LOGS/jest-medusa.json" >"$LOGS/summary.txt" <<'EOF'
const fs = require("fs")
const files = process.argv.slice(2)
const rows = []
for (const file of files) {
  let report
  try {
    report = JSON.parse(fs.readFileSync(file, "utf8"))
  } catch (e) {
    rows.push({ level: "?", kind: "?", jest: "no report", title: file })
    continue
  }
  for (const suite of report.testResults) {
    if (!suite.assertionResults.length) {
      rows.push({ level: "?", kind: "?", jest: "suite error", title: suite.name })
    }
    for (const a of suite.assertionResults) {
      const parent = a.ancestorTitles[0] || ""
      const level = parent.startsWith("StripeBase")
        ? "provider"
        : parent.includes("->")
          ? "route->job"
          : "route"
      const ifFixed = a.title.startsWith("if fixed:")
      rows.push({
        level,
        kind: ifFixed ? "if fixed (it.failing)" : "current behaviour",
        jest: a.status,
        title: a.title.replace(/^(current behaviour|if fixed): /, ""),
        reading: ifFixed
          ? a.status === "passed"
            ? "fails today, as expected while the bug is present"
            : "passes: the bug looks fixed"
          : a.status === "passed"
            ? "holds"
            : "does not hold",
      })
    }
  }
}
const current = rows.filter((r) => r.kind === "current behaviour")
const fixed = rows.filter((r) => r.kind.startsWith("if fixed"))
const head = ["#", "level", "kind", "jest", "reading", "test"]
const body = rows.map((r, i) => [String(i + 1), r.level, r.kind, r.jest, r.reading || "", r.title])
const width = head.map((h, c) => Math.max(h.length, ...body.map((b) => b[c].length)))
const line = (cells) => "| " + cells.map((x, c) => x.padEnd(width[c])).join(" | ") + " |"
console.log(line(head))
console.log("|" + width.map((w) => "-".repeat(w + 2)).join("|") + "|")
body.forEach((b) => console.log(line(b)))
const reproduced =
  current.length > 0 &&
  current.every((r) => r.jest === "passed") &&
  fixed.length > 0 &&
  fixed.every((r) => r.jest === "passed")
console.log("")
console.log(
  reproduced
    ? "Verdict: reproduced. All current-behaviour tests pass and the if-fixed test fails (as marked)."
    : "Verdict: NOT reproduced as described. See the rows above and the jest logs."
)
EOF

step "result (medusajs/medusa @ ${HEAD_SHA:0:7})"
cat "$LOGS/summary.txt"
echo
cat "$LOGS/env.txt"
echo
echo "jest exit codes: payment-stripe=$STRIPE_EXIT medusa=$MEDUSA_EXIT"
echo "full output: $LOGS"

if [ "$STRIPE_EXIT" -ne 0 ] || [ "$MEDUSA_EXIT" -ne 0 ]; then
  exit 1
fi
