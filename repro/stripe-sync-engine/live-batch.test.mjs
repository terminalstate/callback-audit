// A live webhook batch whose pipeline_sync ends with a failed eof is never processed again.
// Same harness as apps/service/src/__tests__/workflow.test.ts: Temporal TestWorkflowEnvironment, stubbed activities.
// Only the pipelineSync activity is faked; the workflow code is the repository's (transpiled by build.mjs).
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { TestWorkflowEnvironment } from '@temporalio/testing'
import { Worker } from '@temporalio/worker'
import path from 'node:path'

const workflowsPath = path.resolve('build/service/temporal/workflows/index.js')
const emptyState = {
  source: { streams: {}, global: {} },
  destination: { streams: {}, global: {} },
  engine: { streams: {}, global: {} },
}
const progress = (status, streams = {}) => ({
  started_at: new Date().toISOString(),
  elapsed_ms: 100,
  global_state_count: 1,
  derived: { status, records_per_second: 10, states_per_second: 1, total_record_count: 0, total_state_count: 0 },
  streams,
})
const eof = (status, streams = {}) => ({
  status,
  has_more: false,
  ending_state: emptyState,
  run_progress: progress(status, streams),
  request_progress: progress(status, streams),
})
const successEof = eof('succeeded')

function stubActivities(pipelineSync) {
  const activities = {
    discoverCatalog: async () => ({ streams: [] }),
    pipelineSetup: async () => {},
    pipelineSync,
    pipelineTeardown: async () => {},
    updatePipelineStatus: async () => {},
  }
  return { ...activities, setup: activities.pipelineSetup, sync: activities.pipelineSync, teardown: activities.pipelineTeardown }
}

let testEnv
beforeAll(async () => {
  testEnv = await TestWorkflowEnvironment.createLocal()
}, 300_000)
afterAll(async () => {
  await testEnv?.teardown()
})

async function deliveriesOfEvt1(failedEof, queue, waitMs = 15_000) {
  const liveBatches = []
  let failed = false
  const worker = await Worker.create({
    connection: testEnv.nativeConnection,
    taskQueue: queue,
    workflowsPath,
    activities: stubActivities(async (_pipelineId, opts) => {
      if (opts?.input) {
        liveBatches.push(opts.input.map((e) => e.id))
        if (!failed) {
          failed = true
          return { eof: failedEof } // e.g. Postgres unreachable while this batch was written
        }
      }
      return { eof: successEof }
    }),
  })

  await worker.runUntil(async () => {
    const handle = await testEnv.client.workflow.start('pipelineWorkflow', {
      args: ['test_pipe'],
      workflowId: `wf-${queue}`,
      taskQueue: queue,
    })
    await new Promise((r) => setTimeout(r, 1500))
    // POST /webhooks/:pipeline_id has already answered 200 to Stripe at this point (apps/service/src/api/app.ts)
    await handle.signal('source_input', { id: 'evt_1', type: 'invoice.paid' })
    const deadline = Date.now() + waitMs
    while (Date.now() < deadline && liveBatches.flat().filter((id) => id === 'evt_1').length < 2) {
      await new Promise((r) => setTimeout(r, 250))
    }
    await handle.cancel()
    await handle.result().catch(() => {})
  })
  return liveBatches.flat().filter((id) => id === 'evt_1').length
}

describe('live webhook batches', () => {
  it('processes a successful batch once', async () => {
    expect(await deliveriesOfEvt1(successEof, 'q-ok', 8_000)).toBe(1)
  }, 60_000)

  it('re-processes an event whose batch ended with eof status "failed"', async () => {
    expect(await deliveriesOfEvt1(eof('failed', { invoice: { status: 'errored' } }), 'q-failed')).toBeGreaterThanOrEqual(2)
  }, 60_000)

  it('re-processes an event whose batch left a stream errored (destination flush error: eof status "started")', async () => {
    expect(await deliveriesOfEvt1(eof('started', { invoice: { status: 'errored' } }), 'q-errored')).toBeGreaterThanOrEqual(2)
  }, 60_000)
})
