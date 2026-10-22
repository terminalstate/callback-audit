#!/bin/bash
# Harness for Paid Memberships Pro - PayFast Gateway (pmpro-payfast): the ITN handler sends "HTTP/1.0 200 OK" before it checks
# anything, so when its own validation request to Payfast (/eng/query/validate) fails — timeout, 503, 403 page — the ITN for a
# completed payment is still answered 200. Payfast re-sends an ITN only when it gets no 200, so it never re-sends; the paid
# checkout order stays `token` and the buyer never gets the membership. Nothing in the add-on or in PMPro re-checks a Payfast
# token order.
# A real WordPress site with PMPro and the add-on from git, served over HTTP; a real checkout through PMPro's checkout page
# (the add-on creates the token order and redirects to Payfast); a real signed ITN POST to the notify_url from that redirect.
# Only Payfast's validation endpoint is answered locally (stand-fake-payfast.php). The source-IP check runs for real: the ITN
# carries X-Forwarded-For with an address that sandbox.payfast.co.za resolves to (the add-on's documented proxy path, taken
# because a passphrase is set). Without DNS the add-on's own debug switch is used instead (printed in the output).
# At the end fix.patch is applied to the stand's copy of the add-on (git apply, reverted afterwards) and the failures are repeated.
# Needs PHP 8 with mysqli, wp-cli, git, curl and MySQL/MariaDB (variables below).
# Run: DB_HOST=127.0.0.1:3306 DB_USER=root DB_PASSWORD=... bash run.sh [WORK_DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"
PMPRO_COMMIT="${PMPRO_COMMIT:-6b567c69d6a788941cd3b588d203dcd655a5cef6}"     # dev on 2026-10-21 (3.8.9)
PAYFAST_COMMIT="${PAYFAST_COMMIT:-95a8e43d701d543198aa74773561ad1948c85744}" # dev on 2026-10-21 (1.7.4)
PMPRO_REPO="${PMPRO_REPO:-https://github.com/strangerstudios/paid-memberships-pro}"
PAYFAST_REPO="${PAYFAST_REPO:-https://github.com/strangerstudios/pmpro-payfast}"
WP_VERSION="${WP_VERSION:-7.1.3}"
DB_HOST="${DB_HOST:-127.0.0.1:3306}"; DB_USER="${DB_USER:-root}"; DB_PASSWORD="${DB_PASSWORD:-}"; DB_NAME="${DB_NAME:-pmpro_payfast_stand}"
PORT="${PORT:-8911}"; URL="http://127.0.0.1:$PORT"; PASSPHRASE=stand-passphrase

mkdir -p "$WORK" && cd "$WORK"
export WP_CLI_CACHE_DIR="$WORK/.wp-cli-cache"
[ -f site/wp-load.php ] || wp core download --version="$WP_VERSION" --path=site --skip-content --quiet
rm -rf "$WP_CLI_CACHE_DIR"
cd site
mkdir -p wp-content/plugins wp-content/mu-plugins
[ -f wp-config.php ] || wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" --dbhost="$DB_HOST" --skip-check --quiet
php -r '[$h,$p]=array_pad(explode(":",$argv[1]),2,3306); $m=new mysqli($h,$argv[2],$argv[3],"",(int)$p); $m->query("CREATE DATABASE IF NOT EXISTS `".$argv[4]."`") or exit(1);' "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
if wp core is-installed 2>/dev/null; then echo "database $DB_NAME already has a WordPress site; use an empty database (DB_NAME=...)" >&2; exit 2; fi

PF_IP=$(php -r '$a = gethostbynamel("sandbox.payfast.co.za"); echo $a ? $a[0] : "";')
if [ -z "$PF_IP" ]; then
  wp config set PMPROPF_DEBUG true --raw --quiet; export STAND_PF_DEBUG=1
  echo "note: sandbox.payfast.co.za does not resolve here; the source-IP check is skipped with the add-on's debug switch"
fi
wp core install --url="$URL" --title=Stand --admin_user=admin --admin_password=admin --admin_email=admin@example.test --skip-email --quiet
fetch() {  # $1 = plugin dir, $2 = repo, $3 = commit
  git init -q "wp-content/plugins/$1"; git -C "wp-content/plugins/$1" remote add origin "$2"
  git -C "wp-content/plugins/$1" fetch -q --depth 1 origin "$3"; git -C "wp-content/plugins/$1" checkout -q "$3"
}
fetch paid-memberships-pro "$PMPRO_REPO" "$PMPRO_COMMIT"
fetch pmpro-payfast "$PAYFAST_REPO" "$PAYFAST_COMMIT"
cp "$HERE/stand-fake-payfast.php" wp-content/mu-plugins/
mkdir -p wp-content/themes/stand   # a bare theme: PMPro's pages are shortcodes rendered by the_content()
printf '/*\nTheme Name: Stand\n*/\n' > wp-content/themes/stand/style.css
printf '<?php wp_head(); while ( have_posts() ) { the_post(); the_content(); } wp_footer();\n' > wp-content/themes/stand/index.php
wp theme activate stand --quiet
wp plugin activate paid-memberships-pro pmpro-payfast --quiet
wp eval-file "$HERE/seed.php"
CHECKOUT_PAGE=$(wp option get pmpro_checkout_page_id)
LEVEL_ONE=$(wp option get stand_level_one_time); LEVEL_SUB=$(wp option get stand_level_monthly)

php -d display_errors=0 -S "127.0.0.1:$PORT" >"$WORK/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null; git -C "$WORK/site/wp-content/plugins/pmpro-payfast" checkout -q . 2>/dev/null || true' EXIT
sleep 1

N=0
checkout() {  # $1 = level id; a new buyer checks out through PMPro's checkout page. Sets REDIRECT (the Payfast URL) and CODE.
  N=$((N + 1))
  local page="$URL/?page_id=$CHECKOUT_PAGE&pmpro_level=$1" nonce
  nonce=$(curl -s "$page" | grep -o 'name="pmpro_checkout_nonce" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"$//')
  REDIRECT=$(curl -s -o /dev/null -w '%{redirect_url}' -X POST "$page" \
    --data-urlencode "pmpro_level=$1" --data-urlencode "checkjavascript=1" --data-urlencode "javascriptok=1" \
    --data-urlencode "username=buyer$N" --data-urlencode "password=Stand-pass-$N" --data-urlencode "password2=Stand-pass-$N" \
    --data-urlencode "bemail=buyer$N@example.test" --data-urlencode "bconfirmemail=buyer$N@example.test" --data-urlencode "fullname=" \
    --data-urlencode "pmpro_checkout_nonce=$nonce" --data-urlencode "submit-checkout=1")
  case "$REDIRECT" in https://sandbox.payfast.co.za/eng/process\?*) ;; *) echo "checkout did not redirect to Payfast: '$REDIRECT'" >&2; exit 1;; esac
  CODE=$(php -r 'parse_str(parse_url($argv[1], PHP_URL_QUERY), $q); echo $q["m_payment_id"];' "$REDIRECT")
}
itn() {  # $1 = validation mode, $2 = pf_payment_id, [$3 = custom_str1]; posts the ITN for $REDIRECT; prints the HTTP status
  local notify body
  wp option update stand_payfast_mode "$1" --quiet; wp option delete stand_payfast_calls stand_mails --quiet >/dev/null 2>&1 || true
  notify=$(php -r 'parse_str(parse_url($argv[1], PHP_URL_QUERY), $q); echo $q["notify_url"];' "$REDIRECT")
  body=$(php "$HERE/itn.php" "$REDIRECT" "$2" "$PASSPHRASE" ${3:+"$3"})
  curl -s -o "$WORK/last-itn-response.txt" -w '%{http_code}' -X POST "$notify" ${PF_IP:+-H "X-Forwarded-For: $PF_IP"} \
    -H 'Content-Type: application/x-www-form-urlencoded' --data "$body"
}
state() { wp eval-file "$HERE/check.php" "$CODE"; }
row() {  # $1 = label, $2 = HTTP status; prints one line and the state
  local s; s=$(state)
  printf '%-58s HTTP %s  %s\n' "$1" "$2" "$s"
  LAST_STATE=$s
}
RESULTS=""
note() { RESULTS="$RESULTS|$1:$2:$3"; }  # label:http:state

echo "WordPress $WP_VERSION, PHP $(php -r 'echo PHP_VERSION;'), PMPro $(git -C wp-content/plugins/paid-memberships-pro log -1 --format='%h %cs'), pmpro-payfast $(git -C wp-content/plugins/pmpro-payfast log -1 --format='%h %cs')"
if [ -n "$PF_IP" ]; then echo "source-IP check: real (X-Forwarded-For $PF_IP, an address of sandbox.payfast.co.za)"; else echo "source-IP check: skipped (debug switch)"; fi
echo
echo "== one-time level (R100): checkout, then the ITN for the completed payment"
for mode in timeout 503 403 invalid; do
  checkout "$LEVEL_ONE"; [ "$mode" = timeout ] && LOST_REDIRECT=$REDIRECT LOST_CODE=$CODE
  code=$(itn "$mode" "1000$N"); row "validation: $mode" "$code"; note "$mode" "$code" "$LAST_STATE"
  [ "$mode" = timeout ] && echo "   response body: $(head -c 120 "$WORK/last-itn-response.txt" | tr '\n\t' '  ')"
done
checkout "$LEVEL_ONE"; code=$(itn valid "1000$N"); row "control, validation: VALID" "$code"; note valid "$code" "$LAST_STATE"
REDIRECT=$LOST_REDIRECT; CODE=$LOST_CODE
wp option delete stand_payfast_calls stand_mails --quiet >/dev/null 2>&1 || true; wp cron event run --all --quiet >/dev/null 2>&1 || true
row "'timeout' order after running every WP-Cron event" "-"; note cron "-" "$LAST_STATE"
code=$(itn valid "10001"); row "same ITN as 'timeout' sent again, validation VALID" "$code"; note resend "$code" "$LAST_STATE"
echo "   (Payfast sends an ITN again only when it got no 200 — it got 200, so this delivery never happens)"

echo
echo "== monthly subscription (R100 now, R100 a month): first ITN, validation times out; renewal ITN a month later"
checkout "$LEVEL_SUB"; SUB_FIRST=$(php -r 'parse_str(parse_url($argv[1], PHP_URL_QUERY), $q); echo $q["custom_str1"];' "$REDIRECT")
code=$(itn timeout "2000$N"); row "first payment, validation: timeout" "$code"; note sub_first "$code" "$LAST_STATE"
MONTH_AGO=$(php -r 'echo date("Y-m-d", strtotime("-31 days"));')
code=$(itn valid "2001$N" "$MONTH_AGO"); row "renewal ITN (custom_str1=$MONTH_AGO), validation VALID" "$code"; note sub_renewal "$code" "$LAST_STATE"
checkout "$LEVEL_SUB"; code=$(itn valid "2000$N"); row "control: first payment, validation VALID" "$code"; note sub_valid "$code" "$LAST_STATE"
echo "   (custom_str1 at checkout: $SUB_FIRST — the renewal ITN carries the checkout date; here the order is new, so the date is set back)"

echo
echo "== with fix.patch on the stand's copy of the add-on"
git -C wp-content/plugins/pmpro-payfast apply "$HERE/fix.patch"
for mode in timeout 503 403 invalid; do
  checkout "$LEVEL_ONE"; [ "$mode" = timeout ] && FIX_REDIRECT=$REDIRECT FIX_CODE=$CODE
  code=$(itn "$mode" "3000$N"); row "fix, validation: $mode" "$code"; note "fix_$mode" "$code" "$LAST_STATE"
  [ "$mode" = timeout ] && echo "   response body: $(head -c 120 "$WORK/last-itn-response.txt" | tr '\n\t' '  ')"
done
REDIRECT=$FIX_REDIRECT; CODE=$FIX_CODE; FIRST_FIX_N=$((N - 3))
code=$(itn valid "3000$FIRST_FIX_N"); row "fix, 'timeout' ITN re-sent by Payfast, validation VALID" "$code"; note fix_resend "$code" "$LAST_STATE"
code=$(itn valid "3000$FIRST_FIX_N"); row "fix, the same ITN once more (duplicate)" "$code"; note fix_dup "$code" "$LAST_STATE"
git -C wp-content/plugins/pmpro-payfast checkout -q .

echo
get() { local x="${RESULTS#*|$1:}"; echo "${x%%|*}"; }
ok=1
for m in timeout 503 403; do [[ "$(get "$m")" == 200:*"status=token level=none"* ]] || ok=0; done
[[ "$(get invalid)" == 200:*"status=token level=none"* ]] || ok=0
[[ "$(get valid)" == 200:*"status=success level=$LEVEL_ONE"* ]] || ok=0
[[ "$(get cron)" == -:*"status=token level=none"* ]] || ok=0
[[ "$(get resend)" == 200:*"status=success level=$LEVEL_ONE"* ]] || ok=0
[[ "$(get sub_first)" == 200:*"status=token level=none"* ]] || ok=0
[[ "$(get sub_renewal)" == 200:*"status=token level=none orders=[token,success("* ]] || ok=0
[[ "$(get sub_valid)" == 200:*"status=success level=$LEVEL_SUB"* ]] || ok=0
fix=1
for m in timeout 503 403; do [[ "$(get "fix_$m")" == 503:*"status=token level=none"* ]] || fix=0; done
[[ "$(get fix_invalid)" == 200:*"status=token level=none"* ]] || fix=0
[[ "$(get fix_resend)" == 200:*"status=success level=$LEVEL_ONE"* ]] || fix=0
[[ "$(get fix_dup)" == 200:*"status=success level=$LEVEL_ONE"*"mails=0 "* ]] || fix=0
if [ $ok = 1 ]; then
  echo "REPRODUCED: with the validation request failing (timeout, 503, 403) the ITN for a completed payment got HTTP 200, so Payfast"
  echo "will not send it again; the checkout order stayed 'token' and the buyer has no membership. The same ITN with validation"
  echo "answering VALID completes the checkout. For a subscription, the later renewal ITN is recorded as a paid renewal order"
  echo "while the buyer still has no membership."
else
  echo "NOT REPRODUCED as described — see the rows above"
fi
if [ $fix = 1 ]; then echo "FIX WORKS: 503 for timeout/503/403 (Payfast re-sends), 200 for INVALID, the re-sent ITN completes the checkout,"; echo "a duplicate of it changes nothing and sends no e-mails."; else echo "FIX: not as expected — see the rows above"; fi
