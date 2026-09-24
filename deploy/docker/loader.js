// Ethora.com platform, copyright: Dappros Ltd (c) 2026, all rights reserved
//
// Generic entry loader for the service images built from deploy/docker/.
//
//   node /app/loader.js <cwd> <entry> [service args...]
//
// Changes to <cwd> (dotenv-style config loading in the services resolves
// relative to it), installs the bytenode require hook when the image was
// built with BYTECODE=1 (bytenode is then present in /app/node_modules),
// retries explicit "./x.js" requires as ".jsc", and requires <entry>. In a
// plain build the hook is simply absent and the same requires load the .js.
'use strict'
const path = require('path')
const Module = require('module')

const [cwd, entry] = process.argv.slice(2)
if (!cwd || !entry) {
  console.error('usage: loader.js <cwd> <entry> [args...]')
  process.exit(2)
}

let bytecode = false
try {
  require('bytenode')
  bytecode = true
} catch (_) {
  // plain-JS image
}

if (bytecode) {
  const originalResolve = Module._resolveFilename
  Module._resolveFilename = function resolveWithBytecodeFallback(request, ...rest) {
    try {
      return originalResolve.call(this, request, ...rest)
    } catch (err) {
      if (err && err.code === 'MODULE_NOT_FOUND' && typeof request === 'string' && /\.js$/.test(request)) {
        return originalResolve.call(this, request.replace(/\.js$/, '.jsc'), ...rest)
      }
      throw err
    }
  }
}

// Hide loader args from the service.
process.argv.splice(2, 2)
process.chdir(cwd)
require(path.resolve(cwd, entry))
