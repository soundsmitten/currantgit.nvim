-- Help coverage: doc/currantgit.txt must build as a help file, every internal
-- link must resolve, and everything a user can type -- each :Git* command and
-- each buffer-local mapping on any CurrantGit buffer the smoke run opened --
-- must be named in it. Runs at the end of smoke.lua so every surface exists.

local doc_path = vim.env.CURRANTGIT_ROOT .. "/doc/currantgit.txt"
local doc = table.concat(vim.fn.readfile(doc_path), "\n")

-- 1. It builds. Duplicate tags (E154) break `:helptags`, and with it `g?`.
local tag_dir = vim.fn.tempname()
vim.fn.mkdir(tag_dir, "p")
vim.fn.writefile(vim.fn.readfile(doc_path), tag_dir .. "/currantgit.txt")
local ok, err = pcall(vim.cmd.helptags, vim.fn.fnameescape(tag_dir))
vim.fn.delete(tag_dir, "rf")
assert(ok, "doc/currantgit.txt does not build with :helptags: " .. tostring(err))

-- 2. Every |currantgit-...| link points at a *tag* defined in the file.
local defined = {}
for tag in doc:gmatch("%*([^%s*|]+)%*") do defined[tag] = true end
local broken = {}
for link in doc:gmatch("|(currantgit[^%s|]*)|") do
  if not defined[link] then broken[#broken + 1] = link end
end
assert(#broken == 0, "help links with no matching *tag*: " .. table.concat(broken, ", "))

-- 3. Every :Git* command is named, and every mapping has a help entry.
-- Vim help spells some keys differently from keymap lhs notation.
local spellings = {
  ["<C-O>"] = { "<C-O>", "CTRL-O" },
  ["<C-S-I>"] = { "<C-S-I>", "CTRL-SHIFT-I" },
}

-- A key counts only when it is in the key column of a help entry line ("co
-- Take ours", or several keys sharing one entry: "]x  [x   Jump..."), with or
-- without a {Visual} prefix. A passing mention in prose does not count.
local entry_keys = {}
for line in (doc .. "\n"):gmatch("(.-)\n") do
  local column = line:match("^(%S.-)%s%s%s+%S") or line:match("^(%S+)$")
  if column then
    for key in column:gmatch("%S+") do entry_keys[(key:gsub("^{Visual}", ""))] = true end
  end
end

local function documented(key)
  for _, spelling in ipairs(spellings[key] or { key }) do
    if entry_keys[spelling] then return true end
  end
  return false
end

local missing = {}
for name in pairs(vim.api.nvim_get_commands({})) do
  if name:match("^Git") and not doc:find(":" .. name .. "%f[^%w]") then
    missing[#missing + 1] = ":" .. name
  end
end

local seen = {}
for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
  local surface = vim.api.nvim_buf_is_valid(buffer)
    and (vim.b[buffer].currantgit_title or vim.b[buffer].currantgit_conflict_pane)
  if surface then
    for _, mode in ipairs({ "n", "x" }) do
      for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buffer, mode)) do
        local key = mapping.lhs
        local label = (mode == "x" and "{Visual}" or "") .. key
        if not seen[label] then
          seen[label] = true
          if not documented(key) then
            missing[#missing + 1] = ("%s (on %s)"):format(label, tostring(surface))
          end
        end
      end
    end
  end
end
table.sort(missing)
assert(next(seen), "help coverage found no CurrantGit buffers to inspect")
assert(#missing == 0, "not documented in doc/currantgit.txt:\n  " .. table.concat(missing, "\n  "))

print(("CurrantGit help: ok (%d mappings checked)"):format(vim.tbl_count(seen)))
