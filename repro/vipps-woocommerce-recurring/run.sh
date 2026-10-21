#!/bin/bash
# Harness for Vipps MobilePay for WooCommerce (woo-vipps), recurring payments: when the response to "create charge" is lost
# (timeout after Vipps saved the charge), the renewal order is marked failed with no charge id stored. Nothing cancels the
# charge, Vipps collects it on the due date, and the charge webhook finds no order — the customer pays, the subscription is
# not renewed. A real WordPress site with WooCommerce, WooCommerce Subscriptions core (GPL) and the plugin from git; the Vipps
# API is a stand-in (pre_http_request) that the plugin's own client calls.
# Needs PHP 8 with mysqli, wp-cli, git and MySQL/MariaDB. Run: DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=... bash run.sh [WORK_DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"
COMMIT="${VIPPS_COMMIT:-6146a9c7f32d74188519a0592f1ff6ce8e5a197f}"   # master on 2026-10-20 (6.3.3, = WordPress.org)
WCS_CORE_COMMIT="${WCS_CORE_COMMIT:-0795346}"                          # woocommerce-subscriptions-core 8.2.0
WP_VERSION="${WP_VERSION:-7.1.3}"; WC_VERSION="${WC_VERSION:-11.2.1}"
DB_HOST="${DB_HOST:-127.0.0.1:3306}"; DB_USER="${DB_USER:-root}"; DB_PASSWORD="${DB_PASSWORD:-}"; DB_NAME="${DB_NAME:-vipps_stand}"

mkdir -p "$WORK" && WORK="$(cd "$WORK" && pwd)" && cd "$WORK"
[ -d wcs-core ] || git clone -q https://github.com/Automattic/woocommerce-subscriptions-core wcs-core
git -C wcs-core checkout -q "$WCS_CORE_COMMIT"
export STAND_WCS_CORE="$WORK/wcs-core"
[ -f site/wp-load.php ] || wp core download --version="$WP_VERSION" --path=site --quiet
cd site
[ -f wp-config.php ] || wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost="$DB_HOST" --skip-check --quiet
php -r '[$h,$p]=array_pad(explode(":",$argv[1]),2,3306); $m=new mysqli($h,$argv[2],$argv[3],"",(int)$p); $m->query("CREATE DATABASE IF NOT EXISTS `".$argv[4]."`") or exit(1);' "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
if wp core is-installed 2>/dev/null; then echo "database $DB_NAME already has a WordPress site; use an empty database (DB_NAME=...)" >&2; exit 2; fi
wp core install --url=http://127.0.0.1:8898 --title=Stand --admin_user=admin --admin_password=admin --admin_email=admin@example.test --skip-email --quiet
wp plugin install woocommerce --version="$WC_VERSION" --activate --quiet
mkdir -p wp-content/mu-plugins
cp "$HERE/stand-wcs.php" "$HERE/stand-fake-vipps.php" wp-content/mu-plugins/
echo "<?php add_filter( 'pre_wp_mail', '__return_true' ); // the stand has no mail server" > wp-content/mu-plugins/stand-no-mail.php
P=wp-content/plugins/woo-vipps
git init -q "$P"; git -C "$P" remote add origin https://github.com/vippsas/vipps-woocommerce
git -C "$P" fetch -q --depth 1 origin "$COMMIT"; git -C "$P" checkout -q FETCH_HEAD
wp plugin activate woo-vipps --quiet
wp eval-file "$HERE/seed.php"
echo "plugin: $(git -C "$P" log -1 --format='%h %cs')"

echo "== 1. create-charge response lost (charge saved at Vipps)"
A=$(wp eval-file "$HERE/renew.php" create_lost); echo "$A"
echo "== 2. control: create and fetch work"
B=$(wp eval-file "$HERE/renew.php" ok); echo "$B"
echo "== 3. fetch of the new charge fails (the plugin then tries to cancel the due charge, but cannot read it either)"
C=$(wp eval-file "$HERE/renew.php" get_fails); echo "$C"

echo
if echo "$A" | grep -q 'status=failed charge_id_stored=none' && echo "$A" | grep -q 'status=DUE' \
   && echo "$A" | grep -q 'charge-captured.v1: order status=failed paid_date=none' \
   && echo "$B" | grep -q 'charge_id_stored=chr-'; then
  echo "REPRODUCED: the charge exists at Vipps and is collected on its due date, but the renewal order is failed with no charge id;"
  echo "the charge webhook finds no order, so the customer pays and the renewal stays failed (the subscription goes on hold)."
else
  echo "NOT REPRODUCED"; exit 1
fi
