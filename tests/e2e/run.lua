-- Entry point: `nvim -l tests/e2e/run.lua [name-filter]` (see scripts/e2e).
package.path = vim.env.CURRANTGIT_ROOT .. "/tests/?.lua;" .. package.path

local harness = require("e2e.harness")
local ok = harness.run(require("e2e.scenarios"), arg[1])
os.exit(ok and 0 or 1)
