#!/bin/bash
# Harness for opencollective/opencollective-api: a contribution edited while its delayed charge is PROCESSING.
# Runs one mocha file in the project's own test setup against a real Postgres.
# Needs: Node 24 + npm, git, PostgreSQL >= 16 (pgcrypto, pg_trgm, btree_gist; PostGIS not needed) with psql, pg_restore,
# createdb, dropdb in PATH, and a `postgres` superuser without a password on PGHOST/PGPORT.
# Usage: PGHOST=127.0.0.1 PGPORT=5432 bash run.sh [WORK_DIR]
# Expected: first run 2 passing (control, current behaviour); second run (--grep "if fixed") 1 failing.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"
COMMIT="${OC_API_COMMIT:-d04af8f1c7d522427da0a83a0c299f891e0e5638}"   # main as of 2026-10-28
TEST=test/server/paymentProviders/stripe/inflight-edit-drops-payment-intent.test.ts
export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-5432}"
export PG_HOST="$PGHOST" PG_PORT="$PGPORT"

mkdir -p "$WORK" && cd "$WORK"
if [ ! -d opencollective-api/.git ]; then
  git init -q opencollective-api && git -C opencollective-api remote add origin https://github.com/opencollective/opencollective-api
  git -C opencollective-api fetch -q --depth 1 origin "$COMMIT" && git -C opencollective-api checkout -q FETCH_HEAD
fi
cd opencollective-api
[ -d node_modules ] || SKIP_POSTINSTALL=1 npm ci --no-audit --no-fund
NODE_ENV=test npm run db:restore:test >/dev/null
cp "$HERE/inflight-edit-drops-payment-intent.test.ts" "$TEST"
NODE_ENV=test TZ=UTC npx mocha "$TEST" --grep "if fixed" --invert
NODE_ENV=test TZ=UTC npx mocha "$TEST" --grep "if fixed" || echo "if fixed: fails as expected at $COMMIT"
