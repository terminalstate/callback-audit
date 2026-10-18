#!/bin/bash
# Harness for BTCPay for WooCommerce V2 (Greenfield): an InvoiceSettled webhook is answered 200 when the plugin cannot
# re-fetch the invoice from BTCPay, so BTCPay does not redeliver it and the paid order stays on-hold.
# A real WordPress site with WooCommerce and the plugin (from git, at the pinned commit), a real signed POST to
# ?wc-api=btcpaygf_default, and a stand-in BTCPay Greenfield API on a second local port (fake-btcpay.php) that the
# plugin's own HTTP client calls. Nothing in the plugin or WooCommerce is changed.
# Needs PHP 8 with mysqli and curl, Composer, wp-cli, git, curl and MySQL/MariaDB (variables below).
# Run: DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=... bash run.sh [WORK_DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"
COMMIT="${BTCPAY_COMMIT:-9d00861effa83f464bdb4cd9e6f8ce275b2ded31}"   # master on 2026-10-18 (2.8.5 + fixes of 2026-10-15)
REPO="${BTCPAY_REPO:-https://github.com/btcpayserver/woocommerce-greenfield-plugin}"
WP_VERSION="${WP_VERSION:-7.1.3}"; WC_VERSION="${WC_VERSION:-11.2.1}"
DB_HOST="${DB_HOST:-127.0.0.1:3306}"; DB_USER="${DB_USER:-root}"; DB_PASSWORD="${DB_PASSWORD:-}"; DB_NAME="${DB_NAME:-btcpay_stand}"
PORT="${PORT:-8896}"; BTCPAY_PORT="${BTCPAY_PORT:-8895}"
URL="http://127.0.0.1:$PORT"
SECRET=stand-webhook-secret

mkdir -p "$WORK" && cd "$WORK"
export STAND_MODE_FILE="$WORK/btcpay-mode" STAND_LOG_FILE="$WORK/btcpay-calls.log"
[ -f site/wp-load.php ] || wp core download --version="$WP_VERSION" --path=site --quiet
cd site
[ -f wp-config.php ] || wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost="$DB_HOST" --skip-check --quiet
php -r '[$h,$p]=array_pad(explode(":",$argv[1]),2,3306); $m=new mysqli($h,$argv[2],$argv[3],"",(int)$p); $m->query("CREATE DATABASE IF NOT EXISTS `".$argv[4]."`") or exit(1);' "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
if wp core is-installed 2>/dev/null; then echo "database $DB_NAME already has a WordPress site; use an empty database (DB_NAME=...)" >&2; exit 2; fi
wp core install --url="$URL" --title=Stand --admin_user=admin --admin_password=admin --admin_email=admin@example.test --skip-email --quiet
wp plugin install woocommerce --version="$WC_VERSION" --activate --quiet
P=wp-content/plugins/btcpay-greenfield-for-woocommerce
if [ ! -d "$P/.git" ]; then
  git init -q "$P"; git -C "$P" remote add origin "$REPO"
  git -C "$P" fetch -q --depth 1 origin "$COMMIT"; git -C "$P" checkout -q FETCH_HEAD
  (cd "$P" && composer install --no-dev --no-interaction --quiet)
fi
mkdir -p wp-content/mu-plugins
echo "<?php add_filter( 'pre_wp_mail', '__return_true' ); // the stand has no mail server" > wp-content/mu-plugins/stand-no-mail.php
wp plugin activate btcpay-greenfield-for-woocommerce --quiet
wp eval-file "$HERE/seed.php" "http://127.0.0.1:$BTCPAY_PORT"

php -S "127.0.0.1:$BTCPAY_PORT" "$HERE/fake-btcpay.php" >/dev/null 2>&1 &
FAKE=$!
php -d display_errors=0 -S "127.0.0.1:$PORT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER $FAKE 2>/dev/null' EXIT
sleep 1

settled() {  # $1 = invoice id — the InvoiceSettled delivery BTCPay sends, signed with the webhook secret
  BODY="{\"deliveryId\":\"dlv-$1-$RANDOM\",\"webhookId\":\"stand-webhook-1\",\"originalDeliveryId\":\"dlv-$1\",\"isRedelivery\":false,\"type\":\"InvoiceSettled\",\"timestamp\":1791803600,\"storeId\":\"STANDSTORE1\",\"invoiceId\":\"$1\",\"manuallyMarked\":false,\"overPaid\":false}"
  SIG=$(printf '%s' "$BODY" | php -r 'echo hash_hmac("sha256", stream_get_contents(STDIN), $argv[1]);' "$SECRET")
  curl -s -o /tmp/btcpay-stand-body.txt -w '%{http_code}' -X POST "$URL/?wc-api=btcpaygf_default" \
    -H 'Content-Type: application/json' -H "BTCPay-Sig: sha256=$SIG" --data "$BODY"
}

# 1. The invoice settles while BTCPay's API is briefly unavailable (restart, overload).
A=$(wp eval-file "$HERE/create-order.php" STANDINV1)
echo outage > "$STAND_MODE_FILE"; : > "$STAND_LOG_FILE"
CODE_A=$(settled STANDINV1); STATE_A=$(wp eval-file "$HERE/check.php" "$A")
echo "== settled, API unavailable: HTTP $CODE_A body=$(cut -c1-40 /tmp/btcpay-stand-body.txt)"
echo "   $STATE_A"
echo "   BTCPay API calls: $(tr '\n' ';' < "$STAND_LOG_FILE")"

# 2. Control: the same delivery for another order while the API answers.
B=$(wp eval-file "$HERE/create-order.php" STANDINV2)
echo ok > "$STAND_MODE_FILE"; : > "$STAND_LOG_FILE"
CODE_B=$(settled STANDINV2); STATE_B=$(wp eval-file "$HERE/check.php" "$B")
echo "== control: HTTP $CODE_B"
echo "   $STATE_B"

echo
if [ "$CODE_A" = "200" ] && echo "$STATE_A" | grep -q 'status=on-hold paid_date=none' && echo "$STATE_B" | grep -q 'status=processing'; then
  echo "REPRODUCED: the plugin could not verify the settled invoice, added a note asking to 'retry the webhook', and answered"
  echo "HTTP 200 — so BTCPay counts the delivery as successful and does not redeliver it. The paid order stays on-hold."
  echo "Control: the same delivery with the API reachable completes the order."
elif [ "${CODE_A:0:1}" = "5" ] && echo "$STATE_B" | grep -q 'status=processing'; then
  echo "NOT REPRODUCED: the failed verification was answered HTTP $CODE_A, so BTCPay will redeliver it (what a fix does)."
  exit 1
else
  echo "NOT REPRODUCED (A: HTTP $CODE_A $STATE_A; control: HTTP $CODE_B $STATE_B)"
  exit 1
fi
