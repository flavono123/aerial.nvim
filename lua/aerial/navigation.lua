local data = require("aerial.data")
local util = require("aerial.util")
local config = require("aerial.config")
local window = require("aerial.window")

local M = {}

local function _get_current_lnum(winid)
  local bufnr = vim.api.nvim_get_current_buf()
  if data.has_symbols(bufnr) then
    local bufdata = data.get_or_create(bufnr)
    local cached_lnum = bufdata.positions[winid]
    if cached_lnum then
      return cached_lnum
    end
  end

  if util.is_aerial_buffer(bufnr) then
    bufnr = util.get_source_buffer()
  end
  if data.has_symbols(bufnr) then
    return window.get_position_in_win(bufnr, winid)
  else
    return nil
  end
end

local function get_target_win()
  local bufnr, _ = util.get_buffers()
  local winid
  if util.is_aerial_buffer() then
    if string.find(vim.o.switchbuf, "uselast") then
      local my_winid = vim.api.nvim_get_current_win()
      vim.cmd("noau wincmd p")
      if bufnr == vim.api.nvim_get_current_buf() then
        winid = vim.api.nvim_get_current_win()
      end
      util.go_win_no_au(my_winid)
    end
    if winid == nil then
      for _, tabwin in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_is_valid(tabwin) and vim.api.nvim_win_get_buf(tabwin) == bufnr then
          winid = tabwin
          break
        end
      end
    end
  else
    winid = vim.api.nvim_get_current_win()
  end
  return winid
end

M.up = function(direction, count)
  direction = direction or -1
  count = count or 1
  local winid = get_target_win()
  if not winid then
    error("Could not find destination window")
    return
  end
  local pos = _get_current_lnum(winid)
  if pos == nil then
    return
  end
  local bufnr, _ = util.get_buffers()
  local bufdata = data.get_or_create(bufnr)

  -- We're going up and BACKWARDS
  local index
  if direction < 0 then
    local prev_root_index
    local last_root_index
    local item
    for _, candidate, i in bufdata:iter({ skip_hidden = true }) do
      if candidate.level == 0 then
        last_root_index = i
      end
      if not item then
        if i == pos.lnum then
          item = candidate
        elseif candidate.level == 0 then
          prev_root_index = i
        end
      end
    end
    -- If we're already at the root, go to the previous root item
    -- or wrap back around to the last root item
    if item.level == 0 then
      index = prev_root_index or last_root_index
    else
      -- Otherwise, it's a simple tree traversal
      for _ = 1, count do
        if not item.parent then
          break
        end
        item = item.parent
      end
      index = bufdata:indexof(item)
    end
  else
    -- We're going up and FORWARDS
    local target_level
    local start_level
    local found = false
    for _, item, i in bufdata:iter({ skip_hidden = true }) do
      if i == pos.lnum then
        start_level = item.level
        target_level = math.max(0, item.level - count)
      elseif target_level then
        if item.level == target_level or item.level < start_level then
          found = true
          break
        end
      end
    end
    -- If we didn't find a target, it's because we're at the end of the list.
    if not found then
      index = 1
    end
  end
  M.select({
    index = index,
    jump = false,
    winid = winid,
  })
  if util.is_aerial_buffer() then
    vim.api.nvim_win_set_cursor(0, { index, 0 })
  end
end

M.prev = function(step)
  step = step or 1
  M.next(-1 * step)
end

M.next = function(step)
  step = step or 1
  local winid = get_target_win()
  if not winid then
    error("Could not find destination window")
    return
  end
  local pos = _get_current_lnum(winid)
  if pos == nil then
    return
  end
  local bufnr, _ = util.get_buffers()

  local count = data.get_or_create(bufnr):count({ skip_hidden = true })
  -- If we're not *exactly* on a location, make sure we hit the nearest location
  -- first even if we're currently considered to be "on" it
  if step < 0 and pos.relative == "below" then
    step = step + 1
  elseif step > 0 and pos.relative == "above" then
    step = step - 1
  end
  local new_num = ((pos.lnum + step - 1) % count) + 1
  M.select({
    index = new_num,
    jump = false,
    winid = winid,
  })
  if util.is_aerial_buffer() then
    vim.api.nvim_win_set_cursor(0, { new_num, 0 })
  end
end

M.select = function(opts)
  opts = vim.tbl_extend("keep", opts or {}, {
    index = nil,
    split = nil,
    jump = true,
  })
  local winid = opts.winid
  if not winid then
    winid = get_target_win()
  end
  if not winid then
    error("Could not find destination window")
    return
  end
  if opts.index == nil then
    if util.is_aerial_buffer() then
      opts.index = vim.api.nvim_win_get_cursor(0)[1]
    else
      local bufdata = data.get_or_create(0)
      opts.index = bufdata.positions[winid].lnum
    end
    opts.index = opts.index or 1
  end

  local item = data.get_or_create(0):item(opts.index)
  if not item then
    error(string.format("Symbol %s is outside the bounds", opts.index))
    return
  end

  if opts.split then
    local split = opts.split
    if split == "vertical" or split == "v" then
      split = "belowright vsplit"
    elseif split == "horizontal" or split == "h" or split == "s" then
      split = "belowright split"
    end
    local my_winid = vim.api.nvim_get_current_win()
    util.go_win_no_au(winid)
    vim.cmd(split)
    winid = vim.api.nvim_get_current_win()
    util.go_win_no_au(my_winid)
  end
  local bufnr, _ = util.get_buffers()
  vim.api.nvim_win_set_buf(winid, bufnr)
  local lnum = item.selection_range and item.selection_range.lnum or item.lnum
  local col = item.selection_range and item.selection_range.col or item.col
  vim.api.nvim_win_set_cursor(winid, { lnum, col })
  local cmd = config.post_jump_cmd
  if cmd and cmd ~= "" then
    vim.fn.win_execute(winid, cmd, true)
  end

  if opts.jump then
    vim.api.nvim_set_current_win(winid)
    if config.close_on_select then
      window.close()
    end
  else
    window.update_position(winid)
  end
  if config.highlight_on_jump then
    util.flash_highlight(bufnr, lnum, config.highlight_on_jump)
  end
end

return M
