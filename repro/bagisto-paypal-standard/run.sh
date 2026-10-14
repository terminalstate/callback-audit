#!/usr/bin/env bash
#
# Reproduction stand: bagisto/bagisto, PayPal Standard. A buyer who pays and does not come back to the store gets no
# order, and the IPN for that payment answers 500 until PayPal gives up.
#
# Usage:  DB_DATABASE=bagisto_stand bash run.sh [WORK_DIR]
#
#   WORK_DIR  new or empty directory to work in (default: a fresh directory from mktemp). The clone and the logs stay
#             inside it.
#
# Steps: clone Bagisto at the pinned commit, install its locked dependencies, point .env at the database below,
# `php artisan migrate --seed`, apply paypal-standard-ipn-test.patch (two Pest tests added to the project's own
# packages/Webkul/Paypal/tests/Feature/PaypalStandardTest.php), run that file, print the result.
#
# Requirements: bash, git, PHP 8.3 or 8.4 with the extensions in Bagisto's composer.json, Composer, and an empty
# MySQL or MariaDB database. Where Packagist is not reachable, the locked packages are fetched from their GitHub
# sources instead (python3 and ../invoiceninja/fetch_vendor.py, ../invoiceninja/write_installed.php; Composer is
# still needed to write the autoloader).
#
# Exit code: 0 when the bug reproduces (the new IPN test fails with 500/500 and the control test passes), 1 when it
# does not (for example on a commit with a fix), 2 on a setup error.

set -euo pipefail

# Pinned commit: 2.4 (the bug-fix branch) at 73e15b7, 2026-10-13. 2.5 needs PHP 8.4; its PayPal package is the same.
#   BAGISTO_COMMIT=<sha> BAGISTO_REPO=https://github.com/<fork>/bagisto.git bash run.sh   # another commit
COMMIT="${BAGISTO_COMMIT:-73e15b7c8e31a9d50a50250efc98a8c9d4e446c8}"
REPO_URL="${BAGISTO_REPO:-https://github.com/bagisto/bagisto.git}"

: "${DB_HOST:=127.0.0.1}"
: "${DB_PORT:=3306}"
: "${DB_USERNAME:=root}"
: "${DB_PASSWORD:=}"
: "${DB_DATABASE:=bagisto_stand}"
export DB_HOST DB_PORT DB_USERNAME DB_PASSWORD DB_DATABASE

STAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK_DIR="${1:-}"
if [ -z "$WORK_DIR" ]; then
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bagisto-paypal-stand.XXXXXX")"
fi
mkdir -p "$WORK_DIR"
if [ -n "$(ls -A "$WORK_DIR")" ]; then
  echo "WORK_DIR must be new or empty: $WORK_DIR" >&2
  exit 2
fi
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
REPO="$WORK_DIR/bagisto"
LOGS="$WORK_DIR/logs"
mkdir -p "$LOGS"

step() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 2; }

for tool in git php composer; do
  command -v "$tool" >/dev/null || die "missing: $tool"
done

# --- database must be empty ---------------------------------------------------
TABLES="$(php -r '
  try {
    $pdo = new PDO(sprintf("mysql:host=%s;port=%s;dbname=%s", getenv("DB_HOST"), getenv("DB_PORT"), getenv("DB_DATABASE")),
                   getenv("DB_USERNAME"), getenv("DB_PASSWORD"));
    echo count($pdo->query("SHOW TABLES")->fetchAll());
  } catch (Throwable $e) { fwrite(STDERR, $e->getMessage() . "\n"); exit(1); }
' 2>"$LOGS/db-check.txt")" || die "cannot connect to $DB_DATABASE on $DB_HOST:$DB_PORT as $DB_USERNAME: $(cat "$LOGS/db-check.txt")"
[ "$TABLES" = "0" ] || die "database $DB_DATABASE is not empty ($TABLES tables); use an empty one"

# --- clone --------------------------------------------------------------------
step "Cloning Bagisto at ${COMMIT:0:12}"
git init -q "$REPO"
git -C "$REPO" fetch -q --depth 1 "$REPO_URL" "$COMMIT"
git -C "$REPO" checkout -q FETCH_HEAD
echo "HEAD = $(git -C "$REPO" rev-parse HEAD)"

# --- dependencies -------------------------------------------------------------
cd "$REPO"
export COMPOSER_ALLOW_SUPERUSER=1
if [ "$(curl -sS -m 12 -o /dev/null -w '%{http_code}' https://repo.packagist.org/packages.json 2>/dev/null || true)" = "200" ]; then
  step "composer install (locked versions)"
  composer install -q --no-interaction --no-scripts >"$LOGS/composer.txt" 2>&1 || die "composer install failed, see $LOGS/composer.txt"
else
  step "Packagist not reachable: fetching the locked packages from their GitHub sources"
  command -v python3 >/dev/null || die "missing: python3"
  python3 "$STAND_DIR/../invoiceninja/fetch_vendor.py" . >"$LOGS/fetch-vendor.txt" 2>&1 || die "fetch failed, see $LOGS/fetch-vendor.txt"
  tail -1 "$LOGS/fetch-vendor.txt"
  cp "$(command -v composer)" "$WORK_DIR/composer.phar"
  cp "$STAND_DIR/../invoiceninja/write_installed.php" "$WORK_DIR/"
  php "$WORK_DIR/write_installed.php" >"$LOGS/write-installed.txt" 2>&1 || die "see $LOGS/write-installed.txt"
  composer dump-autoload -q --no-scripts >"$LOGS/dump-autoload.txt" 2>&1 || die "see $LOGS/dump-autoload.txt"
fi

# --- configure, migrate, seed -------------------------------------------------
step "Configuring .env, migrating and seeding $DB_DATABASE"
cp .env.example .env
php -r '
  $env = file_get_contents(".env");
  foreach (["DB_CONNECTION" => "mysql", "DB_HOST" => getenv("DB_HOST"), "DB_PORT" => getenv("DB_PORT"),
            "DB_DATABASE" => getenv("DB_DATABASE"), "DB_USERNAME" => getenv("DB_USERNAME"),
            "DB_PASSWORD" => getenv("DB_PASSWORD"), "APP_URL" => "http://localhost"] as $k => $v) {
      $env = preg_replace("/^" . $k . "=.*$/m", $k . "=" . $v, $env);
  }
  file_put_contents(".env", $env);
'
php artisan package:discover >"$LOGS/artisan.txt" 2>&1 || die "see $LOGS/artisan.txt"
php artisan key:generate --force >>"$LOGS/artisan.txt" 2>&1 || die "see $LOGS/artisan.txt"
php artisan migrate --seed --force >>"$LOGS/artisan.txt" 2>&1 || die "migrate --seed failed, see $LOGS/artisan.txt"

# --- tests --------------------------------------------------------------------
TEST=packages/Webkul/Paypal/tests/Feature/PaypalStandardTest.php
step "Adding the two IPN tests to $TEST"
git apply "$STAND_DIR/paypal-standard-ipn-test.patch"

step "Running $TEST"
set +e
php vendor/pestphp/pest/bin/pest --colors=never --log-junit "$LOGS/junit.xml" "$TEST" >"$LOGS/pest.txt" 2>&1
set -e
sed -n '/Tests:/p' "$LOGS/pest.txt"
[ -s "$LOGS/junit.xml" ] || die "no test report, see $LOGS/pest.txt"

# 1 = failed, 0 = passed, empty = not found
outcome() {
  php -r '
    $x = simplexml_load_file($argv[1]);
    foreach ($x->xpath("//testcase") as $t) {
      if (str_contains((string) $t["name"], $argv[2])) { echo (isset($t->failure) || isset($t->error)) ? 1 : 0; exit; }
    }' "$LOGS/junit.xml" "$1"
}
NO_RETURN="$(outcome 'when the buyer never returned')"
CONTROL="$(outcome 'after the buyer returned')"
STATUSES=""
if grep -q '^+    0 => 500,' "$LOGS/pest.txt" && grep -q '^+    1 => 500,' "$LOGS/pest.txt"; then STATUSES="500, 500"; fi
NO_RETURN_FAILED=0; CONTROL_PASSED=0
[ "$NO_RETURN" = "1" ] && NO_RETURN_FAILED=1
[ "$CONTROL" = "0" ] && CONTROL_PASSED=1

echo
echo "| test | result |"
echo "|---|---|"
echo "| IPN for a paid cart whose buyer never returned (expects 200, 200 and an order) | $([ $NO_RETURN_FAILED = 1 ] && echo "fails${STATUSES:+: the IPN answered $STATUSES}" || echo passes) |"
echo "| control: the same IPN after the buyer returned (expects 200 and processing) | $([ $CONTROL_PASSED = 1 ] && echo passes || echo fails) |"
echo
if [ $NO_RETURN_FAILED = 1 ] && [ $CONTROL_PASSED = 1 ]; then
  echo "REPRODUCED at $(git rev-parse --short HEAD): the IPN does not place the order for a buyer who never returned. Log: $LOGS/pest.txt"
  exit 0
fi
echo "NOT REPRODUCED at $(git rev-parse --short HEAD). Log: $LOGS/pest.txt"
exit 1
