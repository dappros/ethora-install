#!/usr/bin/env node
// Ethora.com platform, copyright: Dappros Ltd (c) 2026, all rights reserved
//
// Compile every first-party .js file under a directory to V8 bytecode
// (.jsc) with bytenode and delete the .js source. Run inside the Docker
// build on the exact Node the runtime image uses: bytecode is bound to the
// V8 version and is not portable across Node majors or CPU architectures.
//
//   node tools/docker/compile-bytecode.js dist/src
//
// What is deliberately left alone:
//   - node_modules: open-source dependencies, nothing to protect, and some
//     packages rely on Function.prototype.toString which bytecode breaks
//   - *.test.js: deleted outright, tests have no place in a runtime image
//   - start.js: the loader that installs the require hook must stay plain
const fs = require('fs')
const path = require('path')
const bytenode = require('bytenode')

const root = path.resolve(process.argv[2] || 'dist/src')
if (!fs.existsSync(root)) {
  console.error(`no such directory: ${root}`)
  process.exit(2)
}

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) {
      if (entry.name === 'node_modules') continue
      walk(full, out)
    } else if (entry.isFile() && entry.name.endsWith('.js')) {
      out.push(full)
    }
  }
  return out
}

async function main() {
  const files = walk(root)
  let compiled = 0
  let removedTests = 0
  for (const file of files) {
    if (file.endsWith('.test.js')) {
      fs.unlinkSync(file)
      removedTests += 1
      continue
    }
    if (path.basename(file) === 'start.js') continue
    await bytenode.compileFile({ filename: file, output: file.replace(/\.js$/, '.jsc'), compileAsModule: true })
    fs.unlinkSync(file)
    compiled += 1
  }
  // Source maps would leak the original layout; the build does not emit them
  // today, but make sure none survive if that ever changes.
  for (const map of walk(root).filter((f) => f.endsWith('.js.map'))) fs.unlinkSync(map)
  console.log(`[bytecode] compiled ${compiled} files under ${root}, removed ${removedTests} test files (node ${process.version})`)
}

main().catch((e) => {
  console.error('[bytecode] failed:', e && e.stack ? e.stack : e)
  process.exit(1)
})
