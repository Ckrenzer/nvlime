local window = require("nvlime.window")
local buffer = require("nvlime.buffer")
local km = require("nvlime.keymaps")
local ut = require("nvlime.utilities")
local pbuf = require("parsley.buffer")
local pwin = require("parsley.window")
local nvim_create_namespace = vim.api.nvim_create_namespace
local nvim_create_augroup = vim.api.nvim_create_augroup
local nvim_create_autocmd = vim.api.nvim_create_autocmd
local nvim_clear_autocmds = vim.api.nvim_clear_autocmds
local nvim_buf_clear_namespace = vim.api.nvim_buf_clear_namespace
local nvim_buf_set_extmark = vim.api.nvim_buf_set_extmark
local nvim_get_current_win = vim.api.nvim_get_current_win
local input = {}
local _2bnamespace_2b = nvim_create_namespace(buffer["gen-filetype"](buffer.names.input))
local _2baugroup_2b = nvim_create_augroup("nvlime-input", {clear = true})
local function calc_opts(config)
  local border_len = 2
  local wininfo = pwin["get-info"](nvim_get_current_win())
  local width = math.min(80, (wininfo.width - wininfo.textoff - border_len))
  local height = 4
  local row = (wininfo.height - height - border_len)
  return {relative = "win", row = row, col = wininfo.textoff, width = width, height = height, title = config.prompt, title_pos = "center"}
end
local function buf_callback(bufnr)
  buffer["set-conn-var!"](bufnr)
  buffer["set-vars"](bufnr, {nvlime_input = true})
  return buffer["set-opts"](bufnr, {filetype = "lisp", bufhidden = "wipe", modifiable = true})
end
local function win_callback()
  return km.feedkeys("a")
end
local function text__3evirt_lines(str)
  local lines = ut["text->lines"](str)
  local tbl_26_ = {}
  local i_27_ = 0
  for _, line in ipairs(lines) do
    local val_28_ = {{line, "Comment"}}
    if (nil ~= val_28_) then
      i_27_ = (i_27_ + 1)
      tbl_26_[i_27_] = val_28_
    else
    end
  end
  return tbl_26_
end
local function show_history_extmark(bufnr)
  local extmark_id = 0
  local history_len = #vim.g.nvlime_input_history
  local group = nvim_create_augroup("nvlime-input-history", {})
  local add_extmark
  local function _2_()
    nvim_buf_clear_namespace(bufnr, _2bnamespace_2b, 0, -1)
    extmark_id = nvim_buf_set_extmark(bufnr, _2bnamespace_2b, 0, 0, {virt_lines = text__3evirt_lines(vim.g.nvlime_input_history[history_len])})
    return nil
  end
  add_extmark = _2_
  local function _3_()
    if (pbuf["empty?"](bufnr) and (history_len > 0)) then
      return add_extmark()
    else
      return nvim_buf_clear_namespace(bufnr, _2bnamespace_2b, 0, -1)
    end
  end
  return nvim_create_autocmd({"CursorMoved", "CursorMovedI"}, {group = group, buffer = bufnr, callback = _3_})
end
input.open = function(content, config)
  local lines = ut["text->lines"](content)
  local bufnr
  local function _5_(_241)
    return buf_callback(_241)
  end
  bufnr = buffer["create-if-not-exists"](buffer["gen-name"](config["conn-name"], buffer.names.input, config.prompt), false, _5_)
  local opts = calc_opts(config)
  nvim_clear_autocmds({group = _2baugroup_2b, buffer = bufnr})
  local function _6_()
    vim.fn["nvlime#ui#input#FromBufferCancel"](bufnr)
    return nil
  end
  nvim_create_autocmd("WinClosed", {group = _2baugroup_2b, buffer = bufnr, callback = _6_})
  show_history_extmark(bufnr)
  buffer["fill!"](bufnr, lines)
  local winid
  local function _7_()
    return win_callback()
  end
  winid = window["open-float"](bufnr, opts, true, true, _7_)
  return {winid, bufnr}
end
return input