#!/bin/bash
# Harness for Paid Memberships Pro: a Stripe webhook whose event can't be fetched from Stripe is still answered 200.
# PMPro has no test suite, so this is a real WordPress site with PMPro and a real HTTP request to
# admin-ajax.php?action=stripe_webhook. Only stripe-php's HTTP transport is replaced (must-use plugin
# stand-fake-stripe.php, ApiRequestor::setHttpClient); nothing in PMPro is changed and Stripe is never contacted.
# Needs PHP 8 with mysqli, wp-cli, git, curl and MySQL/MariaDB (variables below).
# Run: DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=... bash run.sh [WORK_DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"
# Pinned commit (3.8.8). Override to run at another commit, e.g. a branch with a fix:
#   PMPRO_REPO=https://github.com/<fork>/paid-memberships-pro PMPRO_COMMIT=<sha> bash run.sh
COMMIT="${PMPRO_COMMIT:-bb8b0dd948e5476759648660f148427b05325a4b}"
REPO="${PMPRO_REPO:-https://github.com/strangerstudios/paid-memberships-pro}"
WP_VERSION="${WP_VERSION:-7.1.3}"
DB_HOST="${DB_HOST:-127.0.0.1:3306}"; DB_USER="${DB_USER:-root}"; DB_PASSWORD="${DB_PASSWORD:-}"; DB_NAME="${DB_NAME:-pmpro_stand}"
PORT="${PORT:-8899}"
URL="http://127.0.0.1:$PORT"

mkdir -p "$WORK" && cd "$WORK"
if [ ! -f site/wp-load.php ]; then
  wp core download --version="$WP_VERSION" --path=site --quiet
fi
cd site
[ -f wp-config.php ] || wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost="$DB_HOST" --skip-check --quiet
# create the database without needing the mysql client (wp db create shells out to it)
php -r '[$h,$p]=array_pad(explode(":",$argv[1]),2,3306); $m=new mysqli($h,$argv[2],$argv[3],"",(int)$p); $m->query("CREATE DATABASE IF NOT EXISTS `".$argv[4]."`") or exit(1);' "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
if wp core is-installed 2>/dev/null; then echo "database $DB_NAME already has a WordPress site; use an empty database (DB_NAME=...)" >&2; exit 2; fi
wp core install --url="$URL" --title=Stand --admin_user=admin --admin_password=admin --admin_email=admin@example.test --skip-email --quiet
if [ ! -d wp-content/plugins/paid-memberships-pro/.git ]; then
  git init -q wp-content/plugins/paid-memberships-pro
  git -C wp-content/plugins/paid-memberships-pro remote add origin "$REPO"
  git -C wp-content/plugins/paid-memberships-pro fetch -q --depth 1 origin "$COMMIT"
  git -C wp-content/plugins/paid-memberships-pro checkout -q FETCH_HEAD
fi
mkdir -p wp-content/mu-plugins
cp -r "$HERE/stand-fake-stripe.php" "$HERE/stand-fake-stripe" wp-content/mu-plugins/
wp plugin activate paid-memberships-pro --quiet
wp eval-file "$HERE/seed.php"

php -S "127.0.0.1:$PORT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

post_event() {   # the body Stripe sends: an event id; PMPro re-fetches the event from Stripe by that id
  curl -s -o /tmp/pmpro-stand-body.txt -w '%{http_code}' -X POST "$URL/wp-admin/admin-ajax.php?action=stripe_webhook" \
    -H 'Content-Type: application/json' \
    --data '{"id":"evt_test_1","object":"event","livemode":false,"type":"customer.subscription.deleted"}'
}

echo "== before:            $(wp eval-file "$HERE/check.php")"

# 1. Stripe is briefly unavailable when PMPro re-fetches the event.
wp option update stand_stripe_mode outage --quiet; wp option delete stand_stripe_calls --quiet
CODE=$(post_event)
echo "== outage: HTTP $CODE  $(wp eval-file "$HERE/check.php")"
echo "   body: $(tr '\n' ' ' < /tmp/pmpro-stand-body.txt | cut -c1-200)"
OUTAGE_CODE=$CODE
OUTAGE_STATE=$(wp eval-file "$HERE/check.php")

# 2. The event does not exist in this Stripe account (404): a 200 is right here, with or without a fix.
wp option update stand_stripe_mode missing --quiet; wp option delete stand_stripe_calls --quiet
CODE=$(post_event)
echo "== missing: HTTP $CODE  $(wp eval-file "$HERE/check.php")"
MISSING_CODE=$CODE

# 3. Control: the same delivery when Stripe answers.
wp option update stand_stripe_mode ok --quiet; wp option delete stand_stripe_calls --quiet
CODE=$(post_event)
OK_STATE=$(wp eval-file "$HERE/check.php")
echo "== ok:     HTTP $CODE  $OK_STATE"

echo
if [ "$OUTAGE_CODE" = "200" ] && echo "$OUTAGE_STATE" | grep -q 'subscription=active level=1 level_enddate=never' \
   && echo "$OUTAGE_STATE" | grep -q 'GET \\/v1\\/events\\/evt_test_1 (outage)' \
   && echo "$OK_STATE" | grep -q 'subscription=cancelled'; then
  echo "REPRODUCED: re-fetching the event failed inside PMPro, but Stripe got HTTP 200 and will not resend it."
  echo "The subscription Stripe cancelled stays active in PMPro and the membership never ends (control: the same"
  echo "delivery with Stripe reachable cancels it and sets an end date). A fix would answer 5xx on a transient failure."
elif [ "${OUTAGE_CODE:0:1}" = "5" ] && [ "$MISSING_CODE" = "200" ] && echo "$OK_STATE" | grep -q 'subscription=cancelled'; then
  echo "NOT REPRODUCED: with Stripe failing, the webhook answered HTTP $OUTAGE_CODE, so Stripe will send the event again;"
  echo "an event that does not exist still gets 200, and the control delivery cancels the subscription."
  exit 1
else
  echo "NOT REPRODUCED (outage: HTTP $OUTAGE_CODE, $OUTAGE_STATE; missing: HTTP $MISSING_CODE; control: $OK_STATE)"
  exit 1
fi
