;;; port-eval.el --- Interactive evaluation commands -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Interactive evaluation commands.  Where the result lands depends on
;; `port-eval-display':
;;
;;   `minibuffer'  Send the form through the tool socket and show the
;;                 returned value in the minibuffer (CIDER-style).
;;                 Captured stdout/stderr are still echoed into the
;;                 REPL buffer.
;;
;;   `repl'        The historical Port behavior: send the form through
;;                 the user socket so it appears in the REPL buffer
;;                 with live streaming output.
;;
;;   `both'        Send through the tool socket, but also echo the
;;                 form and the result into the REPL buffer.

;;; Code:

(require 'port-client)
(require 'port-session)
(require 'port-repl)
(require 'port-stacktrace)
(require 'port-tooling)

(declare-function clojure-find-ns "ext:clojure-mode")

(defun port-current-buffer-ns ()
  "Best-effort namespace extraction from the current Clojure source buffer.
Walks to the top of the buffer and matches the first `ns' form
with a regex.  Used as a fallback when `clojure-find-ns' isn't
available (e.g. when only `clojure-ts-mode' is loaded)."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward
           "(ns[ \t\n]+\\([a-zA-Z0-9._/+!?<>=*$&%-]+\\)" nil t)
      (match-string-no-properties 1))))

(defcustom port-eval-display 'minibuffer
  "Where to display the result of interactive evaluation commands.
The commands `port-eval-last-sexp', `port-eval-defun-at-point',
`port-eval-region', and `port-eval-buffer' use this option to
decide where the result lands.

Possible values:

  `minibuffer'  Show the value in the minibuffer (default).  The
                form is evaluated through the tool socket so its
                stdout/stderr are captured and echoed into the
                REPL buffer; only the value itself appears in the
                minibuffer.  No live streaming -- prints arrive
                with the result.

  `repl'        Send the form to the user socket so it appears in
                the REPL buffer as if typed there, with live
                streaming output.  Nothing is shown in the
                minibuffer.  This is the historical Port
                behavior.

  `both'        Like `minibuffer', but additionally echo the form
                into the REPL input area and the result into the
                REPL buffer."
  :type '(choice (const :tag "Minibuffer" minibuffer)
                 (const :tag "REPL buffer" repl)
                 (const :tag "Both" both))
  :group 'port)

(defun port-eval-string (code)
  "Evaluate CODE (a string) according to `port-eval-display'."
  (let* ((session (port-current-session))
         (display port-eval-display))
    (cond
     ((eq display 'repl)
      (port-eval--send-via-repl session code))
     (t
      (let ((ns (port-eval--current-ns session)))
        (when (eq display 'both)
          (port-eval--echo-form session code))
        (port-tooling-user-eval session ns code
                                #'port-eval--display-result))))))

(defun port-eval--current-ns (session)
  "Best-effort namespace name (string) for SESSION's current buffer.
Tries `clojure-find-ns' if loaded (clojure-mode), otherwise our
own regex-based fallback, then the user socket's tracked ns,
then \"user\"."
  (or (and (fboundp 'clojure-find-ns) (clojure-find-ns))
      (port-current-buffer-ns)
      (port-client-current-ns (port-session-user-conn session))
      "user"))

(defun port-eval--echo-form (session code)
  "Echo CODE into SESSION's REPL buffer as if it had been typed there.
Used by the `both' display mode so the form appears in the REPL
even though evaluation is happening on the tool socket."
  (let ((repl (port-session-repl-buffer session)))
    (when (and repl (buffer-live-p repl))
      (with-current-buffer repl
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert code)
          (unless (string-suffix-p "\n" code) (insert "\n"))
          (add-text-properties port-repl-input-start-marker (point)
                               '(read-only t rear-nonsticky (read-only)))
          (set-marker port-repl-prompt-marker (point))
          (set-marker port-repl-input-start-marker (point))
          (setq port-repl-prompt-active-p nil))))))

(defun port-eval--send-via-repl (session code)
  "Send CODE through SESSION's user socket, echoing into the REPL buffer."
  (port-eval--echo-form session code)
  (port-client-send (port-session-user-conn session) code))

(defun port-eval--display-result (result)
  "Render RESULT (the result alist from `port-tooling-user-eval').
Captured stdout/stderr always go to the REPL buffer so prints are
not silently lost.  The value (or error message) is shown in the
minibuffer, and additionally in the REPL when `port-eval-display'
is `both'."
  (let* ((tag (alist-get :tag result))
         (val (alist-get :val result))
         (out (alist-get :out result))
         (err (alist-get :err result))
         (msg (or (alist-get :ex-message result) (alist-get :ex result))))
    (when (and out (not (string-empty-p out)))
      (port-repl-emit-text out 'port-repl-stdout-face))
    (when (and err (not (string-empty-p err)))
      (port-repl-emit-text err 'port-repl-stderr-face))
    (when (eq port-eval-display 'both)
      (port-repl-emit-text
       (format "%s\n" (if (eq tag :err) msg val))
       (if (eq tag :err) 'port-repl-stderr-face 'port-repl-result-face))
      ;; If `port-repl-emit-text' didn't already restore a live
      ;; prompt (i.e. we appended at point-max because the prompt
      ;; was already consumed by `port-eval--echo-form'), drop one
      ;; in now so the next interaction starts cleanly.
      (when-let ((buf (port-session-repl-buffer (port-current-session))))
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (unless port-repl-prompt-active-p
              (port-repl--insert-prompt))))))
    (cond
     ((eq tag :err)
      (port-stacktrace-pop-from-result result)
      (message "%s" (propertize (or msg "<error>") 'face 'error)))
     (t
      (message "=> %s" (port-eval--summary-line val))))))

(defun port-eval--summary-line (val)
  "Return the first line of VAL, marked with an ellipsis if multi-line.
Keeps the minibuffer readable when `clojure.pprint' produces
multi-line output for big values; the full text is still in the
REPL when `port-eval-display' is `both' (and stdout/stderr are
always echoed to the REPL via `:out' / `:err')."
  (let ((nl (and val (string-match "\n" val))))
    (if nl (concat (substring val 0 nl) " …") val)))

;;;###autoload
(defun port-eval-last-sexp ()
  "Send the sexp before point to the prepl."
  (interactive)
  (port-eval-string
   (buffer-substring-no-properties
    (save-excursion (backward-sexp) (point))
    (point))))

;;;###autoload
(defun port-eval-defun-at-point ()
  "Send the top-level form containing point to the prepl."
  (interactive)
  (save-excursion
    (end-of-defun)
    (let ((end (point)))
      (beginning-of-defun)
      (port-eval-string
       (buffer-substring-no-properties (point) end)))))

;;;###autoload
(defun port-eval-region (start end)
  "Send the region between START and END to the prepl."
  (interactive "r")
  (port-eval-string (buffer-substring-no-properties start end)))

;;;###autoload
(defun port-eval-buffer ()
  "Send the entire current buffer to the prepl."
  (interactive)
  (port-eval-region (point-min) (point-max)))

(provide 'port-eval)

;;; port-eval.el ends here
