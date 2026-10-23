#!/bin/bash
# Harness for Paid Memberships Pro - PayPal Gateway (pmpro-paypal, REST/Orders v2): after capturing an approved one-time order,
# the add-on checks only the ORDER status ('COMPLETED') and never captures[0].status, so a capture that PayPal reports as PENDING
# (manual review, eCheck) or DECLINED inside a COMPLETED order completes the checkout: the buyer gets the membership and the order
# is marked paid. PayPal's docs: "Check the payment status in purchase_units[].payments.captures[].status before fulfilling the
# order." / "A completed order can indicate … a payment was declined." The later PAYMENT.CAPTURE.DENIED is not handled.
# A real WordPress site with PMPro and the add-on from git, served over HTTP; a real checkout through PMPro's checkout page (the
# add-on creates the PayPal order and redirects to PayPal's approve link); real webhook POSTs to the add-on's REST route. Only
# PayPal's API is answered locally (stand-fake-paypal.php), including the verify-webhook-signature postback (SUCCESS): PayPal
# verifies webhooks by that postback, so this is provider HTTP, not a bypass. A webhook id is stored, so the live verify path runs.
# At the end fix.patch is applied to the stand's copy of the add-on (git apply, reverted afterwards) and the cases are repeated.
# Needs PHP 8 with mysqli, wp-cli, git, curl and MySQL/MariaDB (variables below).
# Run: DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=... bash run.sh [WORK_DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"
PMPRO_COMMIT="${PMPRO_COMMIT:-6b567c69d6a788941cd3b588d203dcd655a5cef6}"   # dev on 2026-10-21 (3.8.9)
PAYPAL_COMMIT="${PAYPAL_COMMIT:-29164a9c6ade6869620eb8fe2ae2abca35f892a1}" # dev on 2026-10-21 (1.1.4)
PMPRO_REPO="${PMPRO_REPO:-https://github.com/strangerstudios/paid-memberships-pro}"
PAYPAL_REPO="${PAYPAL_REPO:-https://github.com/strangerstudios/pmpro-paypal}"
WP_VERSION="${WP_VERSION:-7.1.3}"
DB_HOST="${DB_HOST:-127.0.0.1:3306}"; DB_USER="${DB_USER:-root}"; DB_PASSWORD="${DB_PASSWORD:-}"; DB_NAME="${DB_NAME:-pmpro_paypal_stand}"
PORT="${PORT:-8912}"; URL="http://127.0.0.1:$PORT"

mkdir -p "$WORK" && cd "$WORK"
export WP_CLI_CACHE_DIR="$WORK/.wp-cli-cache"
[ -f site/wp-load.php ] || wp core download --version="$WP_VERSION" --path=site --skip-content --quiet
rm -rf "$WP_CLI_CACHE_DIR"
cd site
mkdir -p wp-content/plugins wp-content/mu-plugins
[ -f wp-config.php ] || wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost="$DB_HOST" --skip-check --quiet
php -r '[$h,$p]=array_pad(explode(":",$argv[1]),2,3306); $m=new mysqli($h,$argv[2],$argv[3],"",(int)$p); $m->query("CREATE DATABASE IF NOT EXISTS `".$argv[4]."`") or exit(1);' "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
if wp core is-installed 2>/dev/null; then echo "database $DB_NAME already has a WordPress site; use an empty database (DB_NAME=...)" >&2; exit 2; fi
wp core install --url="$URL" --title=Stand --admin_user=admin --admin_password=admin --admin_email=admin@example.test --skip-email --quiet
fetch() {  # $1 = plugin dir, $2 = repo, $3 = commit
  git init -q "wp-content/plugins/$1"; git -C "wp-content/plugins/$1" remote add origin "$2"
  git -C "wp-content/plugins/$1" fetch -q --depth 1 origin "$3"; git -C "wp-content/plugins/$1" checkout -q "$3"
}
fetch paid-memberships-pro "$PMPRO_REPO" "$PMPRO_COMMIT"
fetch pmpro-paypal "$PAYPAL_REPO" "$PAYPAL_COMMIT"
cp "$HERE/stand-fake-paypal.php" wp-content/mu-plugins/
mkdir -p wp-content/themes/stand   # a bare theme: PMPro's pages are shortcodes rendered by the_content()
printf '/*\nTheme Name: Stand\n*/\n' > wp-content/themes/stand/style.css
printf '<?php wp_head(); while ( have_posts() ) { the_post(); the_content(); } wp_footer();\n' > wp-content/themes/stand/index.php
wp theme activate stand --quiet
wp plugin activate paid-memberships-pro pmpro-paypal --quiet
wp eval-file "$HERE/seed.php"
CHECKOUT_PAGE=$(wp option get pmpro_checkout_page_id); LEVEL=$(wp option get stand_level)

php -d display_errors=0 -S "127.0.0.1:$PORT" >"$WORK/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; git -C "$WORK/site/wp-content/plugins/pmpro-paypal" checkout -q . 2>/dev/null || true' EXIT
sleep 1

N=0
reset() { wp option delete stand_paypal_calls stand_mails --quiet >/dev/null 2>&1 || true; }
checkout() {  # $1 = capture status PayPal will report; a new buyer checks out through PMPro's checkout page. Sets PP (PayPal order id).
  N=$((N + 1))
  local page="$URL/?page_id=$CHECKOUT_PAGE&pmpro_level=$LEVEL" nonce redirect
  wp option update stand_paypal_capture "$1" --quiet
  nonce=$(curl -s "$page" | grep -o 'name="pmpro_checkout_nonce" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"$//')
  redirect=$(curl -s -o /dev/null -w '%{redirect_url}' -X POST "$page" \
    --data-urlencode "pmpro_level=$LEVEL" --data-urlencode "checkjavascript=1" --data-urlencode "javascriptok=1" \
    --data-urlencode "username=buyer$N" --data-urlencode "password=Stand-pass-$N" --data-urlencode "password2=Stand-pass-$N" \
    --data-urlencode "bemail=buyer$N@example.test" --data-urlencode "bconfirmemail=buyer$N@example.test" --data-urlencode "fullname=" \
    --data-urlencode "pmpro_checkout_nonce=$nonce" --data-urlencode "submit-checkout=1")
  case "$redirect" in https://www.sandbox.paypal.com/checkoutnow\?token=*) ;; *) echo "checkout did not redirect to PayPal: '$redirect'" >&2; exit 1;; esac
  PP=${redirect#*token=}
}
webhook() {  # $1 = event type, $2 = resource id, [$3 = resource status]; prints the HTTP status, keeps the body
  local body; reset
  body=$(php "$HERE/event.php" "$1" "$2" ${3:+"$3"})
  curl -s -o "$WORK/last-webhook-response.txt" -w '%{http_code}' -X POST "$URL/?rest_route=/pmpro-paypal/v1/webhook" \
    -H 'Content-Type: application/json' -H "PAYPAL-TRANSMISSION-ID: $(php -r 'echo bin2hex(random_bytes(16));')" \
    -H "PAYPAL-TRANSMISSION-TIME: $(date -u +%Y-%m-%dT%H:%M:%SZ)" -H "PAYPAL-TRANSMISSION-SIG: $(php -r 'echo base64_encode(random_bytes(64));')" \
    -H 'PAYPAL-CERT-URL: https://api.sandbox.paypal.com/v1/notifications/certs/CERT-360caa42-fca2a594-stand' \
    -H 'PAYPAL-AUTH-ALGO: SHA256withRSA' --data-binary "$body"
}
recheck() {  # the admin's "Recheck Payment" on the order (core pmpro_check_token_order_for_completion → add-on check_token_order)
  reset; wp eval-file "$HERE/recheck.php" "$PP"
}
row() {  # $1 = label, $2 = HTTP status or "-"; prints one line with the state and the handler's answer
  local s msg="" ; s=$(wp eval-file "$HERE/check.php" "$PP")
  [ "$2" != "-" ] && msg=$(php -r '$j = json_decode(file_get_contents($argv[1]), true); echo $j["message"] ?? $j["error"] ?? "";' "$WORK/last-webhook-response.txt")
  local h="HTTP $2"; [ "$2" = "-" ] && h="(no HTTP)"
  printf '%-56s %-9s %s\n' "$1" "$h" "$s"
  [ -n "$msg" ] && printf '%-56s          handler: "%s"\n' "" "$msg"
  RESULTS="$RESULTS|$3:$2:$s"
}
RESULTS=""
get() { local x="${RESULTS#*|$1:}"; echo "${x%%|*}"; }

echo "WordPress $WP_VERSION, PHP $(php -r 'echo PHP_VERSION;'), PMPro $(git -C wp-content/plugins/paid-memberships-pro log -1 --format='%h %cs'), pmpro-paypal $(git -C wp-content/plugins/pmpro-paypal log -1 --format='%h %cs')"
echo "one-time level, \$10; every webhook is verified by the add-on through PayPal's verify-webhook-signature postback"
EVENTS=$(wp eval-file "$HERE/register.php")
echo "events the add-on registers at PayPal on settings save: $EVENTS"
echo
echo "== buyer approves at PayPal, PayPal sends CHECKOUT.ORDER.APPROVED, the add-on captures"
checkout PENDING; P1=$PP
code=$(webhook CHECKOUT.ORDER.APPROVED "$PP"); row "capture PENDING (PENDING_REVIEW) in a COMPLETED order" "$code" pending
VERIFY=$(wp option get stand_paypal_last_verify)
wp eval-file "$HERE/settle.php" "$PP" DECLINED >/dev/null
code=$(webhook PAYMENT.CAPTURE.DENIED "CAP-$(php -r 'echo substr(md5($argv[1]),0,12);' "$PP")" DECLINED)
row "  review refused: PayPal sends PAYMENT.CAPTURE.DENIED" "$code" denied
checkout DECLINED
code=$(webhook CHECKOUT.ORDER.APPROVED "$PP"); row "capture DECLINED in a COMPLETED order" "$code" declined
checkout COMPLETED
code=$(webhook CHECKOUT.ORDER.APPROVED "$PP"); row "control: capture COMPLETED" "$code" completed
echo
echo "== the webhook did not arrive; the admin presses \"Recheck Payment\" on the token order"
checkout PENDING
echo "   recheck returned: $(recheck)"; row "recheck, capture PENDING (PENDING_REVIEW)" "-" recheck_pending
echo
echo "   verify postback body sent to PayPal (first event): $(echo "$VERIFY" | head -c 200)…"

echo
echo "== with fix.patch on the stand's copy of the add-on"
git -C wp-content/plugins/pmpro-paypal apply "$HERE/fix.patch"
echo "events registered with the fix: $(wp eval-file "$HERE/register.php")"
cap() { php -r 'echo "CAP-" . substr(md5($argv[1]),0,12);' "$1"; }
code=$(webhook PAYMENT.CAPTURE.DENIED "$(cap "$P1")" DECLINED); PP=$P1
row "fix, DENIED for an order completed before the fix" "$code" fix_old_denied
checkout PENDING
code=$(webhook CHECKOUT.ORDER.APPROVED "$PP"); row "fix, capture PENDING (PENDING_REVIEW)" "$code" fix_pending
wp eval-file "$HERE/settle.php" "$PP" COMPLETED >/dev/null
code=$(webhook PAYMENT.CAPTURE.COMPLETED "$(cap "$PP")" COMPLETED)
row "fix,   review clears: PAYMENT.CAPTURE.COMPLETED" "$code" fix_capture_completed
code=$(webhook PAYMENT.CAPTURE.COMPLETED "$(cap "$PP")" COMPLETED)
row "fix,   the same event again" "$code" fix_capture_completed_dup
checkout PENDING
code=$(webhook CHECKOUT.ORDER.APPROVED "$PP"); row "fix, capture PENDING (PENDING_REVIEW)" "$code" fix_pending2
wp eval-file "$HERE/settle.php" "$PP" DECLINED >/dev/null
code=$(webhook PAYMENT.CAPTURE.DENIED "$(cap "$PP")" DECLINED)
row "fix,   review refused: PAYMENT.CAPTURE.DENIED" "$code" fix_denied
checkout DECLINED
code=$(webhook CHECKOUT.ORDER.APPROVED "$PP"); row "fix, capture DECLINED" "$code" fix_declined
checkout COMPLETED
code=$(webhook CHECKOUT.ORDER.APPROVED "$PP"); row "fix, capture COMPLETED" "$code" fix_completed
code=$(webhook PAYMENT.CAPTURE.COMPLETED "$(cap "$PP")" COMPLETED)
row "fix,   PayPal's PAYMENT.CAPTURE.COMPLETED for it" "$code" fix_completed_event
checkout PENDING
echo "   recheck returned: $(recheck)"; row "fix, recheck, capture PENDING" "-" fix_recheck_pending
wp eval-file "$HERE/settle.php" "$PP" COMPLETED >/dev/null
echo "   recheck returned: $(recheck)"; row "fix, recheck after the capture completed" "-" fix_recheck_completed
git -C wp-content/plugins/pmpro-paypal checkout -q .

echo
ok=1
[[ "$(get pending)" == 200:*"status=success level=$LEVEL"*"paypal_capture=PENDING"* ]] || ok=0
[[ "$(get denied)" == 200:*"status=success level=$LEVEL"*"paypal_capture=DECLINED"* ]] || ok=0
[[ "$(get declined)" == 200:*"status=success level=$LEVEL"*"paypal_capture=DECLINED"* ]] || ok=0
[[ "$(get completed)" == 200:*"status=success level=$LEVEL"*"paypal_capture=COMPLETED"* ]] || ok=0
[[ "$(get recheck_pending)" == -:*"status=success level=$LEVEL"*"paypal_capture=PENDING"* ]] || ok=0
[[ "$VERIFY" == *'"webhook_id":"WH-STAND-0001"'*'"webhook_event":{'* ]] || ok=0
[[ "$EVENTS" == *CHECKOUT.ORDER.APPROVED* && "$EVENTS" != *PAYMENT.CAPTURE.COMPLETED* && "$EVENTS" != *PAYMENT.CAPTURE.DENIED* ]] || ok=0
fix=1
[[ "$(get fix_old_denied)" == 200:*"status=success level=$LEVEL"* ]] || fix=0
[[ "$(get fix_pending)" == 200:*"status=token level=none"*"paypal_capture=PENDING"* ]] || fix=0
[[ "$(get fix_capture_completed)" == 200:*"status=success level=$LEVEL"*"mails=2"* ]] || fix=0
[[ "$(get fix_capture_completed_dup)" == 200:*"status=success level=$LEVEL"*"mails=0"* ]] || fix=0
[[ "$(get fix_pending2)" == 200:*"status=token level=none"* ]] || fix=0
[[ "$(get fix_denied)" == 200:*"status=error level=none"* ]] || fix=0
[[ "$(get fix_declined)" == 200:*"status=error level=none"* ]] || fix=0
[[ "$(get fix_completed)" == 200:*"status=success level=$LEVEL"*"mails=2"* ]] || fix=0
[[ "$(get fix_completed_event)" == 200:*"status=success level=$LEVEL"*"mails=0"* ]] || fix=0
[[ "$(get fix_recheck_pending)" == -:*"status=token level=none"* ]] || fix=0
[[ "$(get fix_recheck_completed)" == -:*"status=success level=$LEVEL"* ]] || fix=0
if [ $ok = 1 ]; then
  echo "REPRODUCED: a COMPLETED order whose capture is PENDING or DECLINED completes the checkout — order 'success', membership"
  echo "granted, checkout e-mails sent — from the webhook and from the admin's recheck alike; PAYMENT.CAPTURE.DENIED is answered"
  echo "'Unhandled event type' and the membership stays."
else
  echo "NOT REPRODUCED as described — see the rows above"
fi
if [ $fix = 1 ]; then echo "FIX WORKS: PENDING keeps the order 'token' until PAYMENT.CAPTURE.COMPLETED (or Recheck) completes it, DENIED/DECLINED mark it 'error', COMPLETED completes once as before."; else echo "FIX: not as expected — see the rows above"; fi
