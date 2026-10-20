#!/bin/bash
# Harness for the Checkout.com WooCommerce plugin, classic mode: a 3-D Secure (or redirect APM) payment is never linked to the
# WooCommerce order before the redirect, so if the buyer does not come back, every payment_approved / payment_captured
# webhook is answered 422 and WooCommerce cancels the paid order after the hold-stock time.
# Status codes: the handler answers with http_response_code(422) after WooCommerce has already called status_header(200),
# so php-fpm and the PHP built-in server send "200 OK" (the status line wins, see ../php-status-line/); Apache mod_php sends
# 422. Either way the order is never linked to the payment.
# A real WordPress site with WooCommerce and the plugin (WordPress.org release) and real webhook POSTs to
# ?wc-api=wc_checkoutcom_webhook signed with the secret key as Checkout.com does (HMAC-SHA256 of the body). Checkout.com is
# never called: the order is created in the state process_payment() leaves on the 3-D Secure branch (see create-order.php).
# Needs PHP 8 with mysqli, wp-cli, curl and MySQL/MariaDB (variables below).
# Run: DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=... bash run.sh [WORK_DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"
CKO_VERSION="${CKO_VERSION:-5.1.4.4}"   # the WordPress.org release; master d5be3c37 (2026-09-14) is the same code
WP_VERSION="${WP_VERSION:-7.1.3}"; WC_VERSION="${WC_VERSION:-11.2.1}"
DB_HOST="${DB_HOST:-127.0.0.1:3306}"; DB_USER="${DB_USER:-root}"; DB_PASSWORD="${DB_PASSWORD:-}"; DB_NAME="${DB_NAME:-cko_stand}"
PORT="${PORT:-8894}"
URL="http://127.0.0.1:$PORT"
SIGNING_KEY="Bearer sk_sbox_standsecretkey000000000"   # NAS accounts: the plugin verifies with "Bearer " + secret key

mkdir -p "$WORK" && cd "$WORK"
[ -f site/wp-load.php ] || wp core download --version="$WP_VERSION" --path=site --quiet
cd site
[ -f wp-config.php ] || wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost="$DB_HOST" --skip-check --quiet
php -r '[$h,$p]=array_pad(explode(":",$argv[1]),2,3306); $m=new mysqli($h,$argv[2],$argv[3],"",(int)$p); $m->query("CREATE DATABASE IF NOT EXISTS `".$argv[4]."`") or exit(1);' "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
if wp core is-installed 2>/dev/null; then echo "database $DB_NAME already has a WordPress site; use an empty database (DB_NAME=...)" >&2; exit 2; fi
wp core install --url="$URL" --title=Stand --admin_user=admin --admin_password=admin --admin_email=admin@example.test --skip-email --quiet
wp plugin install woocommerce --version="$WC_VERSION" --activate --quiet
wp plugin install checkout-com-unified-payments-api --version="$CKO_VERSION" --quiet
mkdir -p wp-content/mu-plugins
echo "<?php add_filter( 'pre_wp_mail', '__return_true' ); // the stand has no mail server" > wp-content/mu-plugins/stand-no-mail.php
cp "$HERE/stand-status-observer.php" wp-content/mu-plugins/
CODES_LOG="$PWD/wp-content/stand-handler-codes.log"
wp plugin activate checkout-com-unified-payments-api --quiet
wp eval-file "$HERE/seed.php"

php -d display_errors=0 -S "127.0.0.1:$PORT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

webhook() {  # $1 = event type, $2 = payment id, $3 = WC order id
  BODY="{\"id\":\"evt_$1_$2\",\"type\":\"$1\",\"version\":\"1.0.33\",\"created_on\":\"2026-10-12T10:00:30Z\",\"data\":{\"id\":\"$2\",\"action_id\":\"act_$1\",\"amount\":2500,\"currency\":\"EUR\",\"response_code\":\"10000\",\"response_summary\":\"Approved\",\"reference\":\"$3\",\"metadata\":{\"order_id\":$3},\"processed_on\":\"2026-10-12T10:00:29Z\"}}"
  SIG=$(printf '%s' "$BODY" | php -r 'echo hash_hmac("sha256", stream_get_contents(STDIN), $argv[1]);' "$SIGNING_KEY")
  curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/?wc-api=wc_checkoutcom_webhook" -H 'Content-Type: application/json' -H "Cko-Signature: $SIG" --data "$BODY"
}

# 1. The buyer completes the 3-D Secure challenge but closes the tab instead of following success_url.
A=$(wp eval-file "$HERE/create-order.php")
rm -f "$CODES_LOG"
CODES_A="$(webhook payment_approved pay_standA "$A") $(webhook payment_captured pay_standA "$A") $(webhook payment_captured pay_standA "$A")"
SET_A=$(paste -sd' ' "$CODES_LOG")
STATE_A=$(wp eval-file "$HERE/check.php" "$A")
echo "== buyer did not return: approved, captured, captured (retry) -> handler set $SET_A, HTTP on the wire $CODES_A"
echo "   $STATE_A"
wp eval-file "$HERE/cancel-unpaid.php" "$A"
LATER_A=$(wp eval-file "$HERE/check.php" "$A")
echo "== after wc_cancel_unpaid_orders(): $LATER_A"

# 2. Control: the buyer came back, callback_handler() stored the payment id.
B=$(wp eval-file "$HERE/create-order.php" pay_standB)
rm -f "$CODES_LOG"
CODES_B="$(webhook payment_approved pay_standB "$B") $(webhook payment_captured pay_standB "$B")"
SET_B=$(paste -sd' ' "$CODES_LOG")
STATE_B=$(wp eval-file "$HERE/check.php" "$B")
echo "== control (buyer returned): approved, captured -> handler set $SET_B, HTTP on the wire $CODES_B"
echo "   $STATE_B"

echo
if [ "$SET_A" = "422 422 422" ] && echo "$CODES_A" | grep -Eq '^(200|422) (200|422) (200|422)$' && echo "$STATE_A" | grep -q 'status=pending paid_date=none cko_payment_id=none' \
   && echo "$LATER_A" | grep -q 'status=cancelled' && echo "$STATE_B" | grep -q 'status=processing'; then
  echo "REPRODUCED: signed webhooks for the captured payment are rejected (422) on every delivery because the order has no"
  echo "_cko_payment_id (the 422 goes out as HTTP $CODES_A here, see the note at the top); WooCommerce then cancels"
  echo "the paid order. Control: once the payment id is stored, the same events complete it."
else
  echo "NOT REPRODUCED (A: set $SET_A, wire $CODES_A, $LATER_A; control: $CODES_B $STATE_B)"
  exit 1
fi
