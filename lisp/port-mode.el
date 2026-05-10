;;; port-mode.el --- Minor mode and helper commands -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; The Port minor mode provides keybindings for Clojure source buffers
;; (any major mode -- typically `clojure-mode' or `clojure-ts-mode')
;; plus a small set of helper commands implemented entirely by sending
;; Clojure forms to the prepl.  All results land in the REPL buffer.

;;; Code:

(require 'port-client)
(require 'port-session)
(require 'port-tooling)
(require 'port-eval)
(require 'port-repl)
(require 'port-eldoc)
(require 'port-completion)
(require 'port-stacktrace)
(require 'port-xref)

(defun port--symbol-at-point ()
  "Return the symbol at point as a string, or nil."
  (when-let ((sym (thing-at-point 'symbol t)))
    (substring-no-properties sym)))

(defun port--read-symbol (prompt)
  "Prompt with PROMPT for a Clojure symbol, defaulting to the one at point."
  (let ((default (port--symbol-at-point)))
    (read-string
     (if default (format "%s (default %s): " prompt default) (concat prompt ": "))
     nil nil default)))

(defun port--tool-emit (label result)
  "Render RESULT (an alist from `port-tooling-call') into the REPL.
LABEL is shown as a leading comment so the user sees what produced
the output."
  (let ((tag (alist-get :tag result))
        (out (alist-get :out result))
        (err (alist-get :err result)))
    (port-repl-emit-comment label)
    (when (and out (not (string-empty-p out)))
      (port-repl-emit-text out 'port-repl-stdout-face))
    (when (and err (not (string-empty-p err)))
      (port-repl-emit-text err 'port-repl-stderr-face))
    (pcase tag
      (:ok
       (let ((val (alist-get :val result)))
         (when (and val (not (member val '("nil" "\"\"" ""))))
           (port-repl-emit-text val))))
      (:err
       (let ((ex-msg (or (alist-get :ex-message result)
                         (alist-get :ex result))))
         (port-repl-emit-text (format ";; %s\n" ex-msg) 'port-repl-stderr-face)
         (port-stacktrace-pop-from-result result))))))

;;;###autoload
(defun port-doc (sym)
  "Show documentation for SYM via `clojure.repl/doc' on the tool socket."
  (interactive (list (port--read-symbol "Doc")))
  (port-tooling-call
   (port-current-session)
   (format "(with-out-str (clojure.repl/doc %s))" sym)
   (lambda (result) (port--tool-emit (format "doc %s" sym) result))))

;;;###autoload
(defun port-source (sym)
  "Show source for SYM via `clojure.repl/source' on the tool socket."
  (interactive (list (port--read-symbol "Source")))
  (port-tooling-call
   (port-current-session)
   (format "(with-out-str (clojure.repl/source %s))" sym)
   (lambda (result) (port--tool-emit (format "source %s" sym) result))))

;;;###autoload
(defun port-apropos (pattern)
  "Find symbols matching PATTERN via `clojure.repl/apropos' on the tool socket."
  (interactive (list (read-string "Apropos pattern: ")))
  (port-tooling-call
   (port-current-session)
   (format "(clojure.repl/apropos %S)" pattern)
   (lambda (result) (port--tool-emit (format "apropos %s" pattern) result))))

;;;###autoload
(defun port-macroexpand-1 ()
  "Macroexpand the form at point once via the tool socket."
  (interactive)
  (let* ((bounds (bounds-of-thing-at-point 'sexp))
         (form   (buffer-substring-no-properties (car bounds) (cdr bounds))))
    (port-tooling-call
     (port-current-session)
     (format "(macroexpand-1 (quote %s))" form)
     (lambda (result) (port--tool-emit "macroexpand-1" result)))))

;;;###autoload
(defun port-macroexpand ()
  "Fully macroexpand the form at point via the tool socket."
  (interactive)
  (let* ((bounds (bounds-of-thing-at-point 'sexp))
         (form   (buffer-substring-no-properties (car bounds) (cdr bounds))))
    (port-tooling-call
     (port-current-session)
     (format "(clojure.walk/macroexpand-all (quote %s))" form)
     (lambda (result) (port--tool-emit "macroexpand" result)))))

;;;###autoload
(defun port-load-file (file)
  "Load FILE in the running prepl on the user socket.
Loading runs on the user socket because it has visible side effects
on the REPL session (defines vars, switches namespace)."
  (interactive
   (list (read-file-name "Load file: " nil
                         (and buffer-file-name buffer-file-name) t)))
  (when (buffer-modified-p) (save-buffer))
  (port-repl-emit-comment (format "load-file %s" file))
  (port-eval-string (format "(clojure.core/load-file %S)" file)))

;;;###autoload
(defun port-set-ns (ns)
  "Switch the REPL namespace to NS via `in-ns' on the user socket.
This intentionally bypasses `port-eval-display': the tool socket
wraps each eval in `binding' for *ns*, which would unwind the
in-ns immediately, so we must send directly on the user socket
where the namespace actually persists."
  (interactive
   (list (read-string "Namespace: "
                      (or (port-current-buffer-ns) "user"))))
  (port-eval--send-via-repl (port-current-session)
                            (format "(in-ns '%s)" ns)))

;;;###autoload
(defun port-switch-to-repl ()
  "Pop to the active REPL buffer."
  (interactive)
  (if-let ((session port-default-session)
           (buf     (port-session-repl-buffer session)))
      (pop-to-buffer buf)
    (user-error "Port: not connected")))

(defvar port-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-e") #'port-eval-last-sexp)
    (define-key map (kbd "C-c C-c") #'port-eval-defun-at-point)
    (define-key map (kbd "C-c C-r") #'port-eval-region)
    (define-key map (kbd "C-c C-k") #'port-eval-buffer)
    (define-key map (kbd "C-c C-l") #'port-load-file)
    (define-key map (kbd "C-c C-d") #'port-doc)
    (define-key map (kbd "C-c C-s") #'port-source)
    (define-key map (kbd "C-c C-m") #'port-macroexpand-1)
    (define-key map (kbd "C-c M-n") #'port-set-ns)
    (define-key map (kbd "C-c C-z") #'port-switch-to-repl)
    (define-key map (kbd "M-.")     #'port-find-definition)
    map)
  "Keymap for `port-mode'.")

;;;###autoload
(define-minor-mode port-mode
  "Minor mode for interacting with a Clojure prepl via Port."
  :init-value nil
  :lighter " Port"
  :keymap port-mode-map
  :group 'port
  (cond
   (port-mode
    (port-eldoc-setup)
    (port-completion-setup))
   (t
    (port-eldoc-teardown)
    (port-completion-teardown))))

(provide 'port-mode)

;;; port-mode.el ends here
