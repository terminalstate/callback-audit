#!/bin/bash
# Shows what the IPN postback in akaunting/module-paypal-standard sends to PayPal and what PayPal answers.
# Needs PHP 8 and Composer. Run: bash run.sh [WORK_DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$(mktemp -d)}"; mkdir -p "$WORK"; cd "$WORK"
[ -f vendor/autoload.php ] || composer require --quiet --no-interaction guzzlehttp/guzzle:^7.8
export IPN_FILE="$HERE/ipn.txt" LOG_FILE="$WORK/postbacks.log"; : > "$LOG_FILE"
php -d display_errors=0 -S 127.0.0.1:8889 "$HERE/fake-paypal.php" >/dev/null 2>&1 & S=$!
trap 'kill $S 2>/dev/null' EXIT; sleep 1
MODULE=$(php "$HERE/postback.php" "$WORK/vendor" http://127.0.0.1:8889/ "$IPN_FILE")
FIXED=$(php "$HERE/postback.php" "$WORK/vendor" http://127.0.0.1:8889/ "$IPN_FILE" fixed)
echo "module's postback  -> PayPal answers: $MODULE"
echo "raw-body postback  -> PayPal answers: $FIXED"
cut -c1-120 "$LOG_FILE"
[ "$MODULE" = "INVALID" ] && [ "$FIXED" = "VERIFIED" ] && echo "REPRODUCED: the module posts an empty body, so every IPN is INVALID and no payment is recorded."
