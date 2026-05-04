;;; port-mode.el --- Minor mode and helper commands -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; The Port minor mode provides keybindings for `clojure-mode' buffers
;; plus a small set of helper commands implemented entirely by sending
;; Clojure forms to the prepl.  All results land in the REPL buffer.

;;; Code:

(require 'port-client)
(require 'port-eval)
(require 'port-repl)

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

;;;###autoload
(defun port-doc (sym)
  "Show documentation for SYM via `clojure.repl/doc'."
  (interactive (list (port--read-symbol "Doc")))
  (port-repl-emit-comment (format "doc %s" sym))
  (port-eval-string (format "(clojure.repl/doc %s)" sym)))

;;;###autoload
(defun port-source (sym)
  "Show source for SYM via `clojure.repl/source'."
  (interactive (list (port--read-symbol "Source")))
  (port-repl-emit-comment (format "source %s" sym))
  (port-eval-string (format "(clojure.repl/source %s)" sym)))

;;;###autoload
(defun port-apropos (pattern)
  "Find symbols matching PATTERN via `clojure.repl/apropos'."
  (interactive (list (read-string "Apropos pattern: ")))
  (port-eval-string (format "(clojure.repl/apropos %S)" pattern)))

;;;###autoload
(defun port-macroexpand-1 ()
  "Macroexpand the form at point once."
  (interactive)
  (let* ((bounds (bounds-of-thing-at-point 'sexp))
         (form   (buffer-substring-no-properties (car bounds) (cdr bounds))))
    (port-repl-emit-comment "macroexpand-1")
    (port-eval-string (format "(macroexpand-1 (quote %s))" form))))

;;;###autoload
(defun port-macroexpand ()
  "Fully macroexpand the form at point."
  (interactive)
  (let* ((bounds (bounds-of-thing-at-point 'sexp))
         (form   (buffer-substring-no-properties (car bounds) (cdr bounds))))
    (port-repl-emit-comment "macroexpand")
    (port-eval-string (format "(clojure.walk/macroexpand-all (quote %s))" form))))

;;;###autoload
(defun port-load-file (file)
  "Load FILE in the running prepl via `clojure.core/load-file'."
  (interactive
   (list (read-file-name "Load file: " nil
                         (and buffer-file-name buffer-file-name) t)))
  (when (buffer-modified-p) (save-buffer))
  (port-repl-emit-comment (format "load-file %s" file))
  (port-eval-string (format "(clojure.core/load-file %S)" file)))

;;;###autoload
(defun port-set-ns (ns)
  "Switch the REPL namespace to NS via `in-ns'."
  (interactive
   (list (read-string "Namespace: "
                      (or (port--current-buffer-ns) "user"))))
  (port-eval-string (format "(in-ns '%s)" ns)))

(defun port--current-buffer-ns ()
  "Best-effort namespace extraction from the current Clojure buffer."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward
           "(ns[ \t\n]+\\([a-zA-Z0-9._/+!?<>=*$&%-]+\\)" nil t)
      (match-string-no-properties 1))))

;;;###autoload
(defun port-switch-to-repl ()
  "Pop to the active REPL buffer."
  (interactive)
  (if-let ((conn port-client-default-connection)
           (buf  (port-client-repl-buffer conn)))
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
    map)
  "Keymap for `port-mode'.")

;;;###autoload
(define-minor-mode port-mode
  "Minor mode for interacting with a Clojure prepl via Port."
  :init-value nil
  :lighter " Port"
  :keymap port-mode-map
  :group 'port)

(provide 'port-mode)

;;; port-mode.el ends here
