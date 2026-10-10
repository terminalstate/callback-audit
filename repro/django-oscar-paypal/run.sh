#!/usr/bin/env bash
# Runs the reproduction tests inside django-oscar-paypal's own test suite (django-oscar 4.0); only the HTTP calls to PayPal are faked.
#   ./run.sh                 django-oscar-paypal at the pinned commit
# Needs git and Python 3.10+.
set -euo pipefail
cd "$(dirname "$0")"
COMMIT="${OSCAR_PAYPAL_COMMIT:-d2c017162ed7d29d69939fb2b4ad76fb0e424f96}"
SRC="src-django-oscar-paypal"
VENV="venv-django-oscar-paypal"

if [[ ! -f "$SRC/setup.py" ]]; then
    git clone -q https://github.com/django-oscar/django-oscar-paypal.git "$SRC"
    git -C "$SRC" checkout -q "$COMMIT"
fi
if [[ ! -x "$VENV/bin/python" ]]; then
    python3 -m venv "$VENV"
    # django-oscar 4.0 needs django-treebeard < 5 (the basket page fails to render with 5.x)
    "$VENV/bin/pip" install -q -e "$SRC[oscar]" django-webtest pytest-django sorl-thumbnail "django<5.3" "django-treebeard<5"
fi

cp terminal_state_tests.py "$SRC/tests/unit/"
echo "django-oscar-paypal $(git -C "$SRC" rev-parse --short HEAD), $("$VENV/bin/python" -c 'import django, oscar; print(f"Django {django.get_version()}, django-oscar {oscar.get_version()}")')"
(cd "$SRC" && "../$VENV/bin/python" -m pytest -p no:cacheprovider tests/unit/terminal_state_tests.py -v -rs --color=no 2>&1 | grep -E "::.*(PASSED|FAILED|SKIPPED|ERROR)|passed|failed|^SKIPPED") | tee "result-$(git -C "$SRC" rev-parse --short HEAD).log"
