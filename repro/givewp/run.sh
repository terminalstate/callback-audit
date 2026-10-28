#!/bin/bash
# Harness for impress-org/givewp: the Stripe webhook answers 200 when GiveWP cannot fetch the event from Stripe.
# listen() reads php://input and ends with exit, so PHPUnit can't run it: this is a real WordPress + GiveWP site and a
# real POST to /?give-listener=stripe. Only stripe-php's HTTP transport is replaced (must-use plugin stand-fake-stripe.php,
# ApiRequestor::setHttpClient); GiveWP is not modified and nothing goes to Stripe. The donation is created with GiveWP's
# own factories (needs the dev dependencies). Needs PHP 8.x with mysqli, composer, wp-cli, git, curl and MySQL/MariaDB.
# Usage: DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=... bash run.sh [WORK_DIR]   (GIVEWP_COMMIT=... for another commit)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"
COMMIT="${GIVEWP_COMMIT:-407d6edb0cdfbfb6cfcc31262f3394d39a32deb4}"   # develop as of 2026-10-28 (4.19.1)
WP_VERSION="${WP_VERSION:-7.1.3}"
DB_HOST="${DB_HOST:-127.0.0.1:3306}"; DB_USER="${DB_USER:-root}"; DB_PASSWORD="${DB_PASSWORD:-}"; DB_NAME="${DB_NAME:-givewp_stand}"
PORT="${PORT:-8898}"
URL="http://127.0.0.1:$PORT"

mkdir -p "$WORK" && cd "$WORK"
if [ ! -f site/wp-load.php ]; then
  wp core download --version="$WP_VERSION" --path=site --quiet
fi
cd site
# The database is recreated on every run: the seeded donation must be the only one with pi_test_1.
[ -f wp-config.php ] || wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost="$DB_HOST" --skip-check --quiet
php -r '[$h,$p]=array_pad(explode(":",$argv[1]),2,3306); $m=new mysqli($h,$argv[2],$argv[3],"",(int)$p); $m->query("DROP DATABASE IF EXISTS `".$argv[4]."`"); $m->query("CREATE DATABASE `".$argv[4]."`") or exit(1);' "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
wp core install --url="$URL" --title=Stand --admin_user=admin --admin_password=admin --admin_email=admin@example.test --skip-email --quiet
P=wp-content/plugins/give
if [ ! -d "$P/.git" ]; then
  git init -q "$P" && git -C "$P" remote add origin https://github.com/impress-org/givewp
  git -C "$P" fetch -q --depth 1 origin "$COMMIT" && git -C "$P" checkout -q FETCH_HEAD
  (cd "$P" && composer install --no-interaction --no-progress -q)
fi
mkdir -p wp-content/mu-plugins
cp -r "$HERE/stand-fake-stripe.php" "$HERE/stand-fake-stripe" wp-content/mu-plugins/
wp plugin activate give --quiet
wp eval 'do_action( "admin_init" );' >/dev/null 2>&1 || true   # GiveWP runs its table migrations on admin_init
wp eval-file "$HERE/seed.php"

php -S "127.0.0.1:$PORT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

post_event() {   # the body Stripe sends; GiveWP re-fetches the event from Stripe by its id
  curl -s -o /tmp/givewp-stand-body.txt -w '%{http_code}' -X POST "$URL/?give-listener=stripe" \
    -H 'Content-Type: application/json' \
    --data '{"id":"evt_test_1","object":"event","type":"payment_intent.succeeded","livemode":false,"data":{"object":{"id":"pi_test_1","object":"payment_intent","status":"succeeded"}}}'
}

echo "== before:            $(wp eval-file "$HERE/check.php")"

# 1. Stripe is briefly unavailable when GiveWP re-fetches the event.
wp option update stand_stripe_mode outage --quiet; wp option delete stand_stripe_calls --quiet
CODE=$(post_event)
OUTAGE_STATE=$(wp eval-file "$HERE/check.php")
echo "== outage: HTTP $CODE  $OUTAGE_STATE"
echo "   body: $(tr '\n' ' ' < /tmp/givewp-stand-body.txt | cut -c1-220)"
OUTAGE_CODE=$CODE

# 2. Control: the same delivery when Stripe answers.
wp option update stand_stripe_mode ok --quiet; wp option delete stand_stripe_calls --quiet
CODE=$(post_event)
OK_STATE=$(wp eval-file "$HERE/check.php")
echo "== ok:     HTTP $CODE  $OK_STATE"

echo
if [ "$OUTAGE_CODE" = "200" ] && echo "$OUTAGE_STATE" | grep -q 'status=processing' \
   && echo "$OUTAGE_STATE" | grep -q 'GET \\/v1\\/events\\/evt_test_1 (outage)' \
   && echo "$OK_STATE" | grep -q 'status=publish'; then
  echo "REPRODUCED: re-fetching the event failed inside GiveWP, but Stripe got HTTP 200 and will not resend it;"
  echo "the paid donation stays 'processing' (control: the same delivery with Stripe reachable completes it)."
else
  echo "NOT REPRODUCED (outage: HTTP $OUTAGE_CODE, $OUTAGE_STATE; control: $OK_STATE)"
  exit 1
fi
