-- Entry point: `nvim -l tests/e2e/run.lua [name-filter]` (see scripts/e2e).
package.path = vim.env.CURRANTGIT_ROOT .. "/tests/?.lua;" .. package.path

local harness = require("e2e.harness")
local scenarios = {}
for _, file in ipairs({ "e2e.scenarios", "e2e.commit", "e2e.commit_edges" }) do
  vim.list_extend(scenarios, require(file))
end
local ok = harness.run(scenarios, arg[1])
os.exit(ok and 0 or 1)
