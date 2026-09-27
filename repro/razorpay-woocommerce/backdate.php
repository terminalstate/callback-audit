<?php
/**
 * The plugin's cron only picks up queue rows whose rzp_webhook_notified_at is more than 300 s old
 * (woo-razorpay.php L3393). Instead of waiting five minutes, move that timestamp back 301 s.
 * (run.sh --real-clock waits the five minutes instead.)
 */

declare(strict_types=1);

$state = getenv('STATE_DIR') ?: __DIR__ . '/state';
$db = new PDO("sqlite:$state/wp.sqlite");
$n = $db->exec('UPDATE wp_rzp_webhook_requests SET rzp_webhook_notified_at = rzp_webhook_notified_at - 301 WHERE rzp_webhook_notified_at IS NOT NULL');
echo "backdated $n row(s)\n";
