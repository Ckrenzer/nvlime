let g:nvlime_input_history = []

" Show an input window. {complete_cb} runs when the input is submitted with
" <CR>. Closing the window any other way cancels: [cancel_cb] runs instead,
" or, when it is omitted, 'Canceled.' is shown.
function! nvlime#ui#input#FromBuffer(conn, prompt, init_val, complete_cb,
      \ cancel_cb = v:null)
  let [_, bufnr] = luaeval('require"nvlime.window.input".open(_A[1], _A[2])',
        \ [a:init_val, { 'conn-name': a:conn.cb_data.name, 'prompt': a:prompt}])
  call setbufvar(bufnr, 'nvlime_input_complete_cb', a:complete_cb)
  call setbufvar(bufnr, 'nvlime_input_cancel_cb', a:cancel_cb)
  call cursor('$', len(getline('$')) + 1)
endfunction

function! nvlime#ui#input#MaybeInput(str, str_cb, prompt,
      \ default = '', conn = v:null, comp_type = v:null)
  if a:str is v:null
    if a:conn is v:null
      if a:comp_type is v:null
        let content = input(a:prompt, a:default)
      else
        let content = input(a:prompt, a:default, a:comp_type)
      endif
      call s:CheckInputValidity(content, a:str_cb, v:true)
    else
      let cur_package = a:conn.GetCurrentPackage()
      let cur_buf = bufnr()
      " Oh yeah we LOVE callbacks. You don't go to the hell. The hell
      " comes to you.
      call nvlime#ui#input#FromBuffer(
            \ a:conn, a:prompt,
            \ a:default,
            \ { -> s:CheckInputValidity(nvlime#ui#CurBufferContent(),
            \ { str -> nvlime#ui#WithBuffer(cur_buf, function(a:str_cb, [str]))},
            \ v:true)})
      if bufnr() != cur_buf
        " We set the current package, so that the input buffer has the
        " same context as the the buffer where we initiated the input
        " operation, and completions etc. in the input buffer can work
        " as expected.
        call a:conn.SetCurrentPackage(cur_package)
      endif
    endif
  else
    call s:CheckInputValidity(a:str, a:str_cb, v:false)
  endif
endfunction

function! nvlime#ui#input#FromBufferComplete()
  let buf = bufnr()
  let Callback = getbufvar(buf, 'nvlime_input_complete_cb', v:null)
  if Callback is v:null | return | endif

  " Retire the callback *before* running it. Deleting the buffer below wipes
  " the input window, which fires the WinClosed autocmd that
  " `nvlime.window.input` registers, which calls
  " nvlime#ui#input#FromBufferCancel(). With the callback gone, that finds
  " the input already handled and does nothing.
  call setbufvar(buf, 'nvlime_input_complete_cb', v:null)

  try
    if len(nvlime#ui#CurBufferContent()) > 0
      call nvlime#ui#input#SaveHistory(nvlime#ui#CurBufferContent(v:true))
    endif
    if mode() == 'i'
      stopinsert
    endif
    call Callback()
  finally
    " Tear the input buffer down even when the callback threw. Its callback
    " is already retired, so leaving the buffer around would strand the user
    " in a window whose submit key silently does nothing.
    if bufloaded(buf)
      " Errors here are swallowed on purpose: this runs while an exception
      " from the callback may still be propagating, and that one is the one
      " worth seeing.
      silent! call nvim_buf_delete(buf, { 'force': v:true })
    endif
  endtry
endfunction

" Called when the input window {buf} closes. If the input was not submitted
" first, closing the window is a cancel: by |:q|, by `q`, by moving to
" another window, or by anything else that closes it.
function! nvlime#ui#input#FromBufferCancel(buf)
  let Callback = getbufvar(a:buf, 'nvlime_input_complete_cb', v:null)
  if Callback is v:null | return | endif
  call setbufvar(a:buf, 'nvlime_input_complete_cb', v:null)

  try
    if mode() == 'i'
      stopinsert
    endif
    let CancelCB = getbufvar(a:buf, 'nvlime_input_cancel_cb', v:null)
    if CancelCB is v:null
      call nvlime#ui#ErrMsg('Canceled.')
    else
      call CancelCB()
    endif
  finally
    if bufloaded(a:buf)
      silent! call nvim_buf_delete(a:buf, { 'force': v:true })
    endif
  endtry
endfunction

function! nvlime#ui#input#SaveHistory(text)
  let max_items = g:nvlime_options.input_history_limit
  let history = g:nvlime_input_history

  if len(history) > 0 && history[-1] == a:text
    return
  endif

  let prev_idx = index(history, a:text)
  while prev_idx >= 0
    call remove(history, prev_idx)
    let prev_idx = index(history, a:text)
  endwhile

  call add(history, a:text)
  if len(history) > max_items
    let delta = len(history) - max_items
    let history = history[delta:-1]
  endif

  let g:nvlime_input_history = history
endfunction

function! nvlime#ui#input#GetHistory(backward = v:true, idx = v:null)
  let history_len = len(g:nvlime_input_history)
  if history_len == 0
    return [0, '']
  endif

  let idx = a:idx is v:null ? history_len : a:idx
  if a:backward
    if idx <= 0
      return [0, '']
    elseif idx > history_len
      let idx = history_len
    endif
    return [idx - 1, g:nvlime_input_history[idx - 1]]
  else
    if idx >= history_len - 1
      return [history_len, '']
    elseif idx < -1
      let idx = -1
    endif
    return [idx + 1, g:nvlime_input_history[idx + 1]]
  endif
endfunction

function! nvlime#ui#input#NextHistoryItem(backward = v:true)
  if exists('b:nvlime_input_history_idx')
    let [next_idx, text] = nvlime#ui#input#GetHistory(
          \ a:backward, b:nvlime_input_history_idx)
  else
    let b:nvlime_input_orig_text = nvlime#ui#CurBufferContent(v:true)
    let [next_idx, text] = nvlime#ui#input#GetHistory(a:backward)
  endif

  let b:nvlime_input_history_idx = next_idx
  if len(text) > 0
    call nvlime#ClearCurrentBuffer()
    call nvlime#ui#AppendString(text)
  elseif next_idx > 0 && exists('b:nvlime_input_orig_text')
    unlet b:nvlime_input_history_idx
    call nvlime#ClearCurrentBuffer()
    call nvlime#ui#AppendString(b:nvlime_input_orig_text)
    unlet b:nvlime_input_orig_text
  endif
  call cursor('$', len(getline('$')) + 1)
endfunction

function! s:CheckInputValidity(str_val, cb, cancellable)
  if len(a:str_val) > 0
    call a:cb(a:str_val)
    return
  endif

  let history_len = len(g:nvlime_input_history)
  if history_len > 0
    call a:cb(g:nvlime_input_history[history_len - 1])
  elseif a:cancellable
    call nvlime#ui#ErrMsg('Canceled.')
  endif
endfunction

" vim: sw=2
