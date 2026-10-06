(local window (require "nvlime.window"))
(local buffer (require "nvlime.buffer"))
(local ut (require "nvlime.utilities"))
(local pbuf (require "parsley.buffer"))
(local pwin (require "parsley.window"))
(local {: nvim_create_augroup
        : nvim_create_autocmd
        : nvim_get_current_win
        : nvim_get_mode}
       vim.api)

(local arglist {})
(local +bufname+ (buffer.gen-name buffer.names.arglist))
(local +filetype+ (buffer.gen-filetype buffer.names.arglist))

;;; {any} -> {any}
(fn calc-opts [args]
  (let [border-len 2
        wininfo (pwin.get-info (nvim_get_current_win))
        width (- wininfo.width wininfo.textoff border-len)
        height (math.min 4 (length args.lines))
        curline (vim.fn.line ".")
        row (if (> (- curline wininfo.topline)
                   (- (+ wininfo.topline wininfo.height) curline))
                (+ wininfo.winbar)
                (- wininfo.height height border-len))]
    {:relative "win"
     :row row
     :col wininfo.textoff
     :width width
     :height height
     :focusable false}))

;;; -> bool
(fn insert-mode? []
  (not= nil (: (. (nvim_get_mode) :mode) :match "^[iR]")))

;;; WinID ->
(fn win-callback [winid]
  (window.set-opt winid "conceallevel" 2)
  ;; What closes the popup depends on the mode it opens in: leaving insert
  ;; mode when it was opened while typing, or the next cursor move when it
  ;; was asked for from normal mode. Recreating the group drops the
  ;; handlers of the previous popup.
  (let [group (nvim_create_augroup "nvlime-arglist" {:clear true})
        close #(window.close-float winid)]
    (if (insert-mode?)
        (nvim_create_autocmd "InsertLeave"
          {: group :callback close :once true})
        (nvim_create_autocmd ["CursorMoved" "InsertEnter" "BufLeave" "WinLeave"]
          {: group :callback close :once true}))))

;;; string -> [WinID BufNr]
(fn arglist.show [content]
  "Opens/updates arglist window."
  (let [lines (ut.text->lines content)
        bufnr (buffer.create-nolisted +bufname+ +filetype+)
        opts (calc-opts {: lines})]
    (buffer.fill! bufnr lines)
    (case (pbuf.visible? bufnr)
      (true winid) (do
                     (window.update-win-options winid opts)
                     [winid bufnr])
      _ [(window.open-float
           bufnr opts false false #(win-callback $1))
         bufnr])))

arglist
