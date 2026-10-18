local M = {}

-- Julia block starters that are closed by `end`.
--
-- You can remove entries you do not want, e.g. module/struct.
local START =
[[\v<mutable>\s+<struct>|<primitive>\s+<type>|<baremodule>|<module>|<struct>|<function>|<macro>|<quote>|<let>|<begin>|<if>|<for>|<while>|<try>|<do>]]

local END = [[\v<end>]]

local function has_treesitter_comment_or_string_capture(row0, col0)
  if not (vim.treesitter and vim.treesitter.get_captures_at_pos) then
    return false
  end

  local ok, captures = pcall(vim.treesitter.get_captures_at_pos, 0, row0, col0)
  if not ok or not captures then
    return false
  end

  for _, cap in ipairs(captures) do
    local name = type(cap) == "table" and cap.capture or cap

    if type(name) == "string" then
      name = name:lower()

      if name:find("comment", 1, true)
          or name:find("string", 1, true)
          or name:find("character", 1, true) then
        return true
      end
    end
  end

  return false
end

local function has_syntax_comment_or_string_group()
  local line = vim.fn.line(".")
  local col = vim.fn.col(".")

  local syn_id = vim.fn.synID(line, col, 1)
  local syn_name = vim.fn.synIDattr(syn_id, "name"):lower()

  return syn_name:find("comment", 1, true)
      or syn_name:find("string", 1, true)
      or syn_name:find("char", 1, true)
end

-- Used by Vim's searchpairpos() as skip expression.
--
-- Return 1 to ignore a match, 0 to accept it.
function _G.__pyrepl_julia_searchpair_skip()
  local row0 = vim.fn.line(".") - 1
  local col0 = vim.fn.col(".") - 1

  if has_treesitter_comment_or_string_capture(row0, col0) then
    return 1
  end

  if has_syntax_comment_or_string_group() then
    return 1
  end

  return 0
end

local SKIP = "v:lua.__pyrepl_julia_searchpair_skip()"

local function with_saved_view(fn)
  local view = vim.fn.winsaveview()

  local ok, a, b = pcall(fn)

  vim.fn.winrestview(view)

  if not ok then
    error(a)
  end

  return a, b
end

function M.find_range()
  return with_saved_view(function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local cur_line = cursor[1]
    local cur_col1 = cursor[2] + 1

    -- Search backwards for the nearest unmatched block opener.
    --
    -- Flags:
    --   b = backwards
    --   c = accept match at cursor position
    --   n = do not move cursor
    --   W = do not wrap
    local start_pos = vim.fn.searchpairpos(START, "", END, "bcnW", SKIP)

    if start_pos[1] == 0 then
      return nil, nil
    end

    local start_line = start_pos[1]
    local start_col1 = start_pos[2]

    -- Put cursor on the opener and search forward to its matching `end`.
    vim.api.nvim_win_set_cursor(0, { start_line, start_col1 - 1 })

    -- Do not use `c` here. We want to start searching after the opener.
    local end_pos = vim.fn.searchpairpos(START, "", END, "nW", SKIP)

    if end_pos[1] == 0 then
      return nil, nil
    end

    local end_line = end_pos[1]

    -- Sanity check: the original cursor must be inside the found range.
    if cur_line < start_line or cur_line > end_line then
      return nil, nil
    end

    if cur_line == start_line and cur_col1 < start_col1 then
      return nil, nil
    end

    return start_line, end_line
  end)
end

function M.text_or_current_line()
  local start_line, end_line = M.find_range()

  if start_line and end_line then
    local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
    return table.concat(lines, "\n"), start_line, end_line
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  return vim.api.nvim_get_current_line(), line, line
end

return M
