#!/bin/bash
# Harness for Payfast for WooCommerce: an ITN for a completed payment is answered 200 even when the plugin's validation
# request to Payfast fails, so Payfast (which re-sends only when it gets no 200) never re-sends it; WooCommerce later
# cancels the paid order. A real WordPress site with WooCommerce and the plugin (WordPress.org release) and a real signed
# ITN POST to ?wc-api=WC_Gateway_PayFast. Only the validation POST to Payfast is answered locally (stand-fake-payfast.php).
# Needs PHP 8 with mysqli, wp-cli, curl and MySQL/MariaDB (variables below).
# Run: DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=... bash run.sh [WORK_DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"
PF_VERSION="${PF_VERSION:-1.7.9}"   # WordPress.org release; master f8abdefa (2026-10-08) is the same version
WP_VERSION="${WP_VERSION:-7.1.3}"; WC_VERSION="${WC_VERSION:-11.2.1}"
DB_HOST="${DB_HOST:-127.0.0.1:3306}"; DB_USER="${DB_USER:-root}"; DB_PASSWORD="${DB_PASSWORD:-}"; DB_NAME="${DB_NAME:-payfast_stand}"
PORT="${PORT:-8891}"
URL="http://127.0.0.1:$PORT"

mkdir -p "$WORK" && cd "$WORK"
[ -f site/wp-load.php ] || wp core download --version="$WP_VERSION" --path=site --quiet
cd site
[ -f wp-config.php ] || wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost="$DB_HOST" --skip-check --quiet
php -r '[$h,$p]=array_pad(explode(":",$argv[1]),2,3306); $m=new mysqli($h,$argv[2],$argv[3],"",(int)$p); $m->query("CREATE DATABASE IF NOT EXISTS `".$argv[4]."`") or exit(1);' "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
if wp core is-installed 2>/dev/null; then echo "database $DB_NAME already has a WordPress site; use an empty database (DB_NAME=...)" >&2; exit 2; fi
wp core install --url="$URL" --title=Stand --admin_user=admin --admin_password=admin --admin_email=admin@example.test --skip-email --quiet
wp plugin install woocommerce --version="$WC_VERSION" --activate --quiet
wp plugin install woocommerce-payfast-gateway --version="$PF_VERSION" --quiet
mkdir -p wp-content/mu-plugins && cp "$HERE/stand-fake-payfast.php" wp-content/mu-plugins/
wp plugin activate woocommerce-payfast-gateway --quiet
wp eval-file "$HERE/seed.php"

php -d display_errors=0 -S "127.0.0.1:$PORT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

itn() {  # $1 = "id key total"
  set -- $1
  curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/?wc-api=WC_Gateway_PayFast" \
    -H 'Content-Type: application/x-www-form-urlencoded' --data "$(php "$HERE/itn.php" "$1" "$2" "$3" stand-passphrase)"
}

# 1. The buyer pays; Payfast sends the ITN while the plugin's validation request to Payfast fails.
A=$(wp eval-file "$HERE/create-order.php"); A_ID=${A%% *}
wp option update stand_payfast_mode outage --quiet; wp option delete stand_payfast_calls --quiet
CODE_A=$(itn "$A"); STATE_A=$(wp eval-file "$HERE/check.php" "$A_ID")
echo "== ITN, validation request fails: HTTP $CODE_A"
echo "   $STATE_A"
echo "   calls: $(wp option get stand_payfast_calls --format=json)"
wp eval-file "$HERE/cancel-unpaid.php" "$A_ID"
LATER_A=$(wp eval-file "$HERE/check.php" "$A_ID")
echo "== after wc_cancel_unpaid_orders(): $LATER_A"

# 2. Control: the same ITN for another order while the validation answers VALID.
B=$(wp eval-file "$HERE/create-order.php"); B_ID=${B%% *}
wp option update stand_payfast_mode ok --quiet
CODE_B=$(itn "$B"); STATE_B=$(wp eval-file "$HERE/check.php" "$B_ID")
echo "== control: HTTP $CODE_B"
echo "   $STATE_B"

echo
if [ "$CODE_A" = "200" ] && echo "$STATE_A" | grep -q 'status=pending paid_date=none' && echo "$LATER_A" | grep -q 'status=cancelled' \
   && echo "$STATE_B" | grep -q 'status=processing'; then
  echo "REPRODUCED: the ITN for a completed payment got HTTP 200 although the plugin could not validate it with Payfast,"
  echo "so Payfast will not re-send it; the order stayed pending without a note and WooCommerce cancelled it."
  echo "Control: the same ITN with validation answering VALID completes the order."
else
  echo "NOT REPRODUCED (A: HTTP $CODE_A $STATE_A / $LATER_A; control: HTTP $CODE_B $STATE_B)"
  exit 1
fi
