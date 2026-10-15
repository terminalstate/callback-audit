#!/bin/bash
# Harness for WooCommerce PayPal Payments: PAYMENT.CAPTURE.COMPLETED for an iDEAL order is answered 200 but not applied
# when PayPal's API is briefly unavailable inside the handler, and WooCommerce later cancels the paid order.
# A real WordPress site with WooCommerce and PayPal Payments (from git, at the pinned commit) and a real HTTP request to
# /wp-json/paypal/v1/incoming. Only WordPress HTTP calls to the PayPal API hosts are answered locally (must-use plugin
# stand-fake-paypal.php, pre_http_request) — including the signature check, which the plugin still performs.
# Needs PHP 8 with mysqli, Composer, wp-cli, git, curl and MySQL/MariaDB (variables below).
# Run: DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=... bash run.sh [WORK_DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"
# Pinned commit (4.1.3; dev/develop since 2026-09-30). Override to run at another commit, e.g. a branch with a fix:
#   PPCP_REPO=https://github.com/<fork>/woocommerce-paypal-payments PPCP_COMMIT=<sha> bash run.sh
COMMIT="${PPCP_COMMIT:-8ab95eb470dd069c13d1647a5b8af7e8d570f2b1}"
REPO="${PPCP_REPO:-https://github.com/woocommerce/woocommerce-paypal-payments}"
WP_VERSION="${WP_VERSION:-7.1.3}"; WC_VERSION="${WC_VERSION:-11.2.1}"
DB_HOST="${DB_HOST:-127.0.0.1:3306}"; DB_USER="${DB_USER:-root}"; DB_PASSWORD="${DB_PASSWORD:-}"; DB_NAME="${DB_NAME:-ppcp_stand}"
PORT="${PORT:-8898}"
URL="http://127.0.0.1:$PORT"

mkdir -p "$WORK" && cd "$WORK"
[ -f site/wp-load.php ] || wp core download --version="$WP_VERSION" --path=site --quiet
cd site
[ -f wp-config.php ] || wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost="$DB_HOST" --skip-check --quiet
php -r '[$h,$p]=array_pad(explode(":",$argv[1]),2,3306); $m=new mysqli($h,$argv[2],$argv[3],"",(int)$p); $m->query("CREATE DATABASE IF NOT EXISTS `".$argv[4]."`") or exit(1);' "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
if wp core is-installed 2>/dev/null; then echo "database $DB_NAME already has a WordPress site; use an empty database (DB_NAME=...)" >&2; exit 2; fi
wp core install --url="$URL" --title=Stand --admin_user=admin --admin_password=admin --admin_email=admin@example.test --skip-email --quiet
wp rewrite structure '/%postname%/' --quiet
wp plugin install woocommerce --version="$WC_VERSION" --activate --quiet
P=wp-content/plugins/woocommerce-paypal-payments
if [ ! -d "$P/.git" ]; then
  git init -q "$P"; git -C "$P" remote add origin "$REPO"
  git -C "$P" fetch -q --depth 1 origin "$COMMIT"; git -C "$P" checkout -q FETCH_HEAD
  (cd "$P" && composer install --no-dev --no-interaction --quiet)
fi
mkdir -p wp-content/mu-plugins && cp "$HERE/stand-fake-paypal.php" wp-content/mu-plugins/
wp plugin activate woocommerce-paypal-payments --quiet
wp eval-file "$HERE/seed.php"

php -d display_errors=0 -S "127.0.0.1:$PORT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

post_capture_completed() {  # $1 = WC order id, $2 = PayPal order id — the event PayPal sends when the iDEAL capture completes
  curl -s -o /tmp/ppcp-stand-body.txt -w '%{http_code}' -X POST "$URL/wp-json/paypal/v1/incoming" \
    -H 'Content-Type: application/json' -H 'PAYPAL-AUTH-ALGO: SHA256withRSA' \
    -H 'PAYPAL-CERT-URL: https://api.sandbox.paypal.com/v1/notifications/certs/CERT-stand' \
    -H "PAYPAL-TRANSMISSION-ID: tx-$1" -H 'PAYPAL-TRANSMISSION-SIG: stand' -H 'PAYPAL-TRANSMISSION-TIME: 2026-10-12T10:00:02Z' \
    --data "{\"id\":\"WH-EVT-$1\",\"event_version\":\"1.0\",\"create_time\":\"2026-10-12T10:00:02Z\",\"resource_type\":\"capture\",\"resource_version\":\"2.0\",\"event_type\":\"PAYMENT.CAPTURE.COMPLETED\",\"summary\":\"Payment completed for EUR 25.0 EUR\",\"resource\":{\"id\":\"CAP-$1\",\"status\":\"COMPLETED\",\"amount\":{\"currency_code\":\"EUR\",\"value\":\"25.00\"},\"final_capture\":true,\"custom_id\":\"$1\",\"supplementary_data\":{\"related_ids\":{\"order_id\":\"$2\"}},\"create_time\":\"2026-10-12T10:00:00Z\",\"update_time\":\"2026-10-12T10:00:01Z\"}}"
}

# 1. PayPal is briefly unavailable when the plugin fetches the order for its fee breakdown.
A=$(wp eval-file "$HERE/create-order.php" PPSTANDA)
wp option update stand_paypal_mode outage --quiet; wp option delete stand_paypal_calls --quiet
CODE_A=$(post_capture_completed "$A" PPSTANDA); BODY_A=$(cat /tmp/ppcp-stand-body.txt)
STATE_A=$(wp eval-file "$HERE/check.php" "$A")
echo "== outage:  HTTP $CODE_A $BODY_A"
echo "   $STATE_A"
echo "   PayPal calls: $(wp option get stand_paypal_calls --format=json)"

# 2. Control: the same delivery for another iDEAL order while PayPal answers.
B=$(wp eval-file "$HERE/create-order.php" PPSTANDB)
wp option update stand_paypal_mode ok --quiet; wp option delete stand_paypal_calls --quiet
CODE_B=$(post_capture_completed "$B" PPSTANDB); BODY_B=$(cat /tmp/ppcp-stand-body.txt)
STATE_B=$(wp eval-file "$HERE/check.php" "$B")
echo "== control: HTTP $CODE_B $BODY_B"
echo "   $STATE_B"

# 3. An hour later WooCommerce's unpaid-order cleanup runs.
wp eval-file "$HERE/cancel-unpaid.php" "$A"
LATER_A=$(wp eval-file "$HERE/check.php" "$A")
echo "== after wc_cancel_unpaid_orders(): $LATER_A"

echo
if [ "$CODE_A" = "200" ] && echo "$STATE_A" | grep -q 'status=pending paid_date=none' \
   && echo "$STATE_B" | grep -q 'status=processing' && echo "$LATER_A" | grep -q 'status=cancelled'; then
  echo "REPRODUCED: PAYMENT.CAPTURE.COMPLETED for a paid iDEAL order got HTTP 200 (PayPal will not resend it), but the order"
  echo "stayed pending because the fee lookup's exception escaped the handler before payment_complete(); an hour later"
  echo "WooCommerce cancelled it and released the stock. Control: the same delivery with PayPal reachable completes the order."
elif [ "$CODE_A" = "200" ] && echo "$STATE_A" | grep -q 'status=processing'; then
  echo "NOT REPRODUCED: the order was completed although the fee lookup failed (a fix keeps payment_complete() independent of it)."
  exit 1
else
  echo "NOT REPRODUCED (outage: HTTP $CODE_A, $STATE_A; control: HTTP $CODE_B, $STATE_B; later: $LATER_A)"
  exit 1
fi
