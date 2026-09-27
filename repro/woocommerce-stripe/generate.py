#!/usr/bin/env python3
"""Build a realistic WooCommerce+Stripe dataset by driving every webhook through
the REAL WC_Stripe_Webhook_Handler v11.0.0 running under php -S.

Scenario: a small shop, 14 days. On days 7-8 the store rotated its Stripe webhook
signing secret in the dashboard but the plugin still holds the previous one, so every
delivery in that window fails signature validation -> the plugin answers 204 -> Stripe
marks it delivered and never retries -> those orders stay 'pending' while Stripe shows
them 'succeeded'. Outside the window the secret matches -> 200 -> orders finalize.
"""

import csv
import hashlib
import hmac
import http.client
import json
import os
import random
import signal
import subprocess
import time
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "dataset")
WORK = os.path.join(HERE, "work")
os.makedirs(OUT, exist_ok=True)
os.makedirs(WORK, exist_ok=True)
STORE_SECRET = "whsec_store_configured_secret"  # what the plugin holds
ROTATED_SECRET = "whsec_new_after_rotation_2026"  # what Stripe signs with during the window
PORT = 8099
random.seed(7)

# --- start the real handler under php -S ---
live_log = os.path.join(WORK, "live_app.log")
env = dict(
    os.environ,
    STORE_WEBHOOK_SECRET=STORE_SECRET,
    APP_LOG=live_log,
    PLUGIN_DIR=os.environ.get("PLUGIN_DIR", os.path.join(HERE, "woocommerce-gateway-stripe", "includes")),
)
open(live_log, "w").close()
srv = subprocess.Popen(
    ["php", "-S", f"127.0.0.1:{PORT}", os.path.join(HERE, "router.php")],
    env=env,
    stdout=open(os.path.join(WORK, "server.log"), "w"),
    stderr=subprocess.STDOUT,
)
time.sleep(1.5)


def post_webhook(body: str, sign_secret: str) -> int:
    t = int(time.time())  # signature timestamp must be within 5 min of server clock
    sig = f"t={t},v1=" + hmac.new(sign_secret.encode(), f"{t}.{body}".encode(), hashlib.sha256).hexdigest()
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
    c.request("POST", "/?wc-api=wc_stripe", body, {"Content-Type": "application/json", "Stripe-Signature": sig})
    r = c.getresponse()
    r.read()
    c.close()
    return r.status


# --- scenario timeline ---
START = datetime(2026, 9, 11, 9, 0, tzinfo=timezone.utc)
DAYS = 14
NOW = START + timedelta(days=DAYS)  # reference "now"
ROT_START, ROT_END = 7, 9  # rotation window [day7, day9)

payments, events, inbound, applog = [], [], [], []
n = 0
codes = {200: 0, 204: 0, "other": 0}
stuck_ids = []

for day in range(DAYS):
    day0 = START + timedelta(days=day)
    orders_today = random.randint(5, 8)
    in_window = ROT_START <= day < ROT_END
    for _ in range(orders_today):
        n += 1
        pid = f"pay_{n:04d}"
        eid = f"evt_{n:04d}"
        created = day0 + timedelta(hours=random.uniform(0, 10), minutes=random.uniform(0, 59))
        arrive = created + timedelta(seconds=random.uniform(3, 12))  # webhook lands shortly after
        body = json.dumps(
            {
                "id": eid,
                "type": "payment_intent.succeeded",
                "created": int(created.timestamp()),
                "data": {"object": {"id": f"pi_{n:04d}", "status": "succeeded"}},
            }
        )
        secret = ROTATED_SECRET if in_window else STORE_SECRET
        code = post_webhook(body, secret)
        codes[code if code in (200, 204) else "other"] += 1

        # provider (Stripe) view: the payment succeeded regardless of our local outcome
        events.append([pid, arrive.isoformat(), "succeeded", eid, "true"])
        inbound.append([arrive.isoformat(), code, "/?wc-api=wc_stripe"])

        if code == 200:
            settled = arrive + timedelta(seconds=random.uniform(0.2, 2))
            payments.append([pid, created.isoformat(), settled.isoformat(), "succeeded", "stripe"])
            applog.append((arrive, f"DEBUG Webhook received (payment_intent.succeeded) [{pid}]"))
        else:  # 204: validation failed, order never left pending
            stuck_ids.append(pid)
            payments.append([pid, created.isoformat(), "", "pending", "stripe"])
            applog.append((arrive, f"ERROR Webhook validation failed (signature_mismatch) [{pid}]"))

srv.send_signal(signal.SIGTERM)
time.sleep(0.3)

# --- write dataset ---
with open(f"{OUT}/payments.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["id", "created_at", "updated_at", "status", "provider"])
    w.writerows(payments)
with open(f"{OUT}/events.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["payment_id", "at", "status", "event_id", "terminal"])
    w.writerows(events)
with open(f"{OUT}/inbound.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["at", "status_code", "path"])
    w.writerows(inbound)
with open(f"{OUT}/app.log", "w") as f:
    for ts, line in sorted(applog):
        f.write(f"{ts.strftime('%Y-%m-%dT%H:%M:%SZ')} {line}\n")
with open(f"{OUT}/NOW.txt", "w") as f:
    f.write(NOW.isoformat())

print(f"orders={n}  http_codes={codes}  stuck(204)={len(stuck_ids)}")
print(f"window days {ROT_START}-{ROT_END - 1}; oldest stuck created ~{DAYS - ROT_END + 1}+ days before NOW={NOW.date()}")
print("first stuck ids:", ", ".join(stuck_ids[:8]))
