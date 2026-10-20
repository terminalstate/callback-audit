# Harness: stripe/sync-engine, a failed live webhook batch is dropped after the endpoint answered 200

The repository's Temporal workflow code (`apps/service/src/temporal/workflows/*`, TypeScript stripped by `build.mjs`,
nothing else changed) runs under `@temporalio/testing`'s local server, the same way as the project's own
`apps/service/src/__tests__/workflow.test.ts`.

```
bash run.sh [WORK_DIR]          # stripe/sync-engine dev as of 2026-10-20 (0.48.5); SYNC_ENGINE_COMMIT=… for another commit
```

Needs Node 22+, npm and git (about 450 MB in `WORK_DIR`, including the Temporal dev server download).

## What is real and what is not

| Part | |
|---|---|
| `pipelineWorkflow` and its live loop | **real** (repository code, types stripped) |
| `@stripe/sync-protocol` at run time | the repository's `packages/protocol/src/protocol.ts` and `helpers.ts`, types stripped |
| Temporal | real local dev server from `@temporalio/testing` 1.15.0 |
| Activities | stubs; `pipelineSync` returns a failed eof for the first live batch and succeeds afterwards |
| The webhook | a `source_input` signal with `evt_1`, which is what `POST /webhooks/:pipeline_id` sends right before answering 200 |

## The finding

`POST /webhooks/:pipeline_id` signals the workflow and answers Stripe `200`. The live loop takes up to 10 events off the
queue with `splice` and awaits `pipelineSync`, but does not look at the eof it returns. A processing failure — Postgres
unreachable, a destination flush error — comes back as a returned eof (`status: 'failed'`, or a stream left `errored`),
not as a thrown error, so Temporal does not retry the activity either. The batch is gone, and Stripe will not resend
events it got a 200 for.

## Result

Run on 2026-10-20 (Node 24.21, vitest 3.2.4):

```
== workflow at 0cb8ca4 2026-09-14
   ✓ processes a successful batch once
   × re-processes an event whose batch ended with eof status "failed"
     → expected 1 to be greater than or equal to 2
   × re-processes an event whose batch left a stream errored (destination flush error: eof status "started")
     → expected 1 to be greater than or equal to 2
      Tests  2 failed | 1 passed (3)
== with fix.patch
      Tests  3 passed (3)
```

`fix.patch` puts a failed batch back at the head of the queue and waits 5 seconds before the next attempt. It shows the
gap rather than being a complete fix: without a growing delay or a limit, an event that always fails is retried forever.
