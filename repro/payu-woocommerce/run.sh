#!/bin/bash
# Harness for PayU Payment Gateway for WooCommerce (woo-payu-payment-gateway): on master since 07b8f98 a COMPLETED notification
# is answered 200 but never completes the order — the plugin stores "COMPLETED|<id>" on the order before it asks "is a COMPLETED
# status already stored?", so payment_complete() is never reached. The released 2.11.0 completes the same order (control).
# A real WordPress site with WooCommerce and the plugin from git, a real signed POST to ?wc-api=wc_gateway_payustandard as PayU
# sends it (PENDING, then COMPLETED). The COMPLETED path makes no call to PayU, so nothing is faked.
# Needs PHP 8 with mysqli, Composer, wp-cli, git, curl and MySQL/MariaDB (variables below).
# Run: DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=... bash run.sh [WORK_DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"
COMMIT="${PAYU_COMMIT:-3ed1ca615f0ba757d88318c451a19481f888af3b}"   # master on 2026-10-18
CONTROL="${PAYU_CONTROL:-v2.11.0}"                                  # the release on WordPress.org
UPSTREAM=https://github.com/PayU-EMEA/woo-payu-payment-gateway
REPO="${PAYU_REPO:-$UPSTREAM}"                                     # where PAYU_COMMIT is fetched from; the control is always upstream
WP_VERSION="${WP_VERSION:-7.1.3}"; WC_VERSION="${WC_VERSION:-11.2.1}"
DB_HOST="${DB_HOST:-127.0.0.1:3306}"; DB_USER="${DB_USER:-root}"; DB_PASSWORD="${DB_PASSWORD:-}"; DB_NAME="${DB_NAME:-payu_stand}"
PORT="${PORT:-8897}"; URL="http://127.0.0.1:$PORT"; KEY=stand-second-key-md5

mkdir -p "$WORK" && cd "$WORK"
[ -f site/wp-load.php ] || wp core download --version="$WP_VERSION" --path=site --quiet
cd site
[ -f wp-config.php ] || wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost="$DB_HOST" --skip-check --quiet
php -r '[$h,$p]=array_pad(explode(":",$argv[1]),2,3306); $m=new mysqli($h,$argv[2],$argv[3],"",(int)$p); $m->query("CREATE DATABASE IF NOT EXISTS `".$argv[4]."`") or exit(1);' "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
if wp core is-installed 2>/dev/null; then echo "database $DB_NAME already has a WordPress site; use an empty database (DB_NAME=...)" >&2; exit 2; fi
wp core install --url="$URL" --title=Stand --admin_user=admin --admin_password=admin --admin_email=admin@example.test --skip-email --quiet
wp plugin install woocommerce --version="$WC_VERSION" --activate --quiet
P=wp-content/plugins/woo-payu-payment-gateway
git init -q "$P"; git -C "$P" remote add origin "$REPO"
git -C "$P" fetch -q --depth 1 origin "$COMMIT"
git -C "$P" fetch -q --depth 1 "$UPSTREAM" "refs/tags/$CONTROL:refs/tags/$CONTROL"
git -C "$P" checkout -q "$COMMIT"
(cd "$P" && composer install --no-dev --no-interaction --quiet)
mkdir -p wp-content/mu-plugins
echo "<?php add_filter( 'pre_wp_mail', '__return_true' ); // the stand has no mail server" > wp-content/mu-plugins/stand-no-mail.php
wp plugin activate woo-payu-payment-gateway --quiet

php -d display_errors=0 -S "127.0.0.1:$PORT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

notify() {  # $1 = wc order id, $2 = PayU order id, $3 = status
  local out sig body
  out=$(php "$HERE/notify.php" "$1" "$2" "$3" "$KEY"); sig=${out%%$'\n'*}; body=${out#*$'\n'}
  curl -s -o "$WORK/last-body.txt" -w '%{http_code}' -X POST "$URL/?wc-api=wc_gateway_payustandard" \
    -H 'Content-Type: application/json' -H "OpenPayu-Signature: $sig" --data-binary "$body"
}

scenario() {  # $1 = label, $2 = PayU order id; prints the HTTP codes and the order state after PENDING + COMPLETED
  local id c1 c2
  id=$(wp eval-file "$HERE/create-order.php" "$2")
  c1=$(notify "$id" "$2" PENDING); c2=$(notify "$id" "$2" COMPLETED)
  echo "== $1: PENDING -> HTTP $c1, COMPLETED -> HTTP $c2 body=$(cut -c1-60 "$WORK/last-body.txt")"
  echo "   $(wp eval-file "$HERE/check.php" "$id")"
  LAST_ID=$id
}

echo "plugin: $(git -C "$P" log -1 --format='%h %cs %s')"
wp eval-file "$HERE/seed.php" on-hold
scenario "master, new orders on-hold (plugin default)" STANDPAYU1A; A=$(wp eval-file "$HERE/check.php" "$LAST_ID")

wp eval "\$s = get_option( 'payu_settings_option_name' ); \$s['global_default_on_hold_status'] = 'pending'; update_option( 'payu_settings_option_name', \$s );"
scenario "master, new orders pending (the other choice)" STANDPAYU1B; B_ID=$LAST_ID
wp eval-file "$HERE/cancel-unpaid.php" "$B_ID"
B=$(wp eval-file "$HERE/check.php" "$B_ID")
echo "   after wc_cancel_unpaid_orders(): $B"

git -C "$P" checkout -q "$CONTROL"
echo "plugin: $(git -C "$P" log -1 --format='%h %cs %s') ($CONTROL)"
wp eval "\$s = get_option( 'payu_settings_option_name' ); \$s['global_default_on_hold_status'] = 'on-hold'; update_option( 'payu_settings_option_name', \$s );"
scenario "control, $CONTROL, new orders on-hold" STANDPAYU1C; C=$(wp eval-file "$HERE/check.php" "$LAST_ID")

echo
if echo "$A" | grep -q 'status=on-hold paid_date=none' && echo "$B" | grep -q 'status=cancelled' \
   && echo "$C" | grep -q 'status=processing paid_date=set'; then
  echo "REPRODUCED: on master the COMPLETED notification is answered 200 and stored, but the order is never completed —"
  echo "it stays on-hold, or (with new orders pending) WooCommerce cancels it as unpaid. $CONTROL completes the same order."
else
  echo "NOT REPRODUCED (A: $A; B: $B; control: $C)"
  exit 1
fi
