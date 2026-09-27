#!/usr/bin/env bash
# Runs Odoo's own Mollie webhook against a fake Mollie API, inside Odoo's test framework, and prints
# what the webhook answered.
#   ./run.sh                    Odoo 19.0
#   ODOO_BRANCH=18.0 ./run.sh   Odoo 18.0
# Needs git, Python 3.10-3.12 and a PostgreSQL server where the current user may create databases
# (connection from the usual PGHOST / PGPORT / PGUSER / PGPASSWORD variables, as for psql).
set -euo pipefail
cd "$(dirname "$0")"
BRANCH="${ODOO_BRANCH:-19.0}"
SRC="odoo-$BRANCH"
VENV="venv-$BRANCH"

if [[ ! -f "$SRC/odoo-bin" ]]; then
    git clone -q --depth 1 --filter=blob:none --branch "$BRANCH" https://github.com/odoo/odoo "$SRC"
fi
if [[ ! -x "$VENV/bin/python" ]]; then
    python3 -m venv "$VENV"
    # psycopg2-binary instead of psycopg2 (no compiler needed); python-ldap is not used here.
    grep -v -i "python-ldap\|pypiwin32" "$SRC/requirements.txt" | sed 's/^psycopg2==/psycopg2-binary==/' >"$VENV/requirements.txt"
    "$VENV/bin/pip" install -q -r "$VENV/requirements.txt"
fi

DB="repro_mollie_${BRANCH//[.-]/_}"
dropdb --if-exists "$DB" 2>/dev/null || true
"$VENV/bin/python" "$SRC/odoo-bin" -d "$DB" \
    ${PGHOST:+--db_host "$PGHOST"} ${PGPORT:+--db_port "$PGPORT"} \
    ${PGUSER:+--db_user "$PGUSER"} ${PGPASSWORD:+--db_password "$PGPASSWORD"} \
    --addons-path="$SRC/addons,$SRC/odoo/addons,$PWD" \
    -i repro_mollie_webhook --test-tags /repro_mollie_webhook \
    --stop-after-init --log-level=test --http-port="${HTTP_PORT:-8069}" --without-demo=all \
    >"odoo-$BRANCH.log" 2>&1 || true
dropdb --if-exists "$DB" 2>/dev/null || true

echo "Odoo $BRANCH ($(git -C "$SRC" rev-parse --short HEAD))"
# The tests log their results as a header line followed by table rows or one sentence.
awk '/REPRO (TABLE|RETRY|FIX)$/ {print ""; sub(/.*REPRO /, "== "); print; grab=1; next}
     grab && /^(\||after )/ {print; next}
     {grab=0}' "odoo-$BRANCH.log"
echo
grep -o "odoo.tests.result: .*" "odoo-$BRANCH.log" || { echo "no test result; see odoo-$BRANCH.log"; exit 1; }
