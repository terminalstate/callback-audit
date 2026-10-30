#!/usr/bin/env bash
#
# Reproduction stand: getlago/lago-api, three webhook paths that lose a payment state:
#   - Adyen CHARGEBACK: the queued job always raises, the lost dispute is never recorded;
#   - Flutterwave charge.completed: a failed verification call drops the paid charge, no retry;
#   - Stripe / Adyen refund failure after success: ignored, the credit note stays refunded.
#
# Usage:  ./run.sh [WORK_DIR]
#
# Needs: git, Ruby 4.0.6 with bundler 4.0.16 (the versions in .ruby-version and Gemfile.lock),
# PostgreSQL 15+ with the pg_partman extension, Redis, and the build tools for native gems
# (gcc, make, libpq-dev, libyaml-dev). The database user in DATABASE_URL must be allowed to
# create the database and extensions. Defaults below; override through the environment:
#   LAGO_API_COMMIT  commit to test (default: main as of 2026-10-17)
#   DATABASE_URL     postgres://lago:changeme@localhost:5432/lago_stand_test
#   REDIS_HOST_PORT  localhost:6379
#
# Network: GitHub and rubygems.org. The specs themselves make no network call (WebMock).
# RAILS_MASTER_KEY and SECRET_KEY_BASE are the test values from the project's CI workflow.

set -euo pipefail

COMMIT="${LAGO_API_COMMIT:-2520eba5856695c343a69e626d05a077f5ef9ba0}"
REPO_URL="${LAGO_API_REPO:-https://github.com/getlago/lago-api.git}"
STAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK_DIR="${1:-}"
if [ -z "$WORK_DIR" ]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lago-api-stand.XXXXXX")"
fi
mkdir -p "$WORK_DIR"
if [ -n "$(ls -A "$WORK_DIR")" ]; then
  echo "WORK_DIR must be new or empty: $WORK_DIR" >&2
  exit 2
fi
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
REPO="$WORK_DIR/lago-api"
LOGS="$WORK_DIR/logs"
mkdir -p "$LOGS"

step() { printf '\n==> %s\n' "$*"; }

for tool in git ruby bundle psql openssl; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 2; }
done

export RAILS_ENV=test
export DATABASE_URL="${DATABASE_URL:-postgres://lago:changeme@localhost:5432/lago_stand_test}"
REDIS_HOST_PORT="${REDIS_HOST_PORT:-localhost:6379}"
export LAGO_REDIS_CACHE_URL="redis://$REDIS_HOST_PORT"
export LAGO_REDIS_STORE_URL="$REDIS_HOST_PORT"
export LAGO_API_URL="https://api.lago.dev"
export LAGO_PDF_URL="https://pdf.lago.dev"
export LAGO_DATA_API_URL="http://data_api"
export LAGO_FROM_EMAIL="noreply@getlago.com"
export LAGO_DISABLE_SCHEMA_DUMP=true
export BUNDLE_PATH="$WORK_DIR/bundle"

step "1/5 fetch $REPO_URL @ $COMMIT"
git init --quiet "$REPO"
git -C "$REPO" remote add origin "$REPO_URL"
git -C "$REPO" fetch --quiet --depth 1 origin "$COMMIT"
git -C "$REPO" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
[ "$HEAD_SHA" = "$COMMIT" ] || { echo "unexpected HEAD $HEAD_SHA" >&2; exit 1; }
echo "HEAD = $HEAD_SHA"
echo "ruby $(ruby -e 'print RUBY_VERSION'), required $(cat "$REPO/.ruby-version")"
# The test-only keys the project's CI uses, read from its .github/workflows/spec.yml
ci_env() { sed -n "s/^ *$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\} *$/\1/p" "$REPO/.github/workflows/spec.yml" | head -n 1; }
RAILS_MASTER_KEY="$(ci_env RAILS_MASTER_KEY)"
SECRET_KEY_BASE="$(ci_env SECRET_KEY_BASE)"
export RAILS_MASTER_KEY SECRET_KEY_BASE
[ -n "$RAILS_MASTER_KEY" ] && [ -n "$SECRET_KEY_BASE" ] || { echo "could not read the CI keys from spec.yml" >&2; exit 1; }

step "2/5 bundle install (log: logs/bundle.log)"
(cd "$REPO" && bundle install --jobs 3) >"$LOGS/bundle.log" 2>&1 || { tail -n 30 "$LOGS/bundle.log" >&2; exit 1; }

step "3/5 RSA keys, database and schema (log: logs/db.log)"
(cd "$REPO" && ./scripts/generate.rsa.sh && bin/rails db:create db:schema:load:primary) >"$LOGS/db.log" 2>&1 || {
  tail -n 30 "$LOGS/db.log" >&2; exit 1; }

step "4/5 add the spec files (new files only)"
while IFS= read -r rel; do
  rel="${rel#./}"
  [ -e "$REPO/$rel" ] && { echo "refusing to overwrite an existing file: $rel" >&2; exit 1; }
  mkdir -p "$(dirname "$REPO/$rel")"
  cp "$STAND_DIR/tests/$rel" "$REPO/$rel"
  echo "added $rel"
done < <(cd "$STAND_DIR/tests" && find . -type f -name '*_spec.rb' | sort)
echo "tracked files changed in the clone: $(git -C "$REPO" status --porcelain --untracked-files=no | wc -l)"

step "5/5 rspec spec/requests/webhooks"
set +e
(cd "$REPO" && bundle exec rspec spec/requests/webhooks --format documentation --no-color) >"$LOGS/rspec.txt" 2>&1
RSPEC_EXIT=$?
set -e
# The documentation output only: from the first example group to the summary line.
awk '/^WebhooksController/{p=1} p' "$LOGS/rspec.txt" | grep -vE '^Unable to process|^Annotat|Coverage|^Progress|^\s+# ' |
  sed '/^Pending:/,/^Finished/{/^Finished/!d}' | sed '/examples, /q'
echo
echo "lago-api $HEAD_SHA, $(ruby -v), $(bundle -v), PostgreSQL $(psql --version | awk '{print $3}')"
echo "rspec exit code: $RSPEC_EXIT (0 with 3 pending = reproduced; a pending example that passes is reported as a failure)"
echo "full output: $LOGS"
exit "$RSPEC_EXIT"
