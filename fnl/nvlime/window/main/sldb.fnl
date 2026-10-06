(local buffer (require "nvlime.buffer"))
(local main (require "nvlime.window.main"))
(local psl (require "parsley"))
(local pbuf (require "parsley.buffer"))
(local pwin (require "parsley.window"))
(local {: nvim_win_set_buf
        : nvim_win_close
        : nvim_buf_get_var
        : nvim_get_current_win
        : nvim_set_current_win
        : nvim_create_autocmd
        : nvim_create_augroup}
       vim.api)

(local sldb {})

(local +filetype+ (buffer.gen-filetype buffer.names.sldb))

;;; The window the cursor should go back to once the debugger window is
;;; gone. Only the window is remembered, not the cursor position within it:
;;; neovim keeps a cursor position per window, so returning to the window
;;; is enough to land back on the right line.
(var *return-winid* nil)

;;; BufNr {any} ->
(fn buf-callback [bufnr opts]
  (buffer.set-opts bufnr {:filetype +filetype+})
  (buffer.set-vars
    bufnr {:nvlime_sldb_level opts.level
           :nvlime_sldb_frames opts.frames})
  (buffer.set-conn-var! bufnr)
  (buffer.vim-call!
    bufnr [(.. "call b:nvlime_conn.SetCurrentThread("
               opts.thread ")")]))

;;; WinID ->
(fn restore-return-win [closed-winid]
  "Puts the cursor back into the window it was in before the debugger
took focus. Does nothing when that window is gone, or when the debugger
window wasn't the focused one as it closed."
  (let [winid *return-winid*]
    (set *return-winid* nil)
    ;; `WinClosed` fires while the closing window is still the current one,
    ;; so this is what tells us the debugger was holding the cursor. Without
    ;; it, a debugger returning while the cursor sits in the repl would drag
    ;; the cursor away from it.
    (when (and winid
               (not= winid closed-winid)
               (= (nvim_get_current_win) closed-winid))
      ;; Deferred because neovim only picks the next focused window itself
      ;; after the `WinClosed` handlers have run.
      (vim.schedule
        #(when (and (pwin.visible? winid)
                    ;; Skip when something re-opened the main window in the
                    ;; meantime, e.g. `window.main.notes` swapping in a
                    ;; remaining buffer.
                    (not (pwin.visible? main.sldb.id)))
           (nvim_set_current_win winid))))))

;;; WinID ->
(fn win-callback [winid]
  (nvim_create_autocmd "WinClosed"
    ;; Re-creating the group clears it, so re-opening the debugger
    ;; doesn't stack up handlers.
    {:group (nvim_create_augroup +filetype+ {})
     :pattern (tostring winid)
     :nested true
     :callback #(restore-return-win winid)}))

;;; TODO should process config.stepping?
;;; TODO remove flickering of stepping and continue
;;; {any} ->
(fn sldb.on-debug-return [config]
  (let [(exists? bufnr) (pbuf.exists? (buffer.gen-sldb-name
                                           config.conn-name config.thread))]

    (when exists?
      ;; `nvim_buf_get_var` *throws* when the variable was never set instead
      ;; of returning nil, so the fallback has to come off a `pcall`.
      (let [(has-level? level) (pcall nvim_buf_get_var bufnr
                                      "nvlime_sldb_level")
            buf-level (if has-level? level -1)]
        (when (= buf-level config.level)
          (main.sldb:remove-buf bufnr)
          (buffer.fill! bufnr [])
          (buffer.set-vars bufnr {:buflisted false})
          (if (not (pwin.visible? main.sldb.id))
              ;; The window can already be gone: closed by hand, or by
              ;; `window.close-all`. Neither touching nor closing it is
              ;; valid then - a later `sldb.open` brings it back with
              ;; whatever buffers are left.
              nil

              (not (psl.empty? main.sldb.buffers))
              (nvim_win_set_buf
                main.sldb.id (. main.sldb.buffers
                                (length main.sldb.buffers)))

              (nvim_win_close main.sldb.id true)))))))

;;; string {any} -> [WinID BufNr]
(fn sldb.open [content config]
  (let [bufnr (buffer.create-if-not-exists
                (buffer.gen-sldb-name
                  config.conn-name config.thread)
                false
                #(buf-callback $ config))]
    ;; need to set the level and frames again
    (buffer.set-vars
    bufnr {:nvlime_sldb_level config.level
           :nvlime_sldb_frames config.frames})

    ;; Remember where the cursor was before the debugger takes focus below.
    ;; Only on a fresh entry: while the window is already up, nested levels
    ;; and `OnDebugActivate` call this again from the debugger itself, which
    ;; would otherwise overwrite the return window with the debugger's own.
    (when (not (pwin.visible? main.sldb.id))
      (set *return-winid* (nvim_get_current_win)))

    (let [winid (main.sldb:open bufnr true)]
      (win-callback winid)
      [winid bufnr])))

sldb
