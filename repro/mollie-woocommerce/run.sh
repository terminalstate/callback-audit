#!/usr/bin/env bash
# Runs both webhook entry points of Mollie Payments for WooCommerce against a fake Mollie API and
# prints one table row per answer of the API. First run clones the plugin and its PHP dependencies.
#   ./run.sh
#   PLUGIN_DIR=/path/to/mollie-woocommerce ./run.sh
set -euo pipefail
cd "$(dirname "$0")"
export PLUGIN_DIR="${PLUGIN_DIR:-$PWD/mollie-woocommerce}"
if [[ ! -f "$PLUGIN_DIR/mollie-payments-for-woocommerce.php" ]]; then
    git clone -q https://github.com/mollie/WooCommerce "$PLUGIN_DIR"
    git -C "$PLUGIN_DIR" checkout -q 4d75849d6c72e8206a7cb5126585aebf57224b03   # 8.1.10
fi
# The versions in the plugin's composer.lock.
mkdir -p deps
dep() { [[ -d "deps/$1" ]] || git -c advice.detachedHead=false clone -q --depth 1 --branch "$3" "https://github.com/$2" "deps/$1"; }
dep mollie-api-php mollie/mollie-api-php v2.79.1
dep log php-fig/log 1.1.4
dep container php-fig/container 1.1.0
dep ca-bundle composer/ca-bundle 1.5.14

PORT=8794
php -d display_errors=0 -S 127.0.0.1:$PORT router.php >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
sleep 0.7

# One webhook POST; prints "<status> <order status after it> <API calls>".
post() {
    curl -s -o /dev/null -D - -X POST -H "X-Mollie-Api: $1" --data "id=tr_WDqYK6vllg" "http://127.0.0.1:$PORT$2" |
        tr -d '\r' | awk '/^HTTP\//{c=$2} /^X-Order-Status:/{o=$2} /^X-Api-Calls:/{n=$2} END{print c, o, n}'
}

echo "| Mollie API answer | REST webhook (default) | WC-API webhook (legacy) | Order afterwards | API calls per webhook |"
echo "|---|---|---|---|---|"
for answer in paid timeout 503 429 404; do
    read -r rest order calls <<<"$(post "$answer" /wp-json/mollie/v1/webhook)"
    read -r legacy _ _ <<<"$(post "$answer" "/?wc-api=mollie_wc_gateway_ideal&order_id=1234&key=wc_order_demo")"
    echo "| $answer | $rest | $legacy | $order | $calls |"
done
