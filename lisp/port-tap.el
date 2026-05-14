;;; port-tap.el --- Tap history buffer -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A dedicated buffer that accumulates values published via `tap>'.
;; `io-prepl' already turns each `tap>' call into a `:tag :tap'
;; message on the user socket; Port renders a one-line preview in
;; the REPL buffer and also appends the full value here.

;;; Code:

(require 'cl-lib)

(defcustom port-tap-buffer-name "*port-taps*"
  "Name of the buffer that accumulates tapped values."
  :type 'string
  :group 'port)

(defcustom port-tap-auto-show t
  "When non-nil, display the tap buffer when a new tap arrives.
The buffer is shown via `display-buffer', which respects user
display rules; existing windows are reused rather than stolen."
  :type 'boolean
  :group 'port)

(defcustom port-tap-max-entries 100
  "Cap on entries kept in the tap buffer; oldest are trimmed.
Set to nil for no limit."
  :type '(choice integer (const :tag "Unlimited" nil))
  :group 'port)

(defface port-tap-divider-face
  '((t :inherit shadow))
  "Face for divider headers between tap entries."
  :group 'port)

(defvar port-tap--entry-count 0
  "Number of entries currently held in the tap buffer.")

(defun port-tap--buffer ()
  "Return the tap buffer, creating it if needed."
  (or (get-buffer port-tap-buffer-name)
      (with-current-buffer (get-buffer-create port-tap-buffer-name)
        (cond
         ((fboundp 'clojure-ts-mode) (clojure-ts-mode))
         ((fboundp 'clojure-mode)    (clojure-mode)))
        (setq-local truncate-lines nil)
        (read-only-mode 1)
        (current-buffer))))

(defun port-tap--trim ()
  "Drop the oldest entry when `port-tap-max-entries' is exceeded."
  (when (and port-tap-max-entries
             (> port-tap--entry-count port-tap-max-entries))
    (with-current-buffer (port-tap--buffer)
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-min))
          ;; Skip past the first divider line, then delete up to (and
          ;; including) the blank line preceding the next divider.
          (forward-line 1)
          (if (re-search-forward "^;; tap @" nil t)
              (delete-region (point-min) (line-beginning-position))
            ;; Only one entry; nothing to trim.
            (goto-char (point-min))))))
    (cl-decf port-tap--entry-count)))

(defun port-tap-append (val)
  "Append VAL — a printed Clojure value as a string — to the tap buffer."
  (let ((buf (port-tap--buffer))
        (header (format ";; tap @ %s\n" (format-time-string "%H:%M:%S"))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (unless (bobp) (insert "\n"))
        (insert (propertize header 'face 'port-tap-divider-face))
        (insert val)
        (unless (string-suffix-p "\n" val) (insert "\n"))
        ;; Reindent the inserted value so single-line pr-str output
        ;; from a connect-mode (non-pprint) prepl becomes navigable.
        (when (derived-mode-p 'clojure-mode 'clojure-ts-mode)
          (save-excursion
            (let ((end (point)))
              (re-search-backward "^;; tap @" nil t)
              (forward-line 1)
              (indent-region (point) end))))))
    (cl-incf port-tap--entry-count)
    (port-tap--trim)
    (when port-tap-auto-show (display-buffer buf))))

;;;###autoload
(defun port-show-taps ()
  "Pop to the tap history buffer, creating it if needed."
  (interactive)
  (pop-to-buffer (port-tap--buffer)))

;;;###autoload
(defun port-clear-taps ()
  "Erase the contents of the tap history buffer."
  (interactive)
  (with-current-buffer (port-tap--buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)))
  (setq port-tap--entry-count 0))

(provide 'port-tap)

;;; port-tap.el ends here
