# callback-audit

Read-only audit of webhook/callback delivery. It answers one question about a payment
system: **where do payments stop short of a terminal state?**

A payment that sits in `pending` for hours is almost never stuck at the provider. The money
moved, or didn't, within seconds. What is stuck is your *knowledge* of it: the callback that
carried the terminal status was never applied. "Never applied" is not the same as "never
sent" — between the provider and the row in your database there are seven places where a
callback gets lost, each with its own symptom and its own check. This tool runs the checks
that can be run from exports, and tells you which station to look at next.

It reads CSV exports and log files. It does not connect to a database, does not call the
network, and does not write anything. You can run it on a laptop against files a colleague
sent you.

```
pip install git+https://github.com/terminalstate/callback-audit
callback-audit --demo
```

## The seven stations

| # | Station | Typical cause | What the tool checks |
|---|---|---|---|
| 1 | Provider never sent it, or sent it elsewhere | callback URL points at an old environment; provider only sends some event types; sender crashed before I/O and recorded a fake response code | provider events vs. inbound requests per day |
| 2 | Sent, never reached you | TLS chain, IP allowlist after the provider changed egress, ingress timeout shorter than the handler, edge-level rejection below HTTP | inbound response codes per day; silent days |
| 3 | Reached you, rejected at the door | signature over a re-serialised body, clock skew, rotated secret, wrong header name, scheme implemented "by analogy"; endpoint returns 200 on failure anyway | signature failures as a share of inbound; sender side: 2xx whose body says "ignored" |
| 4 | Accepted, parsed wrong | strict schema silently drops undeclared fields; status mapping covers combinations, not values; only the parsed model is logged | unknown status / validation failures per day |
| 5 | Parsed, not applied | out-of-order delivery, dedup on a reused event id, transient error re-wrapped into a non-retryable one, race with your own timeout task, non-success terminal statuses that your rules never finalise; manual status flipping | provider-terminal vs. local-non-terminal join; event id reuse; out-of-order events; transitions leaving a terminal status; rapid manual chains |
| 6 | Applied, not visible | 200 before commit, rollback of a side effect in the same transaction, reads from a replica or cache | payments export vs. status history disagreement (the rest needs a human) |
| 7 | Nobody is watching | callback is the only path to a terminal state; the watchdog runs on a schedule that resets on every deploy, or reports success while its alert fails; retry ladder with no last rung | age of the oldest non-terminal payment; attempt-counter cliff |

The cheapest and most telling check is the last one: *how old is your oldest non-terminal
payment right now?* If the answer is "days", station 7 applies regardless of the other six.

## Inputs

Every input is optional. Each one unlocks a subset of the checks; the report marks the rest
as `n/a` and says which input would answer them.

| Flag | Format | Columns |
|---|---|---|
| `--payments` | CSV | `id, created_at, status` + optional `updated_at, provider, terminal` |
| `--terminal` | list | your terminal statuses, e.g. `succeeded,failed,canceled,expired` (or give a boolean `terminal` column) |
| `--events` | CSV | the provider's view: `payment_id, at, status` + optional `event_id, terminal` (most provider dashboards export this) |
| `--provider-terminal` | list | terminal statuses as the provider names them (defaults to `--terminal`) |
| `--inbound` | nginx combined log, or CSV `at, status_code[, path, remote, user_agent]` | requests that hit your webhook endpoint; use `--path-filter /webhooks/` to drop the rest |
| `--app-log` | plain text | your application log; lines are matched against two regexes (`--signature-pattern`, `--unknown-status-pattern`), overridable |
| `--history` | CSV | status history: `payment_id, at, from_status, to_status` |
| `--deliveries` | CSV | *if you are the sender*: `payment_id, attempt` + optional `sent_at, response_code, response_body` |

Timestamps: ISO 8601 (with or without offset), epoch seconds or milliseconds, or the
access-log format. **Naive timestamps are interpreted as UTC.** Column names are matched
exactly; extra columns are ignored.

The payments export is usually one query:

```sql
select id, created_at, updated_at, status, provider
from payments
where created_at > now() - interval '30 days';
```

Export the payments table and the status history at the same moment, otherwise the station 6
check will report the time between the two exports as a disagreement.

## Reading the report

```
callback-audit --payments payments.csv --terminal succeeded,failed,canceled \
               --events provider_events.csv \
               --inbound access.log --path-filter /webhooks/ \
               --app-log app.log --history history.csv
```

The report is Markdown (`--json` for machines). One line per check, grouped by station:

* **SUSPECT** — worth a human's next hour. The details block has counts, the days that stand
  out, and up to ten example ids (`--top` to change) so you can trace them.
* **ok** — nothing in this export. Not proof of health; proof that this particular symptom is absent.
* **info** — a fact to keep in mind (a small share of signature failures, events arriving out of order).
* **n/a** — the input that would answer it was not given.

Thresholds are deliberately conservative and all overridable (`--stuck-hours`, and the
per-check shares in `callback_audit/checks/__init__.py`). The tool is meant to point, not to
judge: every SUSPECT ends with a *Next:* line saying what to look at.

## How not to fix it

Two things the report will tempt you to do, both of which have cost real money:

* **Mass-replaying an old retry backlog** after fixing the sender. The rows are safe to send
  again; the *statuses in them* may be weeks stale, and the receiver has long since resolved
  those payments differently. Replay one merchant, one small batch, and look at the response
  bodies before doing the rest.
* **Flipping statuses by hand to force a callback resend.** Every transition emits a callback,
  and in systems where transitions move balances, moves money. A resend button must resend
  without touching state.

## What it does not do

* It does not connect to anything. If you want it to read your database directly, write the
  query, export the CSV, and run it on that — the point is that a read-only export is all the
  access the audit needs.
* It does not check station 6 (applied but not visible) beyond one consistency test between
  two exports. That station needs a person comparing the primary with what the UI shows.
* It does not know your providers. Signature schemes, status vocabularies and retry policies
  differ; the tool works on the shape of the data (counts, shares, sequences, ages), which is
  the same everywhere.

## Development

```
uv sync                      # or: pip install -e '.[dev]'
uv run pytest
uv run ruff check . && uv run ruff format --check .
python -m callback_audit.demo /tmp/demo   # write the synthetic demo dataset somewhere to look at it
```

`--demo` generates a synthetic, deterministic dataset (`callback_audit/demo.py`): two
fictional providers, fourteen days of traffic, and one planted problem per station so that
every check fires. The module docstring lists what was planted; `--demo-dir` keeps the files.

## License

MIT.
