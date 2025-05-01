local M = {}

local api = vim.api
local cmd = vim.cmd
local fn = vim.fn

local function char_at_index(str, idx)
   if idx < 0 then
      idx = 0
   end
   return str:sub(idx, idx)
end

---@param linenr integer
---@return integer
local function line_indent_size(linenr)
   local linestr = api.nvim_buf_get_lines(0, linenr - 1, linenr, false)[1]
   local _, size = string.find(linestr, "^%s*")
   return size ---@diagnostic disable-line: return-type-mismatch
end

---Returns true when buffer has no syntax highlighting
---@return boolean
local function is_syntax_off()
   return vim.b.current_syntax == nil
end

---Returns name of the syntax id group
---@param synid integer
---@return string
local function get_synname(synid)
   return fn.synIDattr(synid, "name")
end

---Returns table with last three syntax ids
---under the `line` `col` position in the current buffer
---@param line integer 1-based line number
---@param col integer 0-based column number
---@return integer[]
local function last3_synids(line, col)
   local synstack = fn.synstack(line, col + 1)
   local len = #synstack
   -- last three ids should be more than enough to determine
   -- if syntax under the cursor belongs to some syntax group
   -- at least for such groups like comment and string
   -- which don't have a lot of nested groups
   return {
      synstack[len],
      synstack[len - 1],
      synstack[len - 2],
   }
end

---@param regex vim.regex
---@param line integer
---@param col integer
---@param match_eol boolean
---@return boolean
function M.synname_match(regex, line, col, match_eol)
   if match_eol and col >= #fn.getline(line) then
      col = col - 1
   end

   for _, synid in ipairs(last3_synids(line, col)) do
      local synname = get_synname(synid)
      if regex:match_str(synname) then
         return true
      end
   end
   return false
end

local skip_expr_regex = vim.regex("\\cstring\\|comment")
---Expression used to check whether we should skip a match with searchpair()
---@return boolean
function M.skip_expr()
   local line, col = unpack(api.nvim_win_get_cursor(0))
   local synname = get_synname(fn.synID(line, col + 1, 0))
   -- Skip inside strings and comments
   if skip_expr_regex:match_str(synname) then
      return true
   end

   local linestr = api.nvim_get_current_line()
   if linestr:sub(col, col) == "\\" then
      col = math.max(0, col - 1)
      -- Skip parens escaped by `\`
      if linestr:sub(col, col) ~= "\\" then
         return true
      end
   end

   return false
end

local function check_unbalance(linestr, col, open, close, stopb, stopf, openpat, closepat)
   local char = char_at_index(linestr, col + 1)
   local skip_fn = "v:lua.require'sexp'.skip_expr()"
   local p1, p2
   openpat = openpat or open
   closepat = closepat or close
   if char == open then
      p1 = fn.searchpair(openpat, "", closepat, "brnmWc", skip_fn, stopb)
      p2 = fn.searchpair(openpat, "", closepat, "rnmW", skip_fn, stopf)
   elseif char == close then
      p1 = fn.searchpair(openpat, "", closepat, "brnmW", skip_fn, stopb)
      p2 = fn.searchpair(openpat, "", closepat, "rnmWc", skip_fn, stopf)
   else
      p1 = fn.searchpair(openpat, "", closepat, "brnmW", skip_fn, stopb)
      p2 = fn.searchpair(openpat, "", closepat, "rnmW", skip_fn, stopf)
   end
   return p1 ~= p2
end

-- local function feedkeys(keys, escape_ks)
--    nvim_feedkeys(keys, "xt", escape_ks or false)
-- end

---Reindent form and adjust cursor position
---If `linenr` is present, then additionally reindent to this line
---@param linenr? integer
function M.reindent_form(linenr)
   local pos = api.nvim_win_get_cursor(0)
   local old_indent = line_indent_size(pos[1])

   cmd.normal({ "=ib", bang = true })
   if linenr then
      cmd.normal({ "=" .. linenr .. "G", bang = true })
   end

   local new_indent = line_indent_size(pos[1])
   pos[2] = pos[2] + new_indent - old_indent
   api.nvim_win_set_cursor(0, pos)
end

---TODO: change this to actual variable
local fts_balancing_all_brackets = vim.regex("\\cfennel")

function M.is_balanced()
   local line, col = unpack(api.nvim_win_get_cursor(0))
   local linestr = api.nvim_get_current_line()
   if col >= #linestr then
      col = #linestr - 1
   end

   local stopb = math.max(line - vim.g.paredit_matchlines, 1)
   local stopf = math.min(line + vim.g.paredit_matchlines, api.nvim_buf_line_count(0))

   if check_unbalance(linestr, col, "(", ")", stopb, stopf) then
      return false
   end

   local ft = api.nvim_get_option_value("filetype", { scope = "local" })
   if fts_balancing_all_brackets:match_str(ft) then
      if check_unbalance(linestr, col, "[", "]", stopb, stopf, "\\[", "\\]") then
         return false
      end
      if check_unbalance(linestr, col, "{", "}", stopb, stopf) then
         return false
      end
   end

   return true
end

local sexp_key
local dot_reg = ""
local changedtick

local augroup = vim.api.nvim_create_augroup("sexp_augroup", {})

local s_and_bs = api.nvim_replace_termcodes([[s<BS>]], true, false, true)
local s_and_del = api.nvim_replace_termcodes([[s<Del>]], true, false, true)
function M.s_key()
   if not (vim.g.paredit_mode and M.is_balanced()) then
      api.nvim_feedkeys(vim.v.count1 .. "s", "nt", false)
   end

   local linestr = api.nvim_get_current_line()
   local col = fn.col(".")
   if char_at_index(linestr, col) == ")" then
      sexp_key = "s_key"

      if col > 1 and char_at_index(linestr, col - 1) == "(" then
         api.nvim_feedkeys(s_and_bs, "ntx", false)
         api.nvim_create_autocmd("InsertEnter", {
            group = augroup,
            callback = function()
               vim.cmd.undojoin()
            end,
            once = true,
         })
      end

      api.nvim_feedkeys("a", "nt", false)

      api.nvim_create_autocmd("ModeChanged", {
         group = augroup,
         pattern = "i*:[^i]*",
         callback = function()
            changedtick = vim.b.changedtick
            dot_reg = fn.getreg(".")
         end,
         once = true,
      })
   else
      api.nvim_feedkeys(vim.v.count1 .. "s", "nt", false)
   end
end

local function dot_repeat()
   if changedtick == vim.b.changedtick then
      M[sexp_key]()
      api.nvim_feedkeys(dot_reg, "ntx", false)
   else
      vim.cmd.normal({ ".", bang = true })
   end
end

vim.keymap.set("n", "s", M.s_key, { silent = true })
vim.keymap.set("n", ".", dot_repeat, { silent = true })

return M
