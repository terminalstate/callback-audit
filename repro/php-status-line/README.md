# Harness: `http_response_code()` after a status line was set with `header()`

WordPress's `status_header( 200 )` is `header( 'HTTP/1.1 200 OK', true, 200 )`, and WooCommerce calls it before every
`?wc-api=` handler. A handler that then reports a failure with `http_response_code()` does not change what is sent under
php-fpm (FastCGI) or the PHP built-in server: the status line set first wins, and the payment provider gets 200. Apache
mod_php sends the code set last. Known in PHP as [php/php-src#18582](https://github.com/php/php-src/issues/18582).

```
PHP_FPM=/path/to/php-fpm bash run.sh          # php-fpm and php of the same version, python3, curl
```

`status_after_status_header.php` does what such a request does: `header( 'HTTP/1.1 200 OK', true, 200 )`, then
`http_response_code( 503 )`. `run.sh` sends it to php-fpm through `fcgi_get.py` (a minimal FastCGI client that prints the raw
CGI response, so no web server is involved) and to the built-in server through curl.

Run on 2026-10-20 (PHP 8.4.23):

```
php-fpm:        Status: 200 OK X-Powered-By: PHP/8.4.23 Content-type: text/html; charset=UTF-8 handler reported 503
built-in server: HTTP 200 (handler set 503)
```

`status_header( $code )` instead of `http_response_code( $code )` sets the status reliably in both places.
