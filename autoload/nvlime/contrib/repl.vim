""
" @dict NvlimeConnection.CreateREPL
" @public
"
" Create the REPL thread, and optionally register a [callback] function to
" handle the result.
"
" [coding_system] is implementation-dependent. Omit this argument or pass
" v:null to let the server choose it for you.
"
" This method needs the SWANK-REPL contrib module. See
" @function(NvlimeConnection.SwankRequire).
function! nvlime#contrib#repl#CreateREPL(coding_system = v:null, Callback = v:null) dict
  function! s:CreateREPL_CB(conn, Cb, chan, msg) abort
    call nvlime#CheckReturnStatus(a:msg, 'nvlime#contrib#repl#CreateREPL')
    " The package for the REPL defaults to ['COMMON-LISP-USER', 'CL-USER'],
    " so SetCurrentPackage(...) is not necessary.
    "call a:conn.SetCurrentPackage(a:msg[1][1])
    call nvlime#TryToCall(a:Cb, [a:conn, a:msg[1][1]])
  endfunction

  let cmd = [nvlime#SYM('SWANK-REPL', 'CREATE-REPL'), v:null]
  if a:coding_system isnot v:null
    let cmd += [nvlime#KW('CODING-SYSTEM'), a:coding_system]
  endif
  call self.Send(self.EmacsRex(cmd),
        \ function('s:CreateREPL_CB', [self, a:Callback]))
endfunction

""
" @dict NvlimeConnection.ListenerEval
" @public
"
" Evaluate {expr} in the current package and thread, and optionally register a
" [callback] function to handle the result.
" {expr} should be a plain string containing the lisp expression to be
" evaluated.
"
" *PRINT-RIGHT-MARGIN* is bound to [width] during the evaluation, so printed
" results wrap to the REPL window. It defaults to the width of that window,
" via @function(nvlime#ui#ResultWindowWidth).
"
" [echo] is written to the REPL when the evaluation starts. If [queue] is
" not v:null, the evaluation waits until the REPL thread is free, showing
" [queue] meanwhile. See @function(nvlime#ui#transcript#Send).
"
" This method needs the SWANK-REPL contrib module. See
" @function(NvlimeConnection.SwankRequire).
function! nvlime#contrib#repl#ListenerEval(expr, Callback = v:null,
      \ width = v:null, echo = v:null, queue = v:null) dict
  function! s:ListenerEvalCB(conn, Cb, chan, msg) abort
    let stat = s:CheckAndReportReturnStatus(a:conn, a:msg,
          \ 'nvlime#contrib#repl#ListenerEval')
    if stat
      call nvlime#TryToCall(a:Cb, [a:conn, a:msg[1][1]])
    endif
  endfunction

  let width = a:width is v:null ? nvlime#ui#ResultWindowWidth() : a:width
  call nvlime#ui#transcript#Send(self, self.EmacsRex(
        \ [nvlime#SYM('SWANK-REPL', 'LISTENER-EVAL'), a:expr,
        \ nvlime#KW('WINDOW-WIDTH'), width]),
        \ function('s:ListenerEvalCB', [self, a:Callback]),
        \ a:echo, a:queue)
endfunction

function! nvlime#contrib#repl#Init(conn)
  let a:conn['CreateREPL'] = function('nvlime#contrib#repl#CreateREPL')
  let a:conn['ListenerEval'] = function('nvlime#contrib#repl#ListenerEval')
  call a:conn.CreateREPL(v:null)
endfunction

function! s:CheckAndReportReturnStatus(conn, return_msg, caller)
  let status = a:return_msg[1][0]
  if status['name'] == 'OK'
    return v:true
  elseif status['name'] == 'ABORT'
    call a:conn.ui.OnWriteString(a:conn, a:return_msg[1][1] . "\n",
          \ {'name': 'ABORT-REASON', 'package': 'KEYWORD'})
    return v:false
  else
    call a:conn.ui.OnWriteString(a:conn, string(a:return_msg[1]),
          \ {'name': 'UNKNOWN-ERROR', 'package': 'KEYWORD'})
    return v:false
  endif
endfunction

" vim: sw=2
