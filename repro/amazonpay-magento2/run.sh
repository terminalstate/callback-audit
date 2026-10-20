#!/bin/bash
# Amazon Pay for Magento 2, "Charge when order is placed" + "Immediate": a capture that Amazon Pay declines is still invoiced
# as paid, and the later Declined notification is dropped as a duplicate. A unit test of the real
# CheckoutSessionManagement::handlePayment(), AmazonPayAdapter and AsyncManagement\Charge with the real Amazon Pay PHP SDK —
# no Magento install: module dependencies from the Mage-OS mirror + a minimal unit-test bootstrap. Faked: the SDK's HTTP
# client (SDK-shaped responses) and Magento repositories.
# Needs PHP 8.2+, Composer, git. Run: bash run.sh [WORK_DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"
COMMIT="${AMZ_COMMIT:-41c44b475fa915679f718b99adc2ec5283b2aeee}"   # master on 2026-10-20 (5.18.6)
mkdir -p "$WORK" && WORK="$(cd "$WORK" && pwd)" && cd "$WORK"
if [ ! -d plugin/.git ]; then
  git init -q plugin; git -C plugin remote add origin https://github.com/amzn/amazon-payments-magento-2-plugin
  git -C plugin fetch -q --depth 1 origin "$COMMIT"; git -C plugin checkout -q FETCH_HEAD
fi
if [ ! -d plugin/vendor ]; then
  (cd plugin && python3 - <<'PY'
import json; d=json.load(open('composer.json'))
d['repositories']=[{'type':'composer','url':'https://mirror.mage-os.org/'}]
d['require-dev']={'phpunit/phpunit':'^12.5'}
d.setdefault('config',{})['allow-plugins']={'magento/*':False,'laminas/*':False}
json.dump(d,open('composer.json','w'),indent=4)
PY
  composer update -q --no-interaction --no-scripts --no-plugins --prefer-dist)
fi
git -C plugin checkout -q -- Model/CheckoutSessionManagement.php
mkdir -p boot/tmp && cp -r "$HERE/bootstrap.php" "$HERE/phpunit.xml" "$HERE/tests" boot/
export AMZ_PLUGIN_ROOT="$WORK/plugin"
echo "== module at $(git -C plugin log -1 --format='%h %cs'), SDK $(grep -A1 '"name": "amzn/amazon-pay-api-sdk-php"' plugin/composer.lock | grep -o '[0-9.]*' | head -1)"
(cd boot && php "$AMZ_PLUGIN_ROOT/vendor/phpunit/phpunit/phpunit" -c phpunit.xml tests) || true
echo "== with fix.patch"
git -C plugin apply "$HERE/fix.patch"
(cd boot && php "$AMZ_PLUGIN_ROOT/vendor/phpunit/phpunit/phpunit" -c phpunit.xml tests)
git -C plugin checkout -q -- Model/CheckoutSessionManagement.php
