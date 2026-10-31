#!/bin/bash
# Harness for LearnPress (WordPress.org release): the PayPal subscription webhook
# (/wp-json/lp/v1/gateways/{gateway}/subscription-webhook) catches every Throwable and returns a plain Response object,
# which WordPress REST sends as HTTP 200. PayPal re-sends a webhook only on a non-2xx answer, so a renewal or an
# activation that hits a transient error (here: PayPal's verify-webhook-signature call times out) is never re-sent.
# Codes the plugin itself chose (400 for a failed verification, 404 for an unknown gateway) are also lost.
# A real WordPress site + LearnPress; only LearnPress's calls to the PayPal sandbox API are answered locally
# (stand-fake-paypal.php). Needs PHP 8 with mysqli, wp-cli, curl and MySQL/MariaDB (variables below).
# Run: DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=... bash run.sh [WORK_DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"
LP_VERSION="${LP_VERSION:-4.4.13}"; WP_VERSION="${WP_VERSION:-7.1.3}"
DB_HOST="${DB_HOST:-127.0.0.1:3306}"; DB_USER="${DB_USER:-root}"; DB_PASSWORD="${DB_PASSWORD:-}"; DB_NAME="${DB_NAME:-learnpress_stand}"
PORT="${PORT:-8893}"
URL="http://127.0.0.1:$PORT"

mkdir -p "$WORK" && cd "$WORK"
[ -f site/wp-load.php ] || wp core download --version="$WP_VERSION" --path=site --quiet
cd site
[ -f wp-config.php ] || wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost="$DB_HOST" --skip-check --quiet
php -r '[$h,$p]=array_pad(explode(":",$argv[1]),2,3306); $m=new mysqli($h,$argv[2],$argv[3],"",(int)$p); $m->query("CREATE DATABASE IF NOT EXISTS `".$argv[4]."`") or exit(1);' "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
if wp core is-installed 2>/dev/null; then echo "database $DB_NAME already has a WordPress site; use an empty database (DB_NAME=...)" >&2; exit 2; fi
wp core install --url="$URL" --title=Stand --admin_user=admin --admin_password=admin --admin_email=admin@example.test --skip-email --quiet
wp plugin install learnpress --version="$LP_VERSION" --activate --quiet
wp eval 'LP_Install::instance()->on_activate();'   # activation from wp-cli does not finish the table install; the admin screen would
mkdir -p wp-content/mu-plugins && cp "$HERE/stand-fake-paypal.php" wp-content/mu-plugins/
wp option update learn_press_paypal --format=json \
  '{"enable":"yes","paypal_sandbox":"yes","app_client_id":"stand-client","app_client_secret":"stand-secret","enable_subscriptions":"yes","subscription_webhook_id":"WH-ID-STAND"}' --quiet
wp eval 'if (class_exists("LearnPress\\Cache\\LPSettingsCache")) { (new LearnPress\Cache\LPSettingsCache(true))->clean_lp_settings(); } else { (new LP_Settings_Cache(true))->clean_lp_settings(); }'   # LearnPress caches its settings; saving in the admin clears it too

php -d display_errors=0 -d opcache.enable=0 -S "127.0.0.1:$PORT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

# LearnPress registers its REST routes only for /wp-json/lp/ URLs (not ?rest_route=).
deliver() {  # $1 = gateway id
  curl -s -o body.txt -w '%{http_code}' -X POST "$URL/wp-json/lp/v1/gateways/$1/subscription-webhook" \
    -H 'Content-Type: application/json' -H 'PAYPAL-AUTH-ALGO: SHA256withRSA' \
    -H 'PAYPAL-CERT-URL: https://api.sandbox.paypal.com/v1/notifications/certs/CERT-STAND' \
    -H 'PAYPAL-TRANSMISSION-ID: 3f1a9d70-0000-11f0-0000-000000000001' -H 'PAYPAL-TRANSMISSION-SIG: c3RhbmQ=' \
    -H "PAYPAL-TRANSMISSION-TIME: $(date -u +%Y-%m-%dT%H:%M:%SZ)" --data @"$HERE/sale-completed.json"
}

wp option update stand_paypal_mode outage --quiet; wp option delete stand_paypal_calls --quiet
A=$(deliver paypal); echo "== PAYMENT.SALE.COMPLETED, verify-webhook-signature times out: HTTP $A  $(cat body.txt)"
echo "   PayPal calls: $(wp option get stand_paypal_calls --format=json)"
wp option update stand_paypal_mode fail --quiet
B=$(deliver paypal); echo "== verification answers FAILURE (plugin throws code 400): HTTP $B  $(cat body.txt)"
C=$(deliver no-such-gateway); echo "== unknown gateway (plugin throws code 404): HTTP $C  $(cat body.txt)"

lp_patch() {  # git apply as plain patch: do not let git pick up a repository above the site
  (cd wp-content/plugins/learnpress && GIT_CEILING_DIRECTORIES="$(dirname "$PWD")" git apply "$@" "$HERE/fix-webhook-status.patch")
}
# Same three deliveries with fix-webhook-status.patch (WP_REST_Response with the exception's 4xx, otherwise 500).
lp_patch
wp option update stand_paypal_mode outage --quiet
A2=$(deliver paypal); echo "== with patch, verify-webhook-signature times out: HTTP $A2  $(cat body.txt)"
wp option update stand_paypal_mode fail --quiet
B2=$(deliver paypal); echo "== with patch, verification FAILURE: HTTP $B2"
C2=$(deliver no-such-gateway); echo "== with patch, unknown gateway: HTTP $C2"
lp_patch -R

echo
if [ "$A" = "200" ]; then
  echo "REPRODUCED: a transient failure is answered 200, so PayPal will not re-send the event"
else
  echo "NOT REPRODUCED (HTTP $A)"
fi
