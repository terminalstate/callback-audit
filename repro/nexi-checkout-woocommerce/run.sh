#!/bin/bash
# Harness for Nexi Checkout (Nets Easy) for WooCommerce (dibs-easy-for-woocommerce): the payment.checkout.completed webhook is
# answered 200 at once and handled by one Action Scheduler job 120 s later; if that job's single GET /v1/payments/{id} fails
# (timeout, 5xx), it adds an order note and ends — nothing ever asks Nexi again. A Swish payment whose buyer did not come back
# stays pending, WooCommerce cancels the order, and the cancel hook skips Nexi because the plugin's own paid date is empty.
# A real WordPress site with WooCommerce and the plugin as released on WordPress.org (the GitHub tree has no vendor/), a real
# webhook POST to ?wc-api=DIBS_Api_Callbacks&dibs-payment-created-callback=1, the job run by Action Scheduler's own runner.
# Only the Nexi API is faked (mu-plugin). Needs PHP 8 with mysqli, wp-cli, curl and MySQL/MariaDB (variables below).
# Run: DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=... bash run.sh [WORK_DIR]
# NEXI_PATCH=fix.patch applies a change to the plugin first (the fix proposed in the report).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH=""; [ -n "${NEXI_PATCH:-}" ] && PATCH="$(cd "$(dirname "$NEXI_PATCH")" && pwd)/$(basename "$NEXI_PATCH")"
WORK="${1:-$(mktemp -d)}"
NETS_VERSION="${NETS_VERSION:-2.14.8}"   # = GitHub master 0ca3c3f (2026-10-06)
WP_VERSION="${WP_VERSION:-7.1.3}"; WC_VERSION="${WC_VERSION:-11.2.1}"
DB_HOST="${DB_HOST:-127.0.0.1:3306}"; DB_USER="${DB_USER:-root}"; DB_PASSWORD="${DB_PASSWORD:-}"; DB_NAME="${DB_NAME:-nets_stand}"
PORT="${PORT:-8899}"; URL="http://127.0.0.1:$PORT"

mkdir -p "$WORK" && cd "$WORK"
[ -f site/wp-load.php ] || wp core download --version="$WP_VERSION" --path=site --quiet
cd site
[ -f wp-config.php ] || wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost="$DB_HOST" --skip-check --quiet
php -r '[$h,$p]=array_pad(explode(":",$argv[1]),2,3306); $m=new mysqli($h,$argv[2],$argv[3],"",(int)$p); $m->query("CREATE DATABASE IF NOT EXISTS `".$argv[4]."`") or exit(1);' "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
if wp core is-installed 2>/dev/null; then echo "database $DB_NAME already has a WordPress site; use an empty database (DB_NAME=...)" >&2; exit 2; fi
wp core install --url="$URL" --title=Stand --admin_user=admin --admin_password=admin --admin_email=admin@example.test --skip-email --quiet
wp plugin install woocommerce --version="$WC_VERSION" --activate --quiet
wp plugin install dibs-easy-for-woocommerce --version="$NETS_VERSION" --activate --quiet
[ -z "$PATCH" ] || (cd wp-content/plugins/dibs-easy-for-woocommerce && GIT_CEILING_DIRECTORIES="$(dirname "$PWD")" git apply "$PATCH")
mkdir -p wp-content/mu-plugins
cp "$HERE/stand-fake-nexi.php" wp-content/mu-plugins/
wp eval-file "$HERE/seed.php"

php -d display_errors=0 -S "127.0.0.1:$PORT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

webhook() {  # $1 = payment id, $2 = order number, $3 = amount in öre; prints the HTTP status
  local body
  body=$(printf '{"id":"e-%s","merchantId":100017120,"timestamp":"2026-10-20T10:00:00.0000+00:00","event":"payment.checkout.completed","data":{"paymentId":"%s","order":{"reference":"%s","amount":{"amount":%d,"currency":"SEK"},"orderItems":[]}}}' "$1" "$1" "$2" "$3")
  curl -s -o "$WORK/last-body.txt" -w '%{http_code}' -X POST "$URL/?wc-api=DIBS_Api_Callbacks&dibs-payment-created-callback=1" \
    -H 'Content-Type: application/json' -H 'Authorization: stand-header-1234' --data-binary "$body"
}

scenario() {  # $1 = GET mode, $2 = payment id, $3 = label; leaves the order id in LAST_ID
  local id num amount code
  read -r id num amount < <(wp eval-file "$HERE/create-order.php" "$2")
  wp option update stand_nexi_get "$1" --quiet; wp option update stand_nexi_calls '[]' --format=json --quiet
  code=$(webhook "$2" "$num" "$amount")
  echo "== $3: payment.checkout.completed -> HTTP $code; scheduled: $(wp eval "echo count( as_get_scheduled_actions( array( 'hook' => 'dibs_payment_created_callback', 'status' => 'pending' ), 'ids' ) );")"
  echo "   job (+120 s): $(wp eval-file "$HERE/run-callback.php" | tr '\n' ' ')"
  echo "   $(wp eval-file "$HERE/check.php" "$id")"
  LAST_ID=$id; CODES="$CODES $code"
}

CODES=""
echo "plugin: dibs-easy-for-woocommerce $(wp plugin get dibs-easy-for-woocommerce --field=version)${PATCH:+ + $(basename "$PATCH")}"
if [ -n "$PATCH" ]; then
  scenario fail_then_ok 0123456789abcdef0123456789abcd03 "Swish, the job's GET times out once"; A=$(wp eval-file "$HERE/check.php" "$LAST_ID")
  echo "   job 2 (re-scheduled): $(wp eval-file "$HERE/run-callback.php" | tr '\n' ' ')"
  A2=$(wp eval-file "$HERE/check.php" "$LAST_ID"); echo "   $A2"
  echo
  if [[ "$CODES" == " 200" && "$A" == *"status=pending"*"pending_callbacks=1"* && "$A2" == *"status=processing paid_date=set"*"charge_id=c-1"*"pending_callbacks=0"* ]]; then
    echo "FIXED: the failed GET re-schedules the job; the second run confirms the Swish payment and the order is processing."
  else
    echo "NOT FIXED (HTTP:$CODES; after job 1: $A; after job 2: $A2)"
  fi
  exit 0
fi
scenario fail_then_ok 0123456789abcdef0123456789abcd01 "Swish, the job's GET times out once"; A_ID=$LAST_ID
A=$(wp eval-file "$HERE/check.php" "$A_ID")
wp eval-file "$HERE/cancel-unpaid.php" "$A_ID"
A2=$(wp eval-file "$HERE/check.php" "$A_ID")
echo "   after wc_cancel_unpaid_orders(): $A2"
scenario ok 0123456789abcdef0123456789abcd02 "control: the GET succeeds"; B=$(wp eval-file "$HERE/check.php" "$LAST_ID")

echo
if [[ "$CODES" == " 200 200" && "$A" == *"status=pending paid_date=none"*"error_notes=1 pending_callbacks=0"* \
   && "$A2" == *"status=cancelled"* && "$A2" == *"nexi_calls=[GET payments/0123456789abcdef0123456789abcd01]"* \
   && "$B" == *"status=processing paid_date=set"*"charge_id=c-1"* ]]; then
  echo "REPRODUCED: one failed GET in the deferred job ends the only path that confirms a Swish payment whose buyer did not come back:"
  echo "the webhook was already answered 200, nothing re-checks, WooCommerce cancels the order and the cancel hook never calls Nexi —"
  echo "although Nexi (the fake) answers 'charged' from the second call on. With the GET succeeding the same webhook completes the order."
else
  echo "NOT REPRODUCED (HTTP:$CODES; A: $A; after cancel: $A2; control: $B)"
fi
