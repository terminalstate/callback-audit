#!/usr/bin/env bash
# Harness for liberapay/liberapay.com: when stripe.Transfer.create fails inside the Stripe
# webhook, the transfer to the creator stays `pending`, the webhook answers 200 and nothing
# retries it. Runs tests/py/test_stripe_transfer_failure.py in the project's own test setup
# (pytest, real Postgres), first on the pinned commit, then with each of the two candidate
# fixes, plus the existing modules that cover the changed code.
#
#   LIBERAPAY_DIR=<checkout> PYTHON=<python with the deps> PSQL=<psql> \
#   DATABASE_URL="host=... port=... user=... dbname=liberapay_tests" ./run.sh
#
# LIBERAPAY_DIR  checkout of liberapay/liberapay.com; default: clone into $TMPDIR/liberapay-stand
# PYTHON         Python >= 3.12 with requirements_base.txt + pytest, vcrpy, html5lib, Faker
# DATABASE_URL   an empty database the schema can be (re)created in; written to tests/local.env
#                of the checkout (git-ignored there) and removed at the end
# PSQL           psql binary for recreate-schema.sh (default: psql on PATH)
# LIBERAPAY_COMMIT  commit to test (default: master as of 2026-10-29)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PIN="${LIBERAPAY_COMMIT:-9f41a3a026768844ae7d5f3979c91fd6b1757f2e}"
DIR="${LIBERAPAY_DIR:-${TMPDIR:-/tmp}/liberapay-stand}"
PY="${PYTHON:-python3}"
: "${DATABASE_URL:?set DATABASE_URL}"

if [ ! -d "$DIR/.git" ]; then
  git clone -q https://github.com/liberapay/liberapay.com "$DIR" || exit 1
fi
git -C "$DIR" checkout -q "$PIN" || { git -C "$DIR" fetch -q origin "$PIN" && git -C "$DIR" checkout -q "$PIN"; } || exit 1
if [ -n "$(git -C "$DIR" status --porcelain)" ]; then
  echo "working tree of $DIR is not clean, refusing to touch it" >&2
  exit 1
fi

# Some containers have no /etc/services; then socket.getservbyname('http') fails while the
# app loads (liberapay/wireup.py). Shim it, outside the checkout.
SHIM="$(mktemp -d)"
if ! "$PY" -c "import socket; socket.getservbyname('http', 'tcp')" 2>/dev/null; then
  cat > "$SHIM/sitecustomize.py" <<'PYEOF'
import socket as _s
_orig = _s.getservbyname
def getservbyname(name, proto=None):
    try:
        return _orig(name, proto) if proto else _orig(name)
    except OSError:
        port = {'http': 80, 'https': 443}.get(name)
        if port is None:
            raise
        return port
_s.getservbyname = getservbyname
PYEOF
fi

TEST=tests/py/test_stripe_transfer_failure.py
OLD="tests/py/test_payins.py tests/py/test_schedule.py tests/py/test_cron.py"
restore() {
  git -C "$DIR" checkout -q -- .
  rm -f "$DIR/$TEST" "$DIR/tests/local.env"
  rm -rf "$SHIM"
}
trap restore EXIT
cp "$HERE/$TEST" "$DIR/$TEST"
printf 'DATABASE_URL="%s"\n' "$DATABASE_URL" > "$DIR/tests/local.env"
cd "$DIR" || exit 1
run_env() { "$PY" cli/run.py -e defaults.env,tests/test.env,tests/local.env -s "PYTHONPATH=.:$SHIM" "$@"; }
if [ -n "${PSQL:-}" ]; then mkdir -p "$SHIM/bin" && ln -sf "$PSQL" "$SHIM/bin/psql"; fi
PATH="$SHIM/bin:$PATH" run_env ./recreate-schema.sh test >/dev/null 2>&1 || { echo "recreate-schema.sh failed" >&2; exit 1; }

step() {   # harness: every test's outcome and printed observations; existing modules: the summary line only
  local label="$1"; shift; echo; echo "== $label"
  case "$label" in
    *harness*) run_env "$PY" -m pytest -p no:cacheprovider -W ignore -q -rA --tb=line "$@" 2>&1 | grep -E '^(PASSED|FAILED)|passed|failed|answer|Transfer.create calls|final state' ;;
    *) run_env "$PY" -m pytest -p no:cacheprovider -W ignore -q --tb=line "$@" 2>&1 | grep -E '^FAILED| passed| failed' ;;
  esac
}
echo "liberapay.com at $(git rev-parse --short=7 HEAD), $("$PY" --version 2>&1)"
step "before: harness" "$TEST"
git apply "$HERE/fixes/fix-transfer-retry-webhook.patch" || exit 1
step "with fix-transfer-retry-webhook.patch: harness" "$TEST"
step "with fix-transfer-retry-webhook.patch: existing modules" $OLD
git checkout -q -- .
git apply "$HERE/fixes/fix-transfer-retry-cron.patch" || exit 1
step "with fix-transfer-retry-cron.patch: harness" "$TEST"
step "with fix-transfer-retry-cron.patch: existing modules" $OLD
