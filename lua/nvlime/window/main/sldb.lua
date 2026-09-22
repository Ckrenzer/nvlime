local buffer = require("nvlime.buffer")
local main = require("nvlime.window.main")
local psl = require("parsley")
local pbuf = require("parsley.buffer")
local pwin = require("parsley.window")
local nvim_win_set_buf = vim.api.nvim_win_set_buf
local nvim_win_close = vim.api.nvim_win_close
local nvim_buf_get_var = vim.api.nvim_buf_get_var
local nvim_get_current_win = vim.api.nvim_get_current_win
local nvim_set_current_win = vim.api.nvim_set_current_win
local nvim_create_autocmd = vim.api.nvim_create_autocmd
local nvim_create_augroup = vim.api.nvim_create_augroup
local sldb = {}
local _2bfiletype_2b = buffer["gen-filetype"](buffer.names.sldb)
local _2areturn_winid_2a = nil
local function buf_callback(bufnr, opts)
  buffer["set-opts"](bufnr, {filetype = _2bfiletype_2b})
  buffer["set-vars"](bufnr, {nvlime_sldb_level = opts.level, nvlime_sldb_frames = opts.frames})
  buffer["set-conn-var!"](bufnr)
  return buffer["vim-call!"](bufnr, {("call b:nvlime_conn.SetCurrentThread(" .. opts.thread .. ")")})
end
local function restore_return_win(closed_winid)
  local winid = _2areturn_winid_2a
  _2areturn_winid_2a = nil
  if (winid and (winid ~= closed_winid) and (nvim_get_current_win() == closed_winid)) then
    local function _2_()
      if (pwin["visible?"](winid) and not pwin["visible?"](main.sldb.id)) then
        return nvim_set_current_win(winid)
      else
        return nil
      end
    end
    return vim.schedule(_2_)
  else
    return nil
  end
end
local function win_callback(winid)
  local function _4_()
    return restore_return_win(winid)
  end
  return nvim_create_autocmd("WinClosed", {group = nvim_create_augroup(_2bfiletype_2b, {}), pattern = tostring(winid), nested = true, callback = _4_})
end
sldb["on-debug-return"] = function(config)
  local exists_3f, bufnr = pbuf["exists?"](buffer["gen-sldb-name"](config["conn-name"], config.thread))
  if exists_3f then
    local buf_level = (nvim_buf_get_var(bufnr, "nvlime_sldb_level") or -1)
    if (buf_level == config.level) then
      main.sldb["remove-buf"](main.sldb, bufnr)
      buffer["fill!"](bufnr, {})
      buffer["set-vars"](bufnr, {buflisted = false})
      if not psl["empty?"](main.sldb.buffers) then
        return nvim_win_set_buf(main.sldb.id, main.sldb.buffers[#main.sldb.buffers])
      else
        return nvim_win_close(main.sldb.id, true)
      end
    else
      return nil
    end
  else
    return nil
  end
end
sldb.open = function(content, config)
  local bufnr
  local function _9_(_241)
    return buf_callback(_241, config)
  end
  bufnr = buffer["create-if-not-exists"](buffer["gen-sldb-name"](config["conn-name"], config.thread), false, _9_)
  buffer["set-vars"](bufnr, {nvlime_sldb_level = config.level, nvlime_sldb_frames = config.frames})
  if not pwin["visible?"](main.sldb.id) then
    _2areturn_winid_2a = nvim_get_current_win()
  else
  end
  local winid = main.sldb:open(bufnr, true)
  win_callback(winid)
  return {winid, bufnr}
end
return sldb
