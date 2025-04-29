local M = {}

local nvim_buf_get_lines = vim.api.nvim_buf_get_lines
local nvim_win_get_cursor = vim.api.nvim_win_get_cursor
local nvim_win_set_cursor = vim.api.nvim_win_set_cursor
local nvim_get_current_line = vim.api.nvim_get_current_line
local nvim_buf_line_count = vim.api.nvim_buf_line_count
local nvim_get_option_value = vim.api.nvim_get_option_value
-- local nvim_feedkeys = vim.api.nvim_feedkeys

local cmd = vim.cmd
local fn = vim.fn

local function str_index(str, idx)
   if idx < 0 then
      idx = 0
   end
   return str:sub(idx, idx)
end

---@param linenr integer
---@return integer
local function line_indent_size(linenr)
   local linestr = nvim_buf_get_lines(0, linenr - 1, linenr, false)[1]
   local _, size = string.find(linestr, "^%s*")
   return size ---@diagnostic disable-line: return-type-mismatch
end

local skip_expr_regex = vim.regex("\\cstring\\|comment")
---Expression used to check whether we should skip a match with searchpair()
---@return boolean
function M.skip_expr()
   local line, col = unpack(nvim_win_get_cursor(0))
   local synname = fn.synIDattr(fn.synID(line, col + 1, 0), "name")
   -- Skip inside strings and comments
   if skip_expr_regex:match_str(synname) then
      return true
   end

   local linestr = nvim_get_current_line()
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
   local char = str_index(linestr, col + 1)
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
   local pos = nvim_win_get_cursor(0)
   local old_indent = line_indent_size(pos[1])

   cmd.normal({ "=ib", bang = true })
   if linenr then
      cmd.normal({ "=" .. linenr .. "G", bang = true })
   end

   local new_indent = line_indent_size(pos[1])
   pos[2] = pos[2] + new_indent - old_indent
   nvim_win_set_cursor(0, pos)
end

---TODO: change this to actual variable
local fts_balancing_all_brackets = vim.regex("\\cfennel")

function M.is_balanced()
   local line, col = unpack(nvim_win_get_cursor(0))
   local linestr = nvim_get_current_line()
   if col >= #linestr then
      col = #linestr - 1
   end

   local stopb = math.max(line - vim.g.paredit_matchlines, 1)
   local stopf = math.min(line + vim.g.paredit_matchlines, nvim_buf_line_count(0))

   if check_unbalance(linestr, col, "(", ")", stopb, stopf) then
      return false
   end

   local ft = nvim_get_option_value("filetype", { scope = "local" })
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

return M
