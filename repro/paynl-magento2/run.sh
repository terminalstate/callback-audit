#!/bin/bash
# Pay. for Magento 2: an unsigned exchange call is answered "TRUE|" when the status request to the Pay. API fails, so Pay. does
# not retry it and the paid order stays pending_payment. A unit test of the real Exchange controller and the real Pay. PHP SDK
# 1.2.3 — no Magento install: module dependencies from the Mage-OS mirror + a minimal unit-test bootstrap. The only thing
# arranged is the network: HTTPS_PROXY points to a closed local port, so the SDK's request to rest.pay.nl fails to connect.
# Needs PHP 8.2+, Composer, git (~320 MB). Run: bash run.sh [WORK_DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"
COMMIT="${PAYNL_COMMIT:-e897a311d2eafd21c87b712eb7a1555ac4cd6ae3}"   # master on 2026-10-20 (4.0.17)
mkdir -p "$WORK" && WORK="$(cd "$WORK" && pwd)" && cd "$WORK"
if [ ! -d plugin/.git ]; then
  git init -q plugin; git -C plugin remote add origin https://github.com/paynl/magento2-plugin
  git -C plugin fetch -q --depth 1 origin "$COMMIT"; git -C plugin checkout -q FETCH_HEAD
fi
if [ ! -d plugin/vendor ]; then
  (cd plugin && python3 - <<'PY'
import json; d=json.load(open('composer.json'))
d['repositories']=[{'type':'composer','url':'https://mirror.mage-os.org/'}]
d['require-dev']={'phpunit/phpunit':'^10.5'}
d.setdefault('config',{})['allow-plugins']={'magento/*':False,'laminas/*':False}
json.dump(d,open('composer.json','w'),indent=4)
PY
  composer update -q --no-interaction --no-scripts --no-plugins --prefer-dist)
fi
git -C plugin checkout -q -- Controller/Checkout/Exchange.php
mkdir -p boot/tmp && cp -r "$HERE/bootstrap.php" "$HERE/phpunit.xml" "$HERE/tests" boot/
export PAYNL_ROOT="$WORK/plugin"
echo "== exchange controller at $(git -C plugin log -1 --format='%h %cs'), SDK $(grep -A1 '"name": "paynl/php-sdk"' plugin/composer.lock | grep -o '[0-9.]*' | head -1)"
(cd boot && php "$PAYNL_ROOT/vendor/bin/phpunit" -c phpunit.xml) || true
echo "== with fix.patch"
git -C plugin apply "$HERE/fix.patch"
(cd boot && php "$PAYNL_ROOT/vendor/bin/phpunit" -c phpunit.xml)
git -C plugin checkout -q -- Controller/Checkout/Exchange.php
