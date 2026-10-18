local M = {}

local config = {
  -- Julia syntax nodes that represent complete `... end` structures.
  --
  -- You can inspect actual node names with:
  --
  --   :InspectTree
  --
  -- or, using the debug helper below:
  --
  --   :lua require("pyrepl.extract.treesitter_julia").debug_ancestors()
  node_types = {
    function_definition = true,
    macro_definition = true,

    if_statement = true,
    for_statement = true,
    while_statement = true,
    try_statement = true,
    let_statement = true,
    quote_statement = true,

    module_definition = true,
    baremodule_definition = true,

    struct_definition = true,
    mutable_struct_definition = true,
    primitive_definition = true,
    abstract_definition = true,

    -- Some grammars/versions may use these names.
    function_expression = true,
    macro_expression = true,
    module_expression = true,
    struct_expression = true,
  },

  -- `begin ... end` is sometimes represented as a generic compound/block node.
  -- We only accept these if the node text starts with the keyword `begin`.
  begin_like_node_types = {
    begin_statement = true,
    begin_expression = true,
    compound_statement = true,
    compound_expression = true,

    -- This is intentionally guarded by a textual `begin` check below.
    -- We do NOT want to return every generic block body.
    block = true,
  },

  -- For `open(...) do io ... end`, the useful region is usually the parent
  -- call expression, not only the `do_clause` itself.
  promote_to_parent = {
    do_clause = true,
    do_block = true,
  },
}

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
end

local function get_root(bufnr)
  bufnr = bufnr or 0

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "julia")
  if not ok or not parser then
    return nil
  end

  local trees = parser:parse()
  local tree = trees and trees[1]

  if not tree then
    return nil
  end

  return tree:root()
end

local function add_col(cols, seen, col, max_col)
  col = math.max(0, math.min(col, max_col))

  if not seen[col] then
    table.insert(cols, col)
    seen[col] = true
  end
end

local function get_node_at_position(bufnr, pos)
  bufnr = bufnr or 0

  local root = get_root(bufnr)
  if not root then
    return nil
  end

  local cursor = pos
  local row = cursor[1] - 1
  local col = cursor[2]

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local max_col = #line

  local cols = {}
  local seen = {}

  -- Try the exact cursor column.
  add_col(cols, seen, col, max_col)

  -- If cursor is after a character or at EOL, try the character before it.
  if col > 0 then
    add_col(cols, seen, col - 1, max_col)
  end

  -- If the cursor is on indentation/whitespace, try the first nonblank char.
  local first_nonblank = line:find("%S")
  if first_nonblank then
    add_col(cols, seen, first_nonblank - 1, max_col)
  end

  -- Finally, try column zero.
  add_col(cols, seen, 0, max_col)

  for _, candidate_col in ipairs(cols) do
    local ok, node = pcall(function()
      return root:named_descendant_for_range(row, candidate_col, row, candidate_col)
    end)

    if ok and node and node:type() ~= "source_file" then
      return node
    end
  end

  return nil
end


local function get_node_at_cursor(bufnr)
  bufnr = bufnr or 0

  local root = get_root(bufnr)
  if not root then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local max_col = #line

  local cols = {}
  local seen = {}

  -- Try the exact cursor column.
  add_col(cols, seen, col, max_col)

  -- If cursor is after a character or at EOL, try the character before it.
  if col > 0 then
    add_col(cols, seen, col - 1, max_col)
  end

  -- If the cursor is on indentation/whitespace, try the first nonblank char.
  local first_nonblank = line:find("%S")
  if first_nonblank then
    add_col(cols, seen, first_nonblank - 1, max_col)
  end

  -- Finally, try column zero.
  add_col(cols, seen, 0, max_col)

  for _, candidate_col in ipairs(cols) do
    local ok, node = pcall(function()
      return root:named_descendant_for_range(row, candidate_col, row, candidate_col)
    end)

    if ok and node and node:type() ~= "source_file" then
      return node
    end
  end

  return nil
end

local function first_word_at_node_start(bufnr, node)
  local start_row, start_col = node:range()

  local line = vim.api.nvim_buf_get_lines(
    bufnr,
    start_row,
    start_row + 1,
    false
  )[1] or ""

  local after_start = line:sub(start_col + 1)

  return after_start:match("^%s*([%a_][%w_]*)")
end

local function choose_candidate_node(bufnr, node)
  local node_type = node:type()

  -- Special case for `do ... end` blocks.
  -- Usually the parent call expression is what you want to send.
  if config.promote_to_parent[node_type] then
    local parent = node:parent()

    if parent and parent:type() ~= "source_file" then
      return parent
    end

    return node
  end

  if config.node_types[node_type] then
    return node
  end

  -- Accept generic block-like nodes only if they really start with `begin`.
  if config.begin_like_node_types[node_type] then
    local word = first_word_at_node_start(bufnr, node)

    if word == "begin" then
      return node
    end
  end

  return nil
end

function M.find_node(bufnr)
  bufnr = bufnr or 0

  local node = get_node_at_cursor(bufnr)

  while node do
    local candidate = choose_candidate_node(bufnr, node)

    if candidate then
      return candidate
    end

    node = node:parent()
  end

  return nil
end

function M.find_node_at_position(bufnr, pos)
  bufnr = bufnr or 0

  local node = get_node_at_position(bufnr, pos)

  while node do
    local candidate = choose_candidate_node(bufnr, node)

    if candidate then
      return candidate
    end

    node = node:parent()
  end

  return nil
end

function M.node_line_range(node, bufnr)
  bufnr = bufnr or 0

  local start_row, _, end_row, end_col = node:range()

  local start_lnum = start_row + 1
  local end_lnum = end_row + 1

  -- If a node ends exactly at column 0 of the next line, treat the previous
  -- line as the actual final line.
  if end_col == 0 and end_row > start_row then
    end_lnum = end_row
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)

  start_lnum = math.max(1, math.min(start_lnum, line_count))
  end_lnum = math.max(start_lnum, math.min(end_lnum, line_count))

  return start_lnum, end_lnum
end

function M.text_for_node(node, bufnr)
  bufnr = bufnr or 0

  local start_lnum, end_lnum = M.node_line_range(node, bufnr)

  local lines = vim.api.nvim_buf_get_lines(
    bufnr,
    start_lnum - 1,
    end_lnum,
    false
  )

  return table.concat(lines, "\n"), start_lnum, end_lnum
end

function M.text_or_current_line(bufnr)
  bufnr = bufnr or 0

  local node = M.find_node(bufnr)

  if node then
    return M.text_for_node(node, bufnr)
  end

  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  local line = vim.api.nvim_buf_get_lines(
    bufnr,
    lnum - 1,
    lnum,
    false
  )[1] or ""

  return line, lnum, lnum
end

local function get_visual_range(buf)
  local start_pos = vim.api.nvim_buf_get_mark(buf, "<")
  local end_pos = vim.api.nvim_buf_get_mark(buf, ">")

  -- return nil if marks are empty
  -- if (start_pos[1] == 0 and start_pos[2] == 0) or (end_pos[1] == 0 and end_pos[2] == 0) then
  --   return nil, nil
  -- end

  local start_idx, end_idx = start_pos[1], end_pos[1]
  if start_idx > end_idx then
    start_idx, end_idx = end_idx, start_idx
  end

  -- return start_idx, end_idx
  return start_pos, end_pos
end

function M.visual_text_or_current_line(bufnr)
  bufnr = bufnr or 0

  local start_idx, end_idx = get_visual_range(bufnr)

  local node_start = M.find_node_at_position(bufnr, start_idx)
  local node_end = M.find_node_at_position(bufnr, end_idx)

  if node_start and node_end then
    local ts, l1, l2 = M.text_for_node(node_start, bufnr)
    local te, l3, l4 = M.text_for_node(node_end, bufnr)
    local lines      = vim.api.nvim_buf_get_lines(
      bufnr,
      math.min(l1, l3) - 1,
      math.max(l2, l4),
      false
    )
    return table.concat(lines, "\n"), math.min(l1, l3), math.max(l2, l4)
  end

  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  local line = vim.api.nvim_buf_get_lines(
    bufnr,
    lnum - 1,
    lnum,
    false
  )[1] or ""

  return line, lnum, lnum
end

function M.debug_ancestors(bufnr)
  bufnr = bufnr or 0

  local node = get_node_at_cursor(bufnr)
  local out = {}

  while node do
    local start_row, start_col, end_row, end_col = node:range()

    table.insert(
      out,
      string.format(
        "%s [%d:%d - %d:%d]",
        node:type(),
        start_row + 1,
        start_col,
        end_row + 1,
        end_col
      )
    )

    node = node:parent()
  end

  vim.print(out)

  return out
end

return M
