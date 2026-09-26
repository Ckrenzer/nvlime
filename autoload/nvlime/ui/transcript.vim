" The REPL buffer as a transcript: the code of each request sits above the
" output and results it produced.
"
" Code sent from the source is held in Nvlime until the REPL thread is free:
" the request before it has returned, and no debugger is open on the thread.
" Sent earlier, it would wait behind the running request, or run at once
" inside the debugger. Held code is shown below the last line of the REPL
" buffer, and dropped when the request before it is aborted.
"
" Other requests for the REPL thread, such as an evaluation in a debugger
" frame or a value sent from the inspector, are sent at once. The REPL thread
" runs them in the order they arrive, inside the debugger if one is open. So
" their code is written when they start: when the request before them
" returns, or when that one stops in the debugger, which goes on running
" whatever is sent to its thread.

let s:namespace = nvim_create_namespace('nvlime_repl_held')

""
" @public
"
" Send {msg}, an :EMACS-REX for the current thread of {conn}, and write
" {echo} to the REPL once the request starts. {echo} is a list of
" [str, str_type] pairs, each written with @function(NvlimeUI.OnWriteString),
" or v:null. {Callback} handles the reply, as for
" @function(NvlimeConnection.Send). Return the id of the request, or v:null
" if it is held.
"
" {msg} and {echo} can also be functions that return them, called when the
" request is sent and when it starts. What they return then can depend on
" the requests before, e.g. the prompt on the package the REPL is in.
"
" If {queue} is not v:null, the request is held until the REPL thread is
" free, and dropped if the request before it is aborted. {queue} is then the
" code as the REPL shows it, whose first line is shown while it is held.
"
" Requests for other threads run alongside the REPL thread, so there is no
" order to keep for them, and {echo} is written at once.
function! nvlime#ui#transcript#Send(conn, msg, Callback, echo = v:null,
      \ queue = v:null)
  if a:conn.ui is v:null
    return a:conn.Send(s:Resolve(a:msg), a:Callback)
  endif

  let entry = {'echo': a:echo, 'id': v:null, 'started': v:false}
  if !s:IsREPLThread(a:conn, a:conn.GetCurrentThread())
    call s:Write(a:conn, entry)
    return a:conn.Send(s:Resolve(a:msg), a:Callback)
  endif

  let state = s:State(a:conn)
  if a:queue isnot v:null
    call extend(entry, {'msg': a:msg, 'Callback': a:Callback,
          \ 'summary': s:Summary(a:queue)})
    call add(state.held, entry)
    call s:StartNext(a:conn)
    call s:RedrawConn(a:conn)
    return entry.id
  endif

  let entry.id = a:conn.Send(s:Resolve(a:msg),
        \ function('s:OnReply', [a:conn, a:Callback, entry]))
  " A Send that handles the reply before it returns has started it already.
  if !entry.started
    if state.running is v:null
      call s:Start(a:conn, entry)
    else
      call add(state.sent, entry)
    endif
  endif
  return entry.id
endfunction

""
" @public
"
" The debugger opened on {thread} at {level}. {conts} holds the ids of the
" requests it interrupted, innermost first. {restarts} are the restarts it
" offers, as [name, description] lists.
function! nvlime#ui#transcript#OnDebug(conn, thread, level, conts,
      \ restarts = v:null)
  let state = s:State(a:conn)
  let running = state.running
  let on_repl_thread = state.thread isnot v:null && a:thread == state.thread
  if running isnot v:null && type(a:conts) == v:t_list
        \ && index(a:conts, running.id) >= 0
    " Only a request on the REPL thread can be running, so this is it.
    let state.thread = a:thread
    call add(state.suspended, [running, a:level])
    let state.running = v:null
  elseif running is v:null && on_repl_thread && !state.unwinding
        \ && (empty(state.suspended) || state.suspended[-1][1] < a:level)
    " The REPL thread stopped while running nothing of ours, e.g. it was
    " interrupted while idle. This stands in for a request on the stack.
    call add(state.suspended, [{'echo': v:null, 'id': v:null,
          \ 'started': v:true, 'idle': v:true, 'continued': v:false,
          \ 'restarts': type(a:restarts) == v:t_list ? a:restarts : []},
          \ a:level])
    return
  elseif !(state.unwinding && on_repl_thread)
    return
  endif

  " The debugger waits for requests now, and runs the next one.
  let state.unwinding = v:false
  call s:StartNext(a:conn)
endfunction

""
" @public
"
" The debugger on {thread} left {level}. The request it had interrupted runs
" again, either to go on or to unwind and return.
function! nvlime#ui#transcript#OnDebugReturn(conn, thread, level)
  let state = s:State(a:conn)
  if state.thread is v:null || a:thread != state.thread
    return
  endif
  if a:level == 1
    " One of the restarts aborts the thread, and swank starts another one
    " for the next request, so the id may be stale now.
    call nvlime#ui#transcript#LearnREPLThread(a:conn)
  endif
  if empty(state.suspended) || state.suspended[-1][1] != a:level
    return
  endif

  let entry = remove(state.suspended, -1)[0]
  let state.unwinding = v:false
  if get(entry, 'idle', v:false)
    " Nothing of ours was stopped there, so the thread is free again. Leaving
    " the debugger by any restart but CONTINUE counts as an abort, as it
    " would for a request of ours.
    if !entry.continued && empty(state.suspended)
      call s:CancelHeld(a:conn)
    endif
    call s:StartNext(a:conn)
  else
    let state.running = entry
  endif
endfunction

""
" @usage {conn} {restart} [level]
" @public
"
" {restart} is being invoked in the debugger of the current thread of
" {conn}: a restart name, or its index in the list the debugger offers.
" Swank invokes it at the innermost level, and not at all when [level] is
" given and isn't that level.
"
" When the REPL thread stopped while running nothing of ours, this is the
" only way to know how its debugger is left: swank reports leaving it the
" same way after a CONTINUE as after an ABORT.
function! nvlime#ui#transcript#OnInvokeRestart(conn, restart, level = v:null)
  if a:conn.ui is v:null || !s:IsREPLThread(a:conn, a:conn.GetCurrentThread())
    return
  endif
  let state = s:State(a:conn)
  if empty(state.suspended)
    return
  endif
  let [entry, level] = state.suspended[-1]
  if !get(entry, 'idle', v:false) || (a:level isnot v:null && a:level != level)
    return
  endif
  let name = a:restart
  if type(name) == v:t_number
    let name = get(get(entry.restarts, name, []), 0, '')
  endif
  " swank marks the restart it quits the debugger with: '*ABORT'
  let entry.continued = type(name) == v:t_string
        \ && substitute(name, '^\*', '', '') ==# 'CONTINUE'
endfunction

""
" @public
"
" Ask the REPL thread of {conn} for its id, the one the debugger names it
" by. A request for the REPL thread doesn't name it, so without the id a
" debugger on it can only be told apart once a request of ours has stopped
" there.
function! nvlime#ui#transcript#LearnREPLThread(conn)
  if a:conn.ui is v:null
    return
  endif
  " SWANK::CURRENT-THREAD-ID is internal, but it is what swank names the
  " thread with in :DEBUG. The public SWANK:LIST-THREADS only has thread
  " names, which don't tell two connections apart, and the REPL thread
  " swank starts after the first one is killed has another name.
  call a:conn.WithThread({'name': 'REPL-THREAD', 'package': 'KEYWORD'},
        \ {-> a:conn.Send(
        \ a:conn.EmacsRex([nvlime#SYM('SWANK', 'CURRENT-THREAD-ID')]),
        \ function('s:OnREPLThreadId', [a:conn]))})
endfunction

""
" @public
"
" {conn} is closing. The requests it still holds are dropped.
function! nvlime#ui#transcript#OnClose(conn)
  if a:conn.ui isnot v:null && has_key(a:conn, 'repl_transcript')
    call s:CancelHeld(a:conn)
  endif
endfunction

""
" @usage {bufnr} [conn]
" @public
"
" Show the requests [conn] holds below the last line of its REPL buffer
" {bufnr}. [conn] defaults to the connection of that buffer. Call it
" whenever lines are added to the buffer, since the held requests have to
" stay below them.
function! nvlime#ui#transcript#Redraw(bufnr, conn = v:null)
  let conn = a:conn is v:null ? getbufvar(a:bufnr, 'nvlime_conn', v:null) : a:conn
  if type(conn) != v:t_dict || !has_key(conn, 'repl_transcript')
        \ || !bufloaded(a:bufnr)
    return
  endif
  let state = conn.repl_transcript
  if empty(state.held) && !state.drawn
    return
  endif

  call nvim_buf_clear_namespace(a:bufnr, s:namespace, 0, -1)
  let state.drawn = !empty(state.held)
  if !state.drawn
    return
  endif
  let last = nvim_buf_line_count(a:bufnr)
  " The prompt as it would be if the request were sent now
  let prompt = nvlime#ui#transcript#Prompt(conn)
  call nvim_buf_set_extmark(a:bufnr, s:namespace, last - 1, 0, {
        \ 'virt_lines': map(copy(state.held),
        \ {_, e -> [[prompt . e.summary, 'nvlime_replHeld']]})})
  " Scrolling to the last line leaves lines below it out of sight.
  for winid in win_findbuf(a:bufnr)
    if line('.', winid) == last
      call win_execute(winid, 'normal! zb')
    endif
  endfor
endfunction

""
" @public
"
" Return the prompt the REPL shows in front of code sent to {conn}, naming
" the package the REPL evaluates it in: 'CL-USER> '. See
" @function(nvlime#contrib#repl#Package).
function! nvlime#ui#transcript#Prompt(conn)
  let pkg = nvlime#contrib#repl#Package(a:conn)
  return (type(pkg) == v:t_list ? pkg[1] : '') . '> '
endfunction

""
" @public
"
" Return {text} as the REPL shows it. {text} was cut out of the current
" buffer starting at {from_pos}, a [line, col] list, so its first line lost
" the text in front of it but the other lines kept their full indentation.
" Those lines lose that much indentation again, measured in display columns,
" so the text keeps the shape it has in the buffer. Only leading spaces and
" tabs are removed: a line indented less than that loses its indentation and
" nothing else. {text} is returned as it is when {from_pos} is not a
" position.
function! nvlime#ui#transcript#Dedent(text, from_pos)
  if type(a:from_pos) != v:t_list || len(a:from_pos) < 2 || a:from_pos[0] < 1
    return a:text
  endif
  let width = strdisplaywidth(
        \ strpart(getline(a:from_pos[0]), 0, a:from_pos[1] - 1))
  if width <= 0
    return a:text
  endif

  let lines = split(a:text, "\n", v:true)
  for i in range(1, len(lines) - 1)
    let lines[i] = s:DropIndent(lines[i], width)
  endfor
  return join(lines, "\n")
endfunction

""
" @public
"
" Return {text} with {prefix} in front of its first line and its other lines
" indented by the width of {prefix}, so that the text keeps its shape. Empty
" lines stay empty.
function! nvlime#ui#transcript#Prefix(prefix, text)
  let pad = repeat(' ', strdisplaywidth(a:prefix))
  let lines = split(a:text, "\n", v:true)
  call map(lines, {i, line -> i == 0 ? a:prefix . line
        \ : (empty(line) ? line : pad . line)})
  return join(lines, "\n")
endfunction

function! s:State(conn)
  if !has_key(a:conn, 'repl_transcript')
    " running: the request the REPL thread is running now
    " sent: requests sent to the REPL thread, waiting there for their turn,
    "   oldest first
    " held: requests not sent yet, oldest first
    " suspended: [request, level] for each request stopped in the debugger,
    "   innermost last
    " thread: the id of the REPL thread, asked for when the REPL is created
    "   and again whenever the thread leaves the debugger, or learned from
    "   the debugger stopping a request of ours
    " unwinding: a request aborted inside the debugger, and the debugger has
    "   not said yet which level the REPL thread is going back to
    " drawn: the held requests are shown in the REPL buffer
    let a:conn['repl_transcript'] = {
          \ 'running': v:null,
          \ 'sent': [],
          \ 'held': [],
          \ 'suspended': [],
          \ 'thread': v:null,
          \ 'unwinding': v:false,
          \ 'drawn': v:false,
          \ }
  endif
  return a:conn['repl_transcript']
endfunction

function! s:IsREPLThread(conn, thread)
  if type(a:thread) == v:t_dict
    return get(a:thread, 'name', '') ==# 'REPL-THREAD'
  endif
  let repl_thread = s:State(a:conn).thread
  return type(a:thread) == v:t_number && repl_thread isnot v:null
        \ && a:thread == repl_thread
endfunction

function! s:OnReply(conn, Callback, entry, chan, msg) abort
  " Normally a no-op. A request that replies before its turn came means the
  " one it was waiting for ended without a reply (its thread was killed, say).
  " Its code is then written late, above the abort reason or the value but
  " after any output, and the requests after it are back in order.
  call s:Start(a:conn, a:entry)
  try
    if a:Callback isnot v:null
      call a:Callback(a:chan, a:msg)
    endif
  finally
    let state = s:State(a:conn)
    call filter(state.suspended, {_, s -> s[0] isnot a:entry})
    if state.running is a:entry
      let state.running = v:null
    endif
    " An abort inside the debugger unwinds either to the level the request
    " ran in, which swank tells with another :DEBUG for it, or further out,
    " which it tells with :DEBUG-RETURN. Only then is it known what runs next.
    if s:IsAbort(a:msg) && !empty(state.suspended)
      let state.unwinding = v:true
    else
      if s:IsAbort(a:msg)
        call s:CancelHeld(a:conn)
      endif
      call s:StartNext(a:conn)
    endif
  endtry
endfunction

function! s:OnREPLThreadId(conn, chan, msg)
  if type(a:msg) == v:t_list && len(a:msg) > 1
        \ && type(a:msg[1]) == v:t_list && len(a:msg[1]) > 1
        \ && type(a:msg[1][0]) == v:t_dict
        \ && get(a:msg[1][0], 'name', '') ==# 'OK'
        \ && type(a:msg[1][1]) == v:t_number
    let state = s:State(a:conn)
    let state.thread = a:msg[1][1]
  endif
endfunction

function! s:IsAbort(msg)
  return type(a:msg) == v:t_list && len(a:msg) > 1
        \ && type(a:msg[1]) == v:t_list && len(a:msg[1]) > 0
        \ && type(a:msg[1][0]) == v:t_dict
        \ && get(a:msg[1][0], 'name', '') ==# 'ABORT'
endfunction

function! s:Start(conn, entry)
  if a:entry.started
    return
  endif
  let state = s:State(a:conn)
  call filter(state.sent, {_, e -> e isnot a:entry})
  let a:entry.started = v:true
  let state.running = a:entry
  call s:Write(a:conn, a:entry)
endfunction

" Start what the REPL thread runs next: a request already sent to it, or,
" once the thread is free, the oldest held one.
function! s:StartNext(conn)
  let state = s:State(a:conn)
  if state.running isnot v:null
    return
  endif
  if !empty(state.sent)
    call s:Start(a:conn, state.sent[0])
  elseif !empty(state.held) && empty(state.suspended) && !state.unwinding
    let entry = remove(state.held, 0)
    let entry.id = a:conn.Send(s:Resolve(entry.msg),
          \ function('s:OnReply', [a:conn, entry.Callback, entry]))
    call s:Start(a:conn, entry)
    call s:RedrawConn(a:conn)
  endif
endfunction

" Drop the held requests, leaving a line for each in the REPL.
function! s:CancelHeld(conn)
  let state = s:State(a:conn)
  if empty(state.held)
    return
  endif
  let held = remove(state.held, 0, -1)
  call s:RedrawConn(a:conn)
  call a:conn.ui.OnWriteString(a:conn,
        \ join(map(held, {_, e -> '; canceled: ' . e.summary}), "\n") . "\n",
        \ {'name': 'REPL-CANCELED', 'package': 'KEYWORD'})
endfunction

function! s:Write(conn, entry)
  let echo = s:Resolve(a:entry.echo)
  if echo is v:null
    return
  endif
  for [str, str_type] in echo
    call a:conn.ui.OnWriteString(a:conn, str, str_type)
  endfor
endfunction

" {Value}, or what it returns if it is a function
function! s:Resolve(Value)
  return type(a:Value) == v:t_func ? a:Value() : a:Value
endfunction

function! s:RedrawConn(conn)
  let name = get(get(a:conn, 'cb_data', {}), 'name', v:null)
  if type(name) != v:t_string
    return
  endif
  let bufname = luaeval('require"nvlime.buffer"["gen-repl-name"](_A)', name)
  if bufexists(bufname)
    call nvlime#ui#transcript#Redraw(bufnr(bufname), a:conn)
  endif
endfunction

" The first line of {code}, with ' ...' when more lines follow
function! s:Summary(code)
  let lines = filter(split(a:code, "\n"), {_, l -> l =~# '\S'})
  if empty(lines)
    return ''
  endif
  return trim(lines[0]) . (len(lines) > 1 ? ' ...' : '')
endfunction

" {line} without as much of its leading whitespace as fits in {width}
" display columns
function! s:DropIndent(line, width)
  let col = 0
  let n = 0
  while n < len(a:line)
    if a:line[n] ==# ' '
      let w = 1
    elseif a:line[n] ==# "\t"
      let w = &tabstop - col % &tabstop
    else
      break
    endif
    if col + w > a:width
      break
    endif
    let col += w
    let n += 1
  endwhile
  return strpart(a:line, n)
endfunction

" vim: sw=2
