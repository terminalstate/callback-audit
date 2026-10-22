#!/bin/bash
# Harness for Paystack WooCommerce Payment Gateway (woo-paystack): when the plugin's own GET /transaction/verify/<ref> fails
# inside the charge.success webhook (5xx, 429, timeout), process_webhooks() just returns — WooCommerce has already set 200 —
# so Paystack marks the event delivered and never resends it; the paid order stays pending and WooCommerce cancels it.
# A real WordPress site with WooCommerce and the plugin from git, a real charge.success POST signed with the secret key
# (x-paystack-signature = HMAC-SHA512 of the body) to ?wc-api=tbz_wc_paystack_webhook. Only api.paystack.co is faked (mu-plugin).
# Needs PHP 8 with mysqli, wp-cli, git, curl and MySQL/MariaDB (variables below).
# Run: DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=... bash run.sh [WORK_DIR]
# PAYSTACK_PATCH=fix.patch applies a change to the plugin first (the fix proposed in the report) and checks Paystack's resend.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH=""; [ -n "${PAYSTACK_PATCH:-}" ] && PATCH="$(cd "$(dirname "$PAYSTACK_PATCH")" && pwd)/$(basename "$PAYSTACK_PATCH")"
WORK="${1:-$(mktemp -d)}"
COMMIT="${PAYSTACK_COMMIT:-830da0c43695bdd266f2fd5bce8db6757567055b}"   # master on 2026-10-20 (5.8.5, as on WordPress.org)
REPO="${PAYSTACK_REPO:-https://github.com/PaystackOSS/woo-paystack}"
WP_VERSION="${WP_VERSION:-7.1.3}"; WC_VERSION="${WC_VERSION:-11.2.1}"
DB_HOST="${DB_HOST:-127.0.0.1:3306}"; DB_USER="${DB_USER:-root}"; DB_PASSWORD="${DB_PASSWORD:-}"; DB_NAME="${DB_NAME:-paystack_stand}"
PORT="${PORT:-8898}"; URL="http://127.0.0.1:$PORT"; SECRET=sk_test_0000standinvented

mkdir -p "$WORK" && cd "$WORK"
[ -f site/wp-load.php ] || wp core download --version="$WP_VERSION" --path=site --quiet
cd site
[ -f wp-config.php ] || wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost="$DB_HOST" --skip-check --quiet
php -r '[$h,$p]=array_pad(explode(":",$argv[1]),2,3306); $m=new mysqli($h,$argv[2],$argv[3],"",(int)$p); $m->query("CREATE DATABASE IF NOT EXISTS `".$argv[4]."`") or exit(1);' "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
if wp core is-installed 2>/dev/null; then echo "database $DB_NAME already has a WordPress site; use an empty database (DB_NAME=...)" >&2; exit 2; fi
wp core install --url="$URL" --title=Stand --admin_user=admin --admin_password=admin --admin_email=admin@example.test --skip-email --quiet
wp plugin install woocommerce --version="$WC_VERSION" --activate --quiet
P=wp-content/plugins/woo-paystack
git init -q "$P"; git -C "$P" remote add origin "$REPO"
git -C "$P" fetch -q --depth 1 origin "$COMMIT"
git -C "$P" checkout -q "$COMMIT"
[ -z "$PATCH" ] || git -C "$P" apply "$PATCH"
mkdir -p wp-content/mu-plugins
cp "$HERE/stand-fake-paystack.php" wp-content/mu-plugins/
wp plugin activate woo-paystack --quiet
wp eval-file "$HERE/seed.php"

php -d display_errors=0 -S "127.0.0.1:$PORT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

webhook() {  # $1 = reference, $2 = amount in kobo; prints the HTTP status (the handler sleeps 10 s before verifying)
  local out sig body
  out=$(php "$HERE/sign.php" "$1" "$2" "$SECRET"); sig=${out%%$'\n'*}; body=${out#*$'\n'}
  curl -s -o "$WORK/last-body.txt" -w '%{http_code}' -X POST "$URL/?wc-api=tbz_wc_paystack_webhook" \
    -H 'Content-Type: application/json' -H "x-paystack-signature: $sig" --data-binary "$body"
}

scenario() {  # $1 = verify mode, $2 = label; leaves the order id and reference in LAST_ID, LAST_REF
  local id ref code
  read -r id ref < <(wp eval-file "$HERE/create-order.php")
  wp option update stand_paystack_verify "$1" --quiet; wp option update stand_paystack_calls 0 --quiet
  code=$(webhook "$ref" "$(wp option get stand_paystack_amount)")
  echo "== $2: charge.success -> HTTP $code"
  echo "   $(wp eval-file "$HERE/check.php" "$id")"
  LAST_ID=$id; LAST_REF=$ref; CODES="$CODES $code"
}

resend() {  # $1 = label; Paystack's resend of the last delivery, the verify call answering
  local code
  wp option update stand_paystack_verify success --quiet
  code=$(webhook "$LAST_REF" "$(wp option get stand_paystack_amount)")
  echo "== $1: charge.success -> HTTP $code"
  echo "   $(wp eval-file "$HERE/check.php" "$LAST_ID")"
  CODES="$CODES $code"
}

CODES=""
echo "plugin: $(git -C "$P" log -1 --format='%h %cs %s')${PATCH:+ + $(basename "$PATCH")}"
if [ -z "$PATCH" ]; then
  scenario 503 "verify answers 503"; A=$(wp eval-file "$HERE/check.php" "$LAST_ID"); A_ID=$LAST_ID
  scenario wp_error "verify times out (WP_Error)"; B=$(wp eval-file "$HERE/check.php" "$LAST_ID")
  scenario 429 "verify answers 429"; C=$(wp eval-file "$HERE/check.php" "$LAST_ID")
  scenario success "control: verify succeeds"; D=$(wp eval-file "$HERE/check.php" "$LAST_ID")
  wp eval-file "$HERE/cancel-unpaid.php" "$A_ID"
  A2=$(wp eval-file "$HERE/check.php" "$A_ID")
  echo "   503 order after wc_cancel_unpaid_orders(): $A2"
  echo
  if [[ "$A" == *"status=pending paid_date=none"*"paystack_calls=1"* && "$B" == *"status=pending"* && "$C" == *"status=pending"* \
     && "$D" == *"status=processing paid_date=set"* && "$A2" == *"status=cancelled"* && "$CODES" == " 200 200 200 200" ]]; then
    echo "REPRODUCED: with the verify call failing (503, timeout, 429) the charge.success webhook is answered 200 and nothing is"
    echo "applied — Paystack treats it as delivered; the order stays pending and WooCommerce cancels it. The same delivery with"
    echo "verify succeeding completes the order, so a resend would have fixed it."
  else
    echo "NOT REPRODUCED (HTTP:$CODES; 503: $A; timeout: $B; 429: $C; control: $D; after cancel: $A2)"
  fi
else
  scenario wp_error "verify times out (WP_Error)"; B=$(wp eval-file "$HERE/check.php" "$LAST_ID")
  scenario 429 "verify answers 429"; C=$(wp eval-file "$HERE/check.php" "$LAST_ID")
  scenario 503 "verify answers 503"; A=$(wp eval-file "$HERE/check.php" "$LAST_ID")
  resend "Paystack's resend, verify answers"; R=$(wp eval-file "$HERE/check.php" "$LAST_ID")
  resend "duplicate resend"; R2=$(wp eval-file "$HERE/check.php" "$LAST_ID")
  scenario success "control: verify succeeds"; D=$(wp eval-file "$HERE/check.php" "$LAST_ID")
  echo
  if [[ "$CODES" == " 503 503 503 200 200 200" && "$A" == *"status=pending"* && "$R" == *"status=processing paid_date=set"* \
     && "${R2%% paystack_calls=*}" == "${R%% paystack_calls=*}" && "$D" == *"status=processing paid_date=set"* ]]; then
    echo "FIXED: a failed verify call is answered 503, so Paystack resends; the resend completes the order and a duplicate"
    echo "resend changes nothing."
  else
    echo "NOT FIXED (HTTP:$CODES; timeout: $B; 429: $C; 503: $A; resend: $R; duplicate: $R2; control: $D)"
  fi
fi
