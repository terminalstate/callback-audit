#!/usr/bin/env bash
# Runs the reproduction tests inside django-payments' own test suite against a fake provider HTTP layer.
#   ./run.sh                 django-payments at the pinned commit, latest stripe-python
#   STRIPE_SPEC="stripe<15" ./run.sh   the same with the last stripe-python that still worked
# Needs git and Python 3.10+.
set -euo pipefail
cd "$(dirname "$0")"
COMMIT="${DJANGO_PAYMENTS_COMMIT:-8edfb1fc47f8011a1ec401b878971fb47d104165}"
SRC="src-django-payments"
VENV="venv-django-payments"

if [[ ! -f "$SRC/pyproject.toml" ]]; then
    git clone -q https://github.com/jazzband/django-payments.git "$SRC"
    git -C "$SRC" checkout -q "$COMMIT"
fi
if [[ ! -x "$VENV/bin/python" ]]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q -e "$SRC[stripe,braintree,cybersource,sagepay,mercadopago,sofort]" pytest pytest-django pytest-cov
fi
if [[ -n "${STRIPE_SPEC:-}" ]]; then
    "$VENV/bin/pip" install -q "$STRIPE_SPEC"
fi

cp test_repro_terminal_state.py "$SRC/payments/"
echo "django-payments $(git -C "$SRC" rev-parse --short HEAD), $("$VENV/bin/python" -c 'import django, stripe; print(f"Django {django.get_version()}, stripe {stripe.VERSION}")')"
(cd "$SRC" && "../$VENV/bin/python" -m pytest -p no:cacheprovider --no-cov payments/test_repro_terminal_state.py -v -rsx --color=no 2>&1 | grep -E "::.*(PASSED|FAILED|SKIPPED|XFAIL|XPASS|ERROR)|passed|failed|^SKIPPED|^XFAIL") | tee "result-$(git -C "$SRC" rev-parse --short HEAD).log"
