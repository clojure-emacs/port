;;; port-eval.el --- Interactive evaluation commands -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Interactive evaluation commands.  Forms are sent to the active prepl
;; via the REPL buffer; all output (return value, stdout, stderr) is
;; rendered into the REPL buffer, in monroe style.

;;; Code:

(require 'port-client)
(require 'port-session)
(require 'port-repl)

(defun port-eval-string (code)
  "Send CODE (a string) to the active prepl user socket.
The code is rendered into the REPL buffer as if typed there."
  (let* ((session (port-current-session))
         (conn    (port-session-user-conn session))
         (repl    (port-session-repl-buffer session)))
    (when (and repl (buffer-live-p repl))
      (with-current-buffer repl
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert code)
          (insert "\n")
          (add-text-properties port-repl-input-start-marker (point)
                               '(read-only t
                                 rear-nonsticky (read-only))))))
    (port-client-send conn code)))

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
