#!/usr/bin/env node
// dsh-oneclick · YAML syntax check for profile files.
// dsh uses a custom `!!js` scalar tag; it is normalised before parsing so the
// rest of the document can be validated with plain js-yaml.
//
// usage: node check-yaml.mjs <file> [<dsh-package.json>]
// exit: 0 ok · 2 syntax error · 3 js-yaml unavailable

import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'

const [, , file, dshPkgArg] = process.argv
if (!file) {
  console.error('usage: node check-yaml.mjs <file> [<dsh-package.json>]')
  process.exit(2)
}
if (!fs.existsSync(file)) {
  console.error(`missing: ${file}`)
  process.exit(2)
}

let yaml = null
for (const base of [dshPkgArg, path.join(process.cwd(), 'package.json')]) {
  if (!base) continue
  try {
    const req = createRequire(base)
    yaml = req('js-yaml')
    break
  } catch { /* try next */ }
}
if (!yaml) {
  // not fatal: the caller treats 3 as "skipped"
  console.error('js-yaml unavailable (skipped)')
  process.exit(3)
}

const src = fs.readFileSync(file, 'utf8')

// `!!js <expression>` is a dsh extension and may span several lines. Replace the
// tag plus its continuation lines (deeper indented, not a list item) with a
// plain scalar so the rest of the document can be validated by js-yaml.
function normalise(text) {
  const lines = text.split('\n')
  const out = []
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    const at = line.indexOf('!!js')
    if (at === -1) { out.push(line); continue }
    const indent = line.search(/\S/)
    out.push(line.slice(0, at) + "'__js__'")
    let j = i + 1
    while (j < lines.length) {
      const next = lines[j]
      if (next.trim() === '') { j++; continue }
      const nextIndent = next.search(/\S/)
      if (nextIndent > indent && !next.trim().startsWith('- ')) { j++; continue }
      break
    }
    i = j - 1
  }
  return out.join('\n')
}

const normalised = normalise(src)

try {
  yaml.load(normalised)
  console.log(`yaml ok: ${path.basename(file)}`)
  process.exit(0)
} catch (e) {
  console.error(`yaml error in ${file}: ${e.message}`)
  process.exit(2)
}
