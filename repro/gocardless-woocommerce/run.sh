#!/bin/bash
# Harness for GoCardless for WooCommerce (woocommerce-gateway-gocardless), Pay by Bank: when the bank's answer is still "fulfilling" at the
# buyer's return (or the buyer never returns), only the billing_requests.fulfilled webhook can attach the payment to the order. The
# webhook is answered 200 and handled by an Action Scheduler job; if that job's GET /billing_requests/{id} fails once (timeout, 5xx),
# it returns false and nothing re-checks. Later payment events look the order up by the payment id it never stored, so the paid order
# stays pending and WooCommerce cancels it.
# A real WordPress site with WooCommerce and the plugin as released on WordPress.org (3.0.3 = GitHub develop 5dad5de), real webhook POSTs
# signed with the webhook secret (Webhook-Signature = HMAC-SHA256 of the body) to ?wc-api=wc_gateway_gocardless&request=webhook, the jobs
# run by Action Scheduler's own runner. Only the GoCardless API is faked (mu-plugin).
# Needs PHP 8 with mysqli, wp-cli, curl and MySQL/MariaDB (variables below).
# Run: DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=... bash run.sh [WORK_DIR]
# GC_PATCH=fix.patch applies a change to the plugin first (the fix proposed in the report).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH=""; [ -n "${GC_PATCH:-}" ] && PATCH="$(cd "$(dirname "$GC_PATCH")" && pwd)/$(basename "$GC_PATCH")"
WORK="${1:-$(mktemp -d)}"
GC_VERSION="${GC_VERSION:-3.0.3}"   # gateway file = GitHub develop 5dad5de (2026-10-18)
WP_VERSION="${WP_VERSION:-7.1.3}"; WC_VERSION="${WC_VERSION:-11.2.1}"
DB_HOST="${DB_HOST:-127.0.0.1:3306}"; DB_USER="${DB_USER:-root}"; DB_PASSWORD="${DB_PASSWORD:-}"; DB_NAME="${DB_NAME:-gocardless_stand}"
PORT="${PORT:-8900}"; URL="http://127.0.0.1:$PORT"; SECRET=stand-webhook-secret-invented

mkdir -p "$WORK" && cd "$WORK"
[ -f site/wp-load.php ] || wp core download --version="$WP_VERSION" --path=site --quiet
cd site
[ -f wp-config.php ] || wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost="$DB_HOST" --skip-check --quiet
php -r '[$h,$p]=array_pad(explode(":",$argv[1]),2,3306); $m=new mysqli($h,$argv[2],$argv[3],"",(int)$p); $m->query("CREATE DATABASE IF NOT EXISTS `".$argv[4]."`") or exit(1);' "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
if wp core is-installed 2>/dev/null; then echo "database $DB_NAME already has a WordPress site; use an empty database (DB_NAME=...)" >&2; exit 2; fi
wp core install --url="$URL" --title=Stand --admin_user=admin --admin_password=admin --admin_email=admin@example.test --skip-email --quiet
wp plugin install woocommerce --version="$WC_VERSION" --activate --quiet
wp plugin install woocommerce-gateway-gocardless --version="$GC_VERSION" --activate --quiet
[ -z "$PATCH" ] || (cd wp-content/plugins/woocommerce-gateway-gocardless && GIT_CEILING_DIRECTORIES="$(dirname "$PWD")" git apply "$PATCH")
mkdir -p wp-content/mu-plugins
cp "$HERE/stand-fake-gocardless.php" wp-content/mu-plugins/
wp eval-file "$HERE/seed.php"

php -d display_errors=0 -S "127.0.0.1:$PORT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

webhook() {  # $1 resource_type, $2 action, $3 link key, $4 link id, $5 order id; prints the HTTP status
  local out sig body
  out=$(php "$HERE/sign.php" "$1" "$2" "$3" "$4" "$5" "$SECRET"); sig=${out%%$'\n'*}; body=${out#*$'\n'}
  curl -s -o "$WORK/last-body.txt" -w '%{http_code}' -X POST "$URL/?wc-api=wc_gateway_gocardless&request=webhook" \
    -H 'Content-Type: application/json' -H "Webhook-Signature: $sig" --data-binary "$body"
}

scenario() {  # $1 = billing-request GET mode, $2 = label; leaves the order id in LAST_ID
  local id br code
  read -r id br < <(wp eval-file "$HERE/create-order.php")
  wp option update stand_gc_br "$1" --quiet; wp option update stand_gc_calls '[]' --format=json --quiet
  code=$(webhook billing_requests fulfilled billing_request "$br" "$id")
  echo "== $2: billing_requests.fulfilled -> HTTP $code; job: $(wp eval-file "$HERE/run-queue.php" | tr '\n' ' ')"
  echo "   $(wp eval-file "$HERE/check.php" "$id")"
  LAST_ID=$id; CODES="$CODES $code"
}

CODES=""
echo "plugin: woocommerce-gateway-gocardless $(wp plugin get woocommerce-gateway-gocardless --field=version)${PATCH:+ + $(basename "$PATCH")}"
if [ -n "$PATCH" ]; then
  scenario fail_then_ok "Pay by Bank, the job's GET billing_requests times out once"; A=$(wp eval-file "$HERE/check.php" "$LAST_ID")
  echo "   job 2 (re-queued): $(wp eval-file "$HERE/run-queue.php" | tr '\n' ' ')"
  A2=$(wp eval-file "$HERE/check.php" "$LAST_ID"); echo "   $A2"
  echo
  if [[ "$CODES" == " 200" && "$A" == *"status=pending"*"payment_id=-"* && "$A2" == *"status=processing paid_date=set payment_id=PM"* ]]; then
    echo "FIXED: the failed GET re-queues the event; the second run attaches the payment and the order is processing."
  else
    echo "NOT FIXED (HTTP:$CODES; after job 1: $A; after job 2: $A2)"
  fi
  exit 0
fi
scenario fail_then_ok "Pay by Bank, the job's GET billing_requests times out once"; A_ID=$LAST_ID
A=$(wp eval-file "$HERE/check.php" "$A_ID")
code=$(webhook payments confirmed payment "PM$A_ID" "$A_ID"); CODES="$CODES $code"
echo "   payments.confirmed -> HTTP $code; job: $(wp eval-file "$HERE/run-queue.php" | tr '\n' ' ')"
A1=$(wp eval-file "$HERE/check.php" "$A_ID"); echo "   $A1"
wp eval-file "$HERE/cancel-unpaid.php" "$A_ID"
A2=$(wp eval-file "$HERE/check.php" "$A_ID")
echo "   after wc_cancel_unpaid_orders(): $A2"
scenario ok "control: the GET succeeds"; B=$(wp eval-file "$HERE/check.php" "$LAST_ID")

echo
if [[ "$CODES" == " 200 200 200" && "$A" == *"status=pending paid_date=none payment_id=-"* && "$A1" == *"status=pending"*"payment_id=-"* \
   && "$A2" == *"status=cancelled"* && "$B" == *"status=processing paid_date=set payment_id=PM"* ]]; then
  echo "REPRODUCED: one failed GET in the billing_requests.fulfilled job leaves a paid Pay by Bank order without its payment: the webhook"
  echo "was answered 200, the job ends, payments.confirmed cannot find the order, and WooCommerce cancels it. With the GET succeeding the"
  echo "same webhook completes the order."
else
  echo "NOT REPRODUCED (HTTP:$CODES; A: $A; after payments.confirmed: $A1; after cancel: $A2; control: $B)"
fi
