// Transpile (no type-check) the workflow code under test from the stripe/sync-engine checkout given in SYNC_ENGINE_ROOT.
// Files are copied verbatim; only TypeScript syntax is stripped.
import ts from 'typescript'
import fs from 'node:fs'
import path from 'node:path'

const root = process.env.SYNC_ENGINE_ROOT
if (!root) throw new Error('set SYNC_ENGINE_ROOT')
const out = path.resolve('build')
fs.rmSync(out, { recursive: true, force: true })

function emit(src, dst) {
  const code = fs.readFileSync(path.join(root, src), 'utf8')
  const js = ts.transpileModule(code, {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
  }).outputText
  fs.mkdirSync(path.dirname(path.join(out, dst)), { recursive: true })
  fs.writeFileSync(path.join(out, dst), js)
}

const svc = 'apps/service/src'
for (const f of fs.readdirSync(path.join(root, svc, 'temporal/workflows'))) {
  if (f.endsWith('.ts')) emit(`${svc}/temporal/workflows/${f}`, `service/temporal/workflows/${f.replace(/\.ts$/, '.js')}`)
}
emit(`${svc}/temporal/lib/backfill-loop.ts`, 'service/temporal/lib/backfill-loop.js')
emit(`${svc}/lib/utils.ts`, 'service/lib/utils.js')

// @stripe/sync-protocol: the two modules the workflows use at runtime (emptySyncState → SyncState schema)
const proto = 'node_modules/@stripe/sync-protocol'
emit('packages/protocol/src/protocol.ts', '../' + proto + '/protocol.js')
emit('packages/protocol/src/helpers.ts', '../' + proto + '/helpers.js')
fs.writeFileSync(path.join(proto, 'index.js'), "export * from './protocol.js'\nexport * from './helpers.js'\n")
fs.writeFileSync(path.join(proto, 'package.json'), JSON.stringify({ name: '@stripe/sync-protocol', type: 'module', main: 'index.js' }))
console.log('built from', root)
