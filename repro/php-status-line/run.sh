#!/bin/bash
# Shows which HTTP status a client receives when a handler calls http_response_code() after the status line was already set
# with header('HTTP/1.1 200 OK') — what WordPress status_header(200) does, and what WooCommerce does before every
# ?wc-api= handler. Runs the same script under php-fpm (FastCGI, via fcgi_get.py) and under the PHP built-in server.
# Needs php-fpm and php of the same version on PATH (or PHP_FPM=/path/to/php-fpm), python3, curl.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FPM="${PHP_FPM:-php-fpm}"
"$FPM" -n -y "$HERE/fpm.conf" & F=$!
php -d display_errors=0 -S 127.0.0.1:8892 -t "$HERE" >/dev/null 2>&1 & S=$!
trap 'kill $F $S 2>/dev/null' EXIT
sleep 1
echo "php-fpm:        $(python3 "$HERE/fcgi_get.py" 127.0.0.1 9123 "$HERE/status_after_status_header.php" | tr -s "\r\n" " ")"
echo "built-in server: HTTP $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8892/status_after_status_header.php) (handler set 503)"
