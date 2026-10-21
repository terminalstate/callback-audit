#!/bin/bash
# Harness for Flutterwave for WooCommerce (Woocommerce-v2): a charge.completed webhook records the Flutterwave transaction id as
# processed before verifying the transaction; when verification fails (timeout), the webhook is still answered 201, and the
# retry with the same id gets 200 "Webhook already processed" without verifying — the paid order stays pending and WooCommerce
# cancels it. A real WordPress site with WooCommerce and the plugin from git, a real POST to ?wc-api=flw_wc_payment_webhook with
# the verif-hash header; the Flutterwave API is a stand-in (pre_http_request) that the plugin's own client calls.
# Needs PHP 8 with mysqli, wp-cli, git, curl and MySQL/MariaDB. Run: DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=... bash run.sh [WORK_DIR]
# FLW_PATCH=fix.patch applies a change to the plugin first (the fix proposed in the report).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH=""; [ -n "${FLW_PATCH:-}" ] && PATCH="$(cd "$(dirname "$FLW_PATCH")" && pwd)/$(basename "$FLW_PATCH")"
WORK="${1:-$(mktemp -d)}"
COMMIT="${FLW_COMMIT:-79d141ede0037fbe86731eb403e2ee9ef25c9157}"   # master on 2026-10-08 (3.3.2, = WordPress.org)
WP_VERSION="${WP_VERSION:-7.1.3}"; WC_VERSION="${WC_VERSION:-11.2.1}"
DB_HOST="${DB_HOST:-127.0.0.1:3306}"; DB_USER="${DB_USER:-root}"; DB_PASSWORD="${DB_PASSWORD:-}"; DB_NAME="${DB_NAME:-flw_stand}"
PORT="${PORT:-8899}"; URL="http://127.0.0.1:$PORT"; HASH=$(printf 'ab12%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)

mkdir -p "$WORK" && WORK="$(cd "$WORK" && pwd)" && cd "$WORK"
[ -f site/wp-load.php ] || wp core download --version="$WP_VERSION" --path=site --quiet
cd site
[ -f wp-config.php ] || wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost="$DB_HOST" --skip-check --quiet
php -r '[$h,$p]=array_pad(explode(":",$argv[1]),2,3306); $m=new mysqli($h,$argv[2],$argv[3],"",(int)$p); $m->query("CREATE DATABASE IF NOT EXISTS `".$argv[4]."`") or exit(1);' "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
if wp core is-installed 2>/dev/null; then echo "database $DB_NAME already has a WordPress site; use an empty database (DB_NAME=...)" >&2; exit 2; fi
wp core install --url="$URL" --title=Stand --admin_user=admin --admin_password=admin --admin_email=admin@example.test --skip-email --quiet
wp plugin install woocommerce --version="$WC_VERSION" --activate --quiet
mkdir -p wp-content/mu-plugins
cp "$HERE/stand-fake-flutterwave.php" wp-content/mu-plugins/
echo "<?php add_filter( 'pre_wp_mail', '__return_true' ); // the stand has no mail server" > wp-content/mu-plugins/stand-no-mail.php
P=wp-content/plugins/rave-woocommerce-payment-gateway
git init -q "$P"; git -C "$P" remote add origin https://github.com/Flutterwave/Woocommerce-v2
git -C "$P" fetch -q --depth 1 origin "$COMMIT"; git -C "$P" checkout -q FETCH_HEAD
[ -z "$PATCH" ] || git -C "$P" apply "$PATCH"
wp plugin activate rave-woocommerce-payment-gateway --quiet
wp eval-file "$HERE/seed.php"
echo "plugin: $(git -C "$P" log -1 --format='%h %cs')${PATCH:+ + $(basename "$PATCH")}"

php -d display_errors=0 -S "127.0.0.1:$PORT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

webhook() {  # $1 = tx_ref; charge.completed as Flutterwave sends it, with the merchant's secret hash in verif-hash
  local body="{\"event\":\"charge.completed\",\"data\":{\"id\":5550001,\"tx_ref\":\"$1\",\"flw_ref\":\"FLW-STAND-1\",\"amount\":2500,\"currency\":\"NGN\",\"charged_amount\":2500,\"status\":\"successful\",\"payment_type\":\"card\",\"customer\":{\"email\":\"buyer@example.test\"}}}"
  curl -s -o "$WORK/last-body.txt" -w '%{http_code}' -X POST "$URL/?wc-api=flw_wc_payment_webhook" -H 'Content-Type: application/json' -H "verif-hash: $HASH" --data "$body"
}

read -r A REF_A <<< "$(wp eval-file "$HERE/create-order.php")"
wp option update stand_flw_mode outage --quiet; wp option delete stand_flw_calls --quiet
C1=$(webhook "$REF_A"); B1=$(cat "$WORK/last-body.txt")
echo "== 1. webhook, verification times out: HTTP $C1 $B1"
echo "   $(wp eval-file "$HERE/check.php" "$A")"
wp option update stand_flw_mode ok --quiet
C2=$(webhook "$REF_A"); B2=$(cat "$WORK/last-body.txt")
echo "== 2. Flutterwave's retry, API back: HTTP $C2 $B2"
STATE_A=$(wp eval-file "$HERE/check.php" "$A"); echo "   $STATE_A"
echo "   API calls: $(wp option get stand_flw_calls --format=json)"
wp eval-file "$HERE/cancel-unpaid.php" "$A"
LATER_A=$(wp eval-file "$HERE/check.php" "$A"); echo "== after wc_cancel_unpaid_orders(): $LATER_A"

read -r B REF_B <<< "$(wp eval-file "$HERE/create-order.php")"
C3=$(webhook "$REF_B"); STATE_B=$(wp eval-file "$HERE/check.php" "$B")
echo "== control: first delivery, API answers: HTTP $C3 $(cat "$WORK/last-body.txt")"
echo "   $STATE_B"

echo
if echo "$B2" | grep -q 'already processed' && echo "$STATE_A" | grep -q 'status=pending' && echo "$LATER_A" | grep -q 'status=cancelled' \
   && echo "$STATE_B" | grep -q 'status=processing'; then
  echo "REPRODUCED: the webhook marked the transaction processed before verifying it; the failed verification was answered $C1, and"
  echo "the retry was answered 200 'Webhook already processed' without verifying — the paid order stayed pending and was cancelled."
elif [ -n "$PATCH" ] && [ "$C1" = 503 ] && echo "$STATE_A" | grep -q 'status=processing' && echo "$LATER_A" | grep -q 'status=processing' \
   && echo "$STATE_B" | grep -q 'status=processing'; then
  echo "NOT REPRODUCED with $(basename "$PATCH"): the failed verification was answered 503 and not recorded; the retry verified the"
  echo "transaction and the order is processing."
else
  echo "NOT REPRODUCED"; exit 1
fi
