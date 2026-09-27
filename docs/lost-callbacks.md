# Seven places a webhook dies between the provider and your database

A payment that has been "stuck in pending" for hours is almost never stuck. At the provider, the money moved or didn't within seconds. What is stuck is your *knowledge* of it: the callback carrying the terminal status was never applied. "Never applied" is not the same as "never sent". Between the provider and the row in your database there are seven stations, and at each one the message dies in its own way, with its own symptom and its own check.

This is the map I walk when someone shows me such a payment. Everything below is checked by reading logs and the database. None of it needs write access, and none of it touches production.

Some of these failures are also reproduced in public code, in four widely-used payment integrations, each with a harness in this repository. They are linked at the stations where they belong.

## Where I start

Not with the code, and not with hypotheses. Two moves, both cheap, both learned the expensive way.

First, confirm that the payment exists in *this* environment. I have dug through an object store with signed URLs looking for a record that lived on staging.

Second, take one concrete id and pull everything about it from centralised logs for the whole period since creation. Not the last hour, and not `kubectl logs`: pods restart, buffers reset, old lines are physically gone. Nine times out of ten the answer is already in the logs, and I have it before I would have finished reading the code.

I have sat on both sides of the pipe: receiving provider webhooks, and sending callbacks to merchants through a dedicated delivery service with retries and sequence numbers. The stations are the same on both sides; the symptoms mirror each other. Someone who has only ever received webhooks underestimates how much breaks before the request reaches the network.

Each station below is symptom → causes → how to check → what I have seen. Cases are anonymised down to the class of problem.

## 1. The provider never sent it, or sent it somewhere else

**Symptom.** The provider's dashboard shows the payment succeeded long ago; you show pending. Your logs contain no inbound request at all, neither accepted nor rejected.

**Causes.** The callback URL is configured on the provider's side, per merchant or terminal, and points at an old environment, staging, a previous domain, especially after a migration. The provider sends callbacks for some events but not others: success yes, "expired" or "cancelled by the bank" or "partial refund" no, or only with a checkbox enabled somewhere. The transition happened before your record existed: the payment was created through another channel, or the callback outran the response to your create call, and the provider faithfully delivered a callback for an object you did not have yet. Or the sender crashed before reaching the network and wrote a response code into its own database that never came from anywhere.

**How to check.** The provider's delivery log, which most have and some produce only on request. Compare *counts* of sent and received per day, not individual events. If the counters diverge, it is station 1 or 2. The decisive check is the *absence* of the request in the receiver's access log over the whole period, not the last hour.

**What I have seen (sending side).** Callbacks to several merchants "hung". Every attempt in the delivery service's database showed a 504, and everyone was hunting a network timeout to the receiver. The receiver's access log for three days had zero requests for those ids. Not one. The request never left: for one merchant, the signing key was missing from the environment, the HTTP client failed while building headers, *before any I/O*, and a catch-all exception handler wrote a hard-coded "504" to the database. Lesson: a response code in your own database is not evidence of a network event. You distinguish "receiver timed out" from "no key" only by the exception text in the sender's log, or by the emptiness of the receiver's.

Same incident, second cause. Keys were read from environment variables by merchant code, while the admin form displayed database columns the code never read. The merchant was "configured" on screen and unconfigured in reality. Then the secret was added, into a *neighbouring* store with an almost identical name. The check that closed it: list the keys in both stores, rather than "is the variable present in the pod".

## 2. Sent, but it never arrived: the network

**Symptom.** The provider's delivery log shows errors or timeouts. On your side, either nothing, or 5xx/504 from the load balancer rather than the application.

**Causes.** A certificate chain was renewed and the provider's client does not trust the new root, or pins the old one. An IP allowlist on your WAF or ingress, and the provider rotated its egress addresses, announced by an email read in the wrong place. An ingress timeout shorter than the handler's runtime: the balancer returns 504, the provider marks the delivery failed and schedules a retry, while your handler finishes and applies the status anyway. That is already the duplicates story, but the symptom starts here. A body-size limit; an http→https redirect that the provider's client does not follow, because many clients will not replay a POST across a redirect. And the one nobody has a rule for: a TCP-level cutoff at the provider's anti-DDoS edge, invisible to every WAF rule on both sides.

**How to check.** The balancer or ingress access log, filtered by the provider's user agent or subnet, broken down by response code per day. A gap in the timeline or a spike of 4xx/5xx on one day, and the date usually matches someone's release or a rotation. Probe **from a production pod**, not a laptop: to the other side, your egress IP is the pod's, and a laptop probe proves nothing.

**What I have seen (sending to a provider).** Intermittent `Connection refused` to a provider's API "after a few requests a day". The provider sent an article about SSL verification, which was beside the point: a refusal at TCP connect happens before TLS and before HTTP; a certificate problem gives a different class of error. Their "we don't see your requests, nothing in our blocking rules" was expected, since the request never reached HTTP and an L3/L4 refusal does not appear in WAF rules. A probe from a production pod against every anycast address behind their CDN: TCP and TLS succeed on all of them, our path is fine. The resolution: their limit counted *business operations per day*, not connections; the threshold moved exactly when they adjusted the rule, so the counter was theirs. Keep-alive would not have helped. What was needed was an IP allowance at their edge, not a WAF exception. Lesson: tell refused (TCP) from timeout (TLS/HTTP); "we don't see your request" is not proof that the fault is yours.

Also a silent configuration decay: while adding keys for a new flow, the cluster secret was overwritten wholesale instead of merged, wiping the credentials of an old, long-working flow on the same base URL. The client logged "settings empty" and *sent the request anyway*, already broken, instead of failing loudly. Class: a configuration error that never surfaces as a 500 and lies deep in the logs.

## 3. Arrived, but turned away at the door: signature and authorisation

**Symptom.** Requests are in the log with 401 or 403. Or, worse, a 200 on signature failure, because "we return 200 so they stop retrying". Then the provider's delivery is green, your status is not applied, and both sides are telling the truth.

**Causes.** The signature is computed over a *re-serialised* body rather than the raw bytes: key order, unicode escaping, number formatting (`1.0` versus `1`), and the signature "doesn't match" on some requests, not all. A timestamp check with a window of N seconds and a clock that drifted on one side. Secret rotation at the provider with no overlap period. A signature header that changes case or is dropped by a proxy. A signature scheme implemented from an *assumption* instead of the webhook docs, failing on 100% of callbacks from day one. A verification secret missing from the environment, with the code substituting a placeholder and carrying on. Authorisation by IP: see station 2.

**How to check.** The share of signature failures among all inbound requests. Percentages mean a systematic cause (serialisation, clocks); 100% for one provider means the scheme. And separately: what does the endpoint return on failed verification? If 200, you have a class of silently lost callbacks that no alert will ever show.

**What I have seen (receiving).** A payout webhook from a newly integrated provider: the request sat in its initial status, the provider insisted "we delivered, you answered 200". By the request id, in centralised logs over the whole period: the callback did arrive, minutes after creation, with a "cancelled" status, and failed signature verification; by convention the endpoint answered 200. Both sides were right at once. The cause: verification had been written on the assumption that the webhook was signed like our *outbound* requests to the same provider (method + URL + body, base64, one header). The real scheme, in their docs, was body only, hex, *a different header*. Because of the header name, verification received an empty string on every real callback, 100% failure from day one, independent of the secret. The irony: a correct implementation already existed in the same codebase for the same provider's older *deposit* webhook. The clue that cracked it was reasoning about the placeholder: the secret had been missing both when signing and when verifying, and a self-consistent placeholder cannot produce a mismatch by itself, so the scheme was wrong, not the token. The request was unblocked by hand, replaying the payload saved in the log through the same handler.

Lessons. The signing scheme for *inbound* webhooks is separate from the scheme for *outbound* requests: find the webhook docs before implementing. If the same provider already has a working callback in the code, compare against that, not against the nearest piece by meaning. Without docs, leave an explicit TODO with a review date and an integration test on a real signature sample, not "by eye".

Also on the receiving side: a handler that catches `Exception` wholesale and answers 200 "unexpected error", including on a row-lock error because someone else was updating the request at that moment. The provider considers it delivered; the status is not applied. Class: catch-all plus 200. Either do not return 200 in that case and let them retry, or park the callback for deferred processing.

And the mirror, sending. Our delivery service treated any 2xx as success and *never read the response body*. The merchant answered 200 with a body saying "this request is already terminal on my side, your callback was ignored". Our delivery was green, three attempts, all 200; the merchant's payout was in the opposite status. When "the callback arrived but nothing was applied", the first move is to read the *body* of the responses in the attempts, not the code. Consequence for both sides: the receiver should say in the body that it applied the event; the sender should parse the body, or at least alert on "ignored".

**Reproduced in public code.** In its usual setup, WooCommerce Stripe Gateway answers a webhook whose signature fails validation with HTTP 204, so Stripe counts it delivered and never retries ([case](case-woocommerce-stripe-204.md)). Razorpay for WooCommerce answers 200 to a delivery whose signature doesn't match ([case](case-razorpay-woocommerce.md)). The catch-and-acknowledge variant, twice with Mollie, whose webhook carries only an id: the request for the status fails, and the endpoint answers 200 anyway, in Mollie for WooCommerce ([case](case-mollie-woocommerce-200.md)) and in Odoo, where the 18.0 code says in a comment that it acknowledges "to avoid getting spammed" ([case](case-odoo-mollie-200.md)).

**My position on what to return when the signature fails.** I would return 4xx and live with the retries. The "200 to stop the retry storm" convention turns every verification bug into silence, and silence is the expensive failure in payments: the retry storm is loud, bounded by the provider's schedule and costs you nothing but log lines, while a lost terminal status costs you a support ticket per payment. If the receiving system genuinely cannot afford a storm, the honest compromise is: return 200 only after the raw payload is persisted and an alert fires, so that "accepted but not applied" is a queue you can replay, not a hole. What I would not defend is the case above: 200, nothing persisted, nobody told.

## 4. Let in, but parsed wrong: the schema

**Symptom.** The request was accepted with a 200, it is in the application log, but nothing changed in the database, or the wrong thing did. This often surfaces only when the provider introduces a new status value or a new field.

**Causes.** The receiving schema silently drops undeclared fields: the provider added a sub-status or a decline reason, the sender sees it in its logs, the receiver never does. A strict enum on status: an unknown value → 400 → the provider retries until exhaustion → the message lands in their dead letter, and nobody on your side learns of it. A status-mapping table that covers *combinations* rather than values, so a known status with empty sub-fields turns out "unknown". Types: amount as string versus number, minor units versus major, `null` versus empty string, timestamps without an offset. And the parsed model is what gets logged, not the raw body, so the log cannot tell you what actually arrived.

**How to check.** Is the raw body in the logs at all, before parsing? If yes, take a sample and compare it to what landed in the model, field by field. Count validation errors and "unknown status" lines by field and value over a period: one field with hundreds of failures is the one.

**What I have seen (sending).** A new field was added to the merchant callback (links to payout documents). Correct in the backend, present in the raw event on the bus; the merchant did not see it, and the "request body" in the admin panel lacked it too. A long search in the backend, in the wrong repository. Between the backend and the merchant sat a separate delivery service that re-parsed the payload with a strict schema, dropping the undeclared field silently, which is the default in popular validation libraries, and serialised the outbound body *from the parsed model*. Two errors of thinking: "the field is in the event, so it will go out", and "the body in the admin panel is what arrived". Lesson: the raw event log is not what actually leaves; every new field must be declared on *every* hop; when "the backend sends it and the receiver doesn't see it", check the last hop's schema first.

Receiving: a provider sends `cancelled` with empty sub-fields (an echo after our own cancel request), while the mapping table only knows the variant with populated sub-fields. Log line "unknown status mapping", response 200, so no retry storm, but the request never moves to cancelled and hangs until its TTL. On the order of a hundred such events in a couple of hours before anyone looked at the error tracker. Class: the mapping does not cover every combination, and the unknown combination gets a 200 and silence.

**Reproduced in public code.** In Razorpay for WooCommerce with the Payment Action set to "Authorize", the webhook path counts an authorized payment as a failure and marks the order Failed, while the browser path marks the order for the same payment paid ([case](case-razorpay-woocommerce.md)).

## 5. Parsed, but not applied: state machine, ordering, deduplication

**Symptom.** Everything is in the logs, everything validates, and the row is in the wrong status. The most treacherous class: the system looks healthy.

**Causes.** Delivery order is not guaranteed: "succeeded" arrives before "processing"; the state machine rejects the backwards transition, then applies "processing", and the payment is stuck there forever though both messages arrived. Deduplication by the provider's event id, while the provider reuses one id for every status change of a payment, so the second, legitimate transition is discarded as a duplicate. A transient error (failed to take a row lock) caught by an intermediate layer and re-raised as a domain validation error; the retry policy matches on exception *type*, and a race designed to be retryable becomes a permanent failure on the first attempt. A race with your own timeout job: "cancel if unpaid after N minutes", the customer pays at minute N plus a few seconds, the job cancels, the success callback arrives next and hits a terminal "cancelled". And a non-success status from the provider that by your rules does not finalise, after which nobody ever comes again.

**How to check.** Compare the *sequence* of events at the provider with the sequence of transitions applied on your side, for one payment. Look for two classes: "received but not applied" and "applied but not received". The second class is manual status edits from the back office, and that is a story of its own.

**What I have seen (receiving).** On the order of a hundred deposit requests stuck in their initial status for weeks. Two hypotheses were refuted empirically *before* the cause was found, and both had come "from reading the code": that the broker pod had been recreated and lost its delayed tasks, but the pod's uptime did not match the window; and that scheduling the one-off timeout task failed silently, but there were tens of thousands of "task scheduled" lines without gaps and zero "failed to schedule". The real cause, traced through one id end to end: the one-off timeout task ran, hit a row lock (someone else was saving the request at that moment), and the model layer *repackaged* the lock error as a validation error. The task's auto-retry list matched by exception type, validation errors were not in it, so a permanent failure on the first attempt. Two minutes later the real provider callback arrived with a *non-success* status, and by the rules non-success does not finalise. The request stayed forever: a one-off task does not come a second time. Lessons: a retry policy is verified not by reading the task's code but by what actually reaches it through every intermediate `except`; do not defend a hypothesis by reading code, count log lines first; and one one-off task cannot be the only path to a terminal status (station 7).

Sending, the "applied but not received" case inverted: statuses toggled by hand to force a callback re-send, a chain of three transitions in twenty seconds (cancelled → succeeded → disputed → cancelled), sent the merchant an *extra* callback with status "succeeded" (sequence number +1 per transition), and each transition actually moved money: apply, revert, freeze. There was a re-send button in the admin panel; nothing helps against a terminal lock on the receiver's side. Class: toggling statuses to trigger a callback moves money.

Delivery order and reused event ids I list here as classes I check for, not as incidents I have run down myself.

## 6. Applied, but not visible: transaction and replication

**Symptom.** The log says "status updated", the UI or report shows the old status. Sometimes it resolves itself in minutes, sometimes never.

**Causes.** The 200 was sent before the commit: the process was killed or the commit failed, and the provider already counts the delivery as successful and will not retry. The write and a side effect share one transaction: the notification failed, and the status write rolled back with it. Reads from a replica: the UI, the reconciliation job or a worker reads a lagging replica and decides on stale state. A cache does the same.

**How to check.** For one stuck payment, compare the row on the primary with what the UI shows. Match 200 responses in the access log against actual writes over the same interval: "200 without a write" is station 6.

This is the one station on the map I list from the literature rather than from my own incident log. It belongs on the map because the check is cheap.

## 7. Nobody is watching: the callback as the only path

**Symptom.** Any of stations 1–6 turns into "the payment has been stuck for three days", because apart from the callback there is no other way to learn the status. Or a second path formally exists and is itself silent.

**Causes.** No periodic status poll against the provider's API for non-terminal payments older than X minutes. No metric for "age of the oldest non-terminal payment" and no alert on it. The only path to a terminal status is one delayed task (station 5), and if it did not run, the payment never gets there. A periodic watchdog that exists but never fires, or fires and cannot deliver its result while reporting success. A retry ladder without a last rung: after the Nth attempt the row falls out of the selection forever, with no terminal status and no alert.

**How to check.** One query: the maximum age of a payment not in a terminal status, right now. If the answer is "days", you have station 7 regardless of the other six. It is the cheapest check on this list and the most telling. Second: the distribution of the attempt counter across non-terminal deliveries; a spike at exactly one value means there is a ceiling. Third: does the watchdog's name appear in the scheduler log *at all*?

**What I have seen (receiving).** A periodic reminder about stuck payouts had never fired *once* in its entire existence. The schedule was interval-based, the scheduler kept no persistent state, so on every scheduler restart the interval started over; production deploys ran more than once an hour, and the task simply never survived to its first run, quietly, without a single error. Neighbouring cron-style schedules worked: they compute "due" from calendar time, not from the last run. When the schedule was fixed, a second, independent bug surfaced: the task ran, alert delivery failed on an invalid chat id, the code logged a warning and reported success. The watchdog was broken twice and reported "succeeded" both times. Lessons: interval schedules only when the interval is well below the restart frequency; when "the task doesn't run", start with the scheduler log and whether the task's name appears at all; "succeeded" in the trace is not "result delivered", read the sender's ERROR lines for the moment of execution.

Sending: merchant callback retries. The selection for re-delivery covered attempts below 3 and exactly 3, 4, 5, 6 with backoff; at 7 the counter fell out of the condition forever, no terminal status, no alert. Thousands of rows accumulated across *all* merchants over months, systemic rather than a one-off. Class: a retry ladder without a last rung. The same bug later served as an emergency brake: to stop a mass re-send, the counter was set out of range.

Receiving: the one-off timeout task as the only path (station 5's case). The conclusion: on top of it there has to be a periodic sweep that picks up non-terminal requests older than the TTL, in case the one-off task did not arrive for any reason. And one more "one chance, no second pass": matching an inbound payment confirmation to a request within a window of about ten minutes from creation, with a "checked" flag set even when no match was found. Money that arrived after the window stays unattached forever, although it arrived. Class: a one-shot check with a "we looked" marker.

**Reproduced in public code.** Razorpay for WooCommerce answers the webhook with 200 and leaves the event for a cron job, which marks it done even when the payment couldn't be fetched from the API: one chance, a "we looked" marker, and the 200 already sent ([case](case-razorpay-woocommerce.md); first reported in razorpay-woocommerce#664). In Odoo, after an acknowledged failure, the post-processing cron never asks Mollie again ([case](case-odoo-mollie-200.md)).

## Fifteen minutes to find your station

Checks from cheapest to most expensive:

1. Age of the oldest non-terminal payment (station 7).
2. Counters: sent by the provider versus received by you, per day (stations 1–2).
3. Response codes on inbound requests from the provider, per day (stations 2–3).
4. What the endpoint returns on signature failure and on `except Exception` (station 3).
5. Whether the raw body is logged before parsing; how many "unknown status" lines (station 4).
6. Distribution of the attempt counter across non-terminal deliveries (station 7, for senders).
7. Sequence of events at the provider versus sequence of transitions on your side, for three random stuck payments (stations 5–6).

All of this is reading. Nothing on the list needs write access or touches production.

## What to fix now, what later

Not "fix everything". Of seven stations, usually two are leaking. Now: a second path to a terminal status (an API poll, the age metric, a sweep on top of one-off tasks) and the raw body in the logs. Both are cheap and both cure the blindness. Later: signatures over raw bytes and per the webhook docs, a state machine that rejects illegal transitions loudly, deduplication not keyed on the provider's event id, a non-200 to the provider on catch-all, and response bodies read on the sending side.

**How not to fix it** (sending). After the cause was fixed, the *entire* retry backlog was released at once: thousands of rows, many a week old, across all merchants. Zero problems reached the fixed path; thousands of stale statuses reached merchant backends that had long since resolved those requests differently. Mass 500s and, per the customer, some users "in debit". Lesson: before a mass re-send, assess not only "will it fail" but the *age* of the data that is about to fly again; one merchant and a small batch first. And separately: do not toggle statuses by hand to trigger a callback (station 5).

## Three places where the same thing breaks again in six months

The next provider. A different webhook signing scheme, a different set of statuses and sub-fields, different rules about what finalises. Verification "by analogy" and a mapping built from "what we saw in the first week" are exactly the two bugs that cost weeks of stuck requests above (stations 3 and 4).

Configuration. Secrets and keys per merchant or provider live in the environment, the admin form shows what the code does not read, and the cluster secret gets overwritten wholesale on the next addition. This broke twice in one season (stations 1 and 2).

Retry infrastructure. One-off tasks, interval schedules and retry ladders break quietly, and the more often you deploy, the more often they break. When releases get more frequent, the watchdogs go silent (station 7).

---

*If you want this map run against your own logs and database, read-only, that is the audit I do. The tool in this repository is the first pass.*
