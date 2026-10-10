#!/usr/bin/env bash
# Runs the reproduction tests with django-paypal's own test runner (runtests.py); only the IPN postback to PayPal is faked.
#   ./run.sh                 django-paypal at the pinned commit
# Needs git and Python 3.10+.
set -euo pipefail
cd "$(dirname "$0")"
COMMIT="${DJANGO_PAYPAL_COMMIT:-5d09973ce99826c538f19b358eaedd337df00e80}"
SRC="src-django-paypal"
VENV="venv-django-paypal"

if [[ ! -f "$SRC/runtests.py" ]]; then
    git clone -q https://github.com/spookylukey/django-paypal.git "$SRC"
    git -C "$SRC" checkout -q "$COMMIT"
fi
if [[ ! -x "$VENV/bin/python" ]]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q -e "$SRC" "requests>2.18" vcrpy
fi

cp test_repro_terminal_state.py "$SRC/paypal/standard/ipn/tests/"
echo "django-paypal $(git -C "$SRC" rev-parse --short HEAD), $("$VENV/bin/python" -c 'import django; print("Django", django.get_version())')"
(cd "$SRC" && "../$VENV/bin/python" runtests.py --verbosity=2 paypal.standard.ipn.tests.test_repro_terminal_state 2>&1 | grep -E "^test_|\.\.\. (ok|skipped|FAIL|ERROR)|^Ran |^OK|^FAILED") | tee "result-$(git -C "$SRC" rev-parse --short HEAD).log"
