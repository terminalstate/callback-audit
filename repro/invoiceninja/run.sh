#!/usr/bin/env bash
#
# Runs the reproduction tests in tests/ (every *StandTest.php next to this script) inside invoiceninja's own
# PHPUnit suite.
#
#   bash run.sh [WORK_DIR]
#
# From an empty directory it clones invoiceninja at the pinned commit, installs its dependencies, configures .env
# against a MySQL/MariaDB database you provide, migrates and seeds, copies the test files in, then runs them
# twice: a default run with the `if-fixed` group excluded (expected green) and the `if-fixed` group of each file
# (expected red while the bug is present). It prints a result table and exits 0 when every file reproduces.
#
# Needs git, PHP 8.2+ with the extensions in the project's composer.json, and composer (or python3 + curl, see the
# fallback below). The database must exist, be empty, and be reachable with the DB_* variables below.
#
# -------------------------------------------------------------------- settings
# Pinned commit (v5-develop, 2026-10-10). Override to run at another commit, e.g. a branch with a fix:
#   INVOICENINJA_COMMIT=<sha> bash run.sh
: "${INVOICENINJA_COMMIT:=493c3884e4214028bc5970cb41bafbd9c4d96401}"
: "${INVOICENINJA_REPO:=https://github.com/invoiceninja/invoiceninja.git}"

# Database (must already exist and be reachable; it is NOT created here).
: "${DB_HOST:=127.0.0.1}"
: "${DB_PORT:=3306}"
: "${DB_USERNAME:=root}"
: "${DB_PASSWORD:=ninja}"
: "${DB_DATABASE:=ninja_stand}"

# Composer version for the fallback (only used when Packagist is unreachable and no composer.phar is next to
# this script).
: "${COMPOSER_VERSION:=2.8.12}"

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 2; }

# ---------------------------------------------------------------- 1. work dir
WORK_DIR="${1:-}"
if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d)"
    info "No WORK_DIR given; using temporary directory $WORK_DIR"
else
    mkdir -p "$WORK_DIR"
    if [ -n "$(ls -A "$WORK_DIR" 2>/dev/null)" ]; then
        die "WORK_DIR '$WORK_DIR' is not empty. Pass a new or empty directory."
    fi
fi
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
CLONE="$WORK_DIR/invoiceninja"
LOGS="$WORK_DIR/logs"; mkdir -p "$LOGS"
RESULT="$WORK_DIR/result.txt"
: > "$RESULT"

for bin in git php; do command -v "$bin" >/dev/null 2>&1 || die "'$bin' is required but not on PATH."; done

# ---------------------------------------------------------------- 2. clone
log "Cloning invoiceninja @ ${INVOICENINJA_COMMIT:0:12} into $CLONE"
mkdir -p "$CLONE"
(
    cd "$CLONE"
    git init -q
    git remote add origin "$INVOICENINJA_REPO" 2>/dev/null || true
    git fetch -q --depth 1 origin "$INVOICENINJA_COMMIT"
    git checkout -q FETCH_HEAD
) || die "git clone/fetch failed. github.com must be reachable over https."
HEAD_SHA="$(git -C "$CLONE" rev-parse HEAD)"
[ "$HEAD_SHA" = "$INVOICENINJA_COMMIT" ] || die "HEAD $HEAD_SHA != expected $INVOICENINJA_COMMIT"
info "HEAD = $HEAD_SHA"

# ---------------------------------------------------------------- 3. deps
packagist_reachable() {
    command -v curl >/dev/null 2>&1 || return 1
    local code
    code="$(curl -sS -m 12 -o /dev/null -w '%{http_code}' https://repo.packagist.org/packages.json 2>/dev/null || echo 000)"
    [ "$code" = "200" ]
}

log "Installing dependencies"
if [ "${USE_GITHUB_FALLBACK:-0}" != "1" ] && command -v composer >/dev/null 2>&1 && packagist_reachable; then
    info "Packagist reachable -> composer install"
    ( cd "$CLONE" && composer install --no-interaction --no-progress --no-scripts ) >"$LOGS/composer-install.log" 2>&1 \
        || die "composer install failed; see $LOGS/composer-install.log"
else
    # Fallback for machines that can reach github.com but not Packagist: fetch every locked package from its
    # GitHub source at the locked commit, then let Composer write the autoloader and installed.php.
    info "Packagist not reachable (or USE_GITHUB_FALLBACK=1) -> GitHub fallback"
    command -v python3 >/dev/null 2>&1 || die "python3 is required for the GitHub fallback."
    [ -f "$SCRIPT_DIR/fetch_vendor.py" ] || die "fetch_vendor.py not found next to run.sh"
    [ -f "$SCRIPT_DIR/write_installed.php" ] || die "write_installed.php not found next to run.sh"

    # composer.phar: next to run.sh, or downloaded from the GitHub release.
    PHAR="$SCRIPT_DIR/composer.phar"
    if [ ! -f "$PHAR" ]; then
        command -v curl >/dev/null 2>&1 || die "curl is required to download composer.phar"
        info "Downloading composer.phar $COMPOSER_VERSION from the GitHub release"
        curl -sSL -o "$PHAR" \
            "https://github.com/composer/composer/releases/download/${COMPOSER_VERSION}/composer.phar" \
            || die "could not download composer.phar"
    fi

    info "fetch_vendor.py: shallow-fetching the locked packages from GitHub (this can take several minutes)"
    python3 "$SCRIPT_DIR/fetch_vendor.py" "$CLONE" >"$LOGS/fetch_vendor.log" 2>&1 \
        || die "fetch_vendor.py failed; see $LOGS/fetch_vendor.log"
    tail -n 3 "$LOGS/fetch_vendor.log" | sed 's/^/    /'

    info "composer.phar dump-autoload --no-scripts"
    php "$PHAR" dump-autoload -d "$CLONE" --no-scripts --optimize >"$LOGS/dump-autoload.log" 2>&1 \
        || die "dump-autoload failed; see $LOGS/dump-autoload.log"

    info "write_installed.php (installed.php / InstalledVersions.php)"
    ( cd "$CLONE" && php "$SCRIPT_DIR/write_installed.php" ) >"$LOGS/write-installed.log" 2>&1 \
        || die "write_installed.php failed; see $LOGS/write-installed.log"
fi
[ -f "$CLONE/vendor/autoload.php" ] || die "vendor/autoload.php missing after install"

# ---------------------------------------------------------------- 4. .env
log "Configuring .env"
[ -f "$CLONE/.env.ci" ] || die ".env.ci missing in the checkout"
cp "$CLONE/.env.ci" "$CLONE/.env"

set_env() { # set_env KEY VALUE  (replace existing line or append)
    local key="$1" val="$2" f="$CLONE/.env"
    if grep -qE "^${key}=" "$f"; then
        # Use a temp file to avoid sed delimiter issues with the value.
        awk -v k="$key" -v v="$val" 'BEGIN{FS=OFS="="} $1==k{print k"="v; next} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    else
        printf '%s=%s\n' "$key" "$val" >> "$f"
    fi
}
# Point both the plain `mysql` connection and db-ninja-01/02/03 at the same DB.
for pair in \
    "DB_CONNECTION=mysql" \
    "DB_HOST=$DB_HOST"    "DB_PORT=$DB_PORT"   "DB_DATABASE=$DB_DATABASE"   "DB_USERNAME=$DB_USERNAME"   "DB_PASSWORD=$DB_PASSWORD" \
    "DB_HOST1=$DB_HOST"   "DB_PORT1=$DB_PORT"  "DB_DATABASE1=$DB_DATABASE"  "DB_USERNAME1=$DB_USERNAME"  "DB_PASSWORD1=$DB_PASSWORD" \
    "MULTI_DB_ENABLED=false" \
    "CACHE_DRIVER=file" "QUEUE_CONNECTION=sync" "SESSION_DRIVER=array" "MAIL_MAILER=array" "SCOUT_DRIVER=null" ; do
    set_env "${pair%%=*}" "${pair#*=}"
done
info "DB target: $DB_USERNAME@$DB_HOST:$DB_PORT/$DB_DATABASE"

export DB_HOST DB_PORT DB_USERNAME DB_PASSWORD DB_DATABASE
export DB_HOST1="$DB_HOST" DB_PORT1="$DB_PORT" DB_USERNAME1="$DB_USERNAME" DB_PASSWORD1="$DB_PASSWORD" DB_DATABASE1="$DB_DATABASE"

# ---------------------------------------------------------------- 5. guard DB
log "Checking the target database is empty"
TABLE_COUNT="$(php -r '
    $h=getenv("DB_HOST"); $p=getenv("DB_PORT"); $u=getenv("DB_USERNAME");
    $w=getenv("DB_PASSWORD"); $d=getenv("DB_DATABASE");
    try {
        $pdo=new PDO("mysql:host=$h;port=$p;dbname=$d", $u, $w);
        $n=$pdo->query("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=".$pdo->quote($d))->fetchColumn();
        echo (int)$n;
    } catch (Throwable $e) { fwrite(STDERR, $e->getMessage()); echo "ERR"; }
' 2>"$LOGS/db-check.log")"
if [ "$TABLE_COUNT" = "ERR" ]; then
    die "cannot connect to $DB_DATABASE on $DB_HOST:$DB_PORT (see $LOGS/db-check.log). Create it first, e.g. mysql -u$DB_USERNAME -p -e 'CREATE DATABASE $DB_DATABASE;'"
fi
if [ "$TABLE_COUNT" != "0" ] && [ "${ALLOW_EXISTING_DB:-0}" != "1" ]; then
    die "database $DB_DATABASE already has $TABLE_COUNT tables. Refusing to migrate over it. Use a fresh DB, or set ALLOW_EXISTING_DB=1 to override."
fi
info "tables present: $TABLE_COUNT"

# ---------------------------------------------------------------- 6. app setup
log "key:generate / package:discover / migrate / seed"
( cd "$CLONE" && php artisan key:generate --force )        >"$LOGS/key-generate.log" 2>&1 || die "key:generate failed; see $LOGS/key-generate.log"
( cd "$CLONE" && php artisan package:discover --ansi )     >"$LOGS/package-discover.log" 2>&1 || die "package:discover failed; see $LOGS/package-discover.log"
( cd "$CLONE" && php artisan migrate --force )             >"$LOGS/migrate.log" 2>&1 || die "migrate failed; see $LOGS/migrate.log"
( cd "$CLONE" && php artisan db:seed --force )             >"$LOGS/seed.log" 2>&1 || die "db:seed failed; see $LOGS/seed.log"
info "migrated and seeded"

# ---------------------------------------------------------------- 7. copy tests
log "Copying the test files into the checkout"
STAND_TESTS=()
while IFS= read -r t; do STAND_TESTS+=("$t"); done < <(cd "$SCRIPT_DIR" && find tests -name '*StandTest.php' | sort)
[ "${#STAND_TESTS[@]}" -gt 0 ] || die "no tests/**/*StandTest.php next to run.sh"
for t in "${STAND_TESTS[@]}"; do
    [ -f "$SCRIPT_DIR/$t" ] || die "missing test $SCRIPT_DIR/$t"
    if [ -e "$CLONE/$t" ]; then die "refusing to overwrite existing $t in the checkout"; fi
    mkdir -p "$CLONE/$(dirname "$t")"
    cp "$SCRIPT_DIR/$t" "$CLONE/$t"
    info "$t"
done

PHPUNIT="$CLONE/vendor/phpunit/phpunit/phpunit"
[ -f "$PHPUNIT" ] || die "phpunit not found at $PHPUNIT"

# ---------------------------------------------------------------- 8. default run
log "Default run (current behaviour + controls, if-fixed excluded) -- expected GREEN"
( cd "$CLONE" && php "$PHPUNIT" --no-coverage --exclude-group if-fixed "${STAND_TESTS[@]}" ) \
    2>&1 | tee "$LOGS/default-run.log"
DEFAULT_EXIT=${PIPESTATUS[0]}

# ---------------------------------------------------------------- 9. if-fixed run (per file)
# phpunit.xml sets stopOnFailure, so each file's if-fixed group runs on its own.
declare -a IFF_NAME IFF_FILE IFF_EXIT
for t in "${STAND_TESTS[@]}"; do IFF_FILE+=("$t"); n="${t##*/}"; IFF_NAME+=("${n%.php}"); done
log "If-fixed run (one per file) -- expected RED while the bug is present"
for i in "${!IFF_FILE[@]}"; do
    f="${IFF_FILE[$i]}"
    info "${IFF_NAME[$i]}: ${f##*/}"
    ( cd "$CLONE" && php "$PHPUNIT" --no-coverage --group if-fixed "$f" ) \
        >"$LOGS/iffixed-${IFF_NAME[$i]}.log" 2>&1
    IFF_EXIT[$i]=$?
    tail -n 6 "$LOGS/iffixed-${IFF_NAME[$i]}.log" | sed 's/^/        /'
done

# ---------------------------------------------------------------- 10. report
# The verdict is computed here, outside the pipeline below (a `{ ...; } | tee` block runs in a subshell).
default_ok="FAIL"; [ "$DEFAULT_EXIT" = "0" ] && default_ok="GREEN"
allred=1
for i in "${!IFF_FILE[@]}"; do [ "${IFF_EXIT[$i]}" = "0" ] && allred=0; done
reproduced=0
[ "$DEFAULT_EXIT" = "0" ] && [ "$allred" = "1" ] && reproduced=1
{
    echo "invoiceninja reproduction tests"
    echo "commit:   $HEAD_SHA"
    echo "database: $DB_USERNAME@$DB_HOST:$DB_PORT/$DB_DATABASE"
    echo "date:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    printf '%-44s | %-26s | %-4s | %s\n' "file" "run" "exit" "expected -> got"
    printf '%s\n' "--------------------------------------------------------------------------------------------------------"
    printf '%-44s | %-26s | %-4s | %s\n' "all" "default (exclude if-fixed)" "$DEFAULT_EXIT" "GREEN -> $default_ok"
    for i in "${!IFF_FILE[@]}"; do
        verdict="RED (reproduced)"; [ "${IFF_EXIT[$i]}" = "0" ] && verdict="GREEN (not reproduced: fixed?)"
        printf '%-44s | %-26s | %-4s | %s\n' "${IFF_NAME[$i]}" "if-fixed group" "${IFF_EXIT[$i]}" "RED -> $verdict"
    done
    echo
    if [ "$reproduced" = "1" ]; then
        echo "VERDICT: reproduced (default run green, every if-fixed run red)."
    else
        echo "VERDICT: NOT fully reproduced -- see logs in $LOGS/"
    fi
} | tee -a "$RESULT"

log "Logs: $LOGS    Result: $RESULT"
[ "$reproduced" = "1" ] && exit 0 || exit 1
