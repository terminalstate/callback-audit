#!/usr/bin/env bash
# Runs every scenario against the plugin's own code and prints one table row per scenario.
#   PLUGIN_DIR=/path/to/razorpay-woocommerce ./run.sh [--real-clock]
# --real-clock: wait the plugin's five-minute cron window for real instead of backdating
#               (adds ~5 minutes per scenario).
# ONLY="API 503" ./run.sh   runs only the scenarios whose label contains that text.
set -euo pipefail
cd "$(dirname "$0")"
export STATE_DIR="${STATE_DIR:-$PWD/state}"
export PLUGIN_DIR="${PLUGIN_DIR:-$PWD/razorpay-woocommerce}"
[[ -f "$PLUGIN_DIR/woo-razorpay.php" ]] || { echo "PLUGIN_DIR=$PLUGIN_DIR has no woo-razorpay.php (see README)" >&2; exit 2; }
REAL_CLOCK=0; [[ "${1:-}" == "--real-clock" ]] && REAL_CLOCK=1
mkdir -p "$STATE_DIR"

PHPFLAGS=(-d display_errors=0 -d log_errors=1 -d error_reporting=E_ALL)
pkill -f "php .* -S 127.0.0.1:879[23]" 2>/dev/null || true
sleep 0.3
php "${PHPFLAGS[@]}" -d error_log="$STATE_DIR/php-errors.log" -S 127.0.0.1:8792 router.php >"$STATE_DIR/store-server.log" 2>&1 &
STORE=$!
php "${PHPFLAGS[@]}" -S 127.0.0.1:8793 fake-api.php >"$STATE_DIR/api-server.log" 2>&1 &
API=$!
trap 'kill $STORE $API 2>/dev/null || true' EXIT
sleep 0.7

state() { curl -s http://127.0.0.1:8792/_harness/state; }
order_status() { state | php -r '$d = json_decode(stream_get_contents(STDIN), true); echo $d["order_status"];'; }
queue() { state | php -r '$d = json_decode(stream_get_contents(STDIN), true); $q = $d["queue"][0]; echo ($q["rzp_webhook_data"] === "[]" ? "no event stored" : "event stored") . ", status " . $q["rzp_update_order_cron_status"];'; }
cron() { curl -s -o /dev/null --max-time 130 'http://127.0.0.1:8792/wp-cron.php?hook=rzp_webhook_exec_cron'; }
api_calls() { [[ -f "$STATE_DIR/api.log" ]] && wc -l <"$STATE_DIR/api.log" | tr -d ' ' || echo 0; }
wait_window() {
    if [[ $REAL_CLOCK == 1 ]]; then sleep 305; else php backdate.php >/dev/null; fi
}

# action  signature  api-answer  label
SCENARIOS=(
  "capture   good  captured    control: API answers, payment captured"
  "capture   good  timeout     API timeout (SDK gives up after 60 s)"
  "capture   good  503         API 503"
  "capture   good  429         API 429 Too many requests"
  "authorize good  authorized  Payment Action = Authorize, payment authorized"
  "capture   bad   captured    signature does not match the secret"
  "capture   none  captured    no X-Razorpay-Signature header"
)

echo "| Scenario | Webhook answered | Queue row after the cron | Order after the cron | API calls | Cron again, API healthy |"
echo "|---|---|---|---|---|---|"
for s in "${SCENARIOS[@]}"; do
    read -r action sig answer label <<<"$s"
    [[ -n "${ONLY:-}" && "$label" != *"$ONLY"* ]] && continue
    php setup.php "$action" >/dev/null
    echo "$answer" >"$STATE_DIR/api-scenario"
    code=$(php send-webhook.php "$sig" | cut -d' ' -f1)
    wait_window
    cron
    after=$(order_status); q=$(queue); calls=$(api_calls)
    echo captured >"$STATE_DIR/api-scenario"
    [[ "$action" == "authorize" ]] && echo authorized >"$STATE_DIR/api-scenario"
    cron
    again="$(order_status) ($(( $(api_calls) - calls )) API calls)"
    echo "| $label | $code | $q | $after | $calls | $again |"
done

# For comparison: the browser callback for the same authorized payment, Payment Action = Authorize.
[[ -n "${ONLY:-}" ]] && exit 0
php setup.php authorize >/dev/null
echo authorized >"$STATE_DIR/api-scenario"
code=$(php send-callback.php | cut -d' ' -f1)
echo
echo "Browser callback, Payment Action = Authorize, payment authorized: HTTP $code, order $(order_status), queue row: $(queue)"
