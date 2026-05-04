;;; port-xref.el --- Jump to definitions via the tool socket -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Resolves the symbol at point to its source file and line via the
;; tool socket, then visits the file.  Handles absolute paths and
;; paths relative to the buffer's directory.  Source inside jars is
;; not supported yet.

;;; Code:

(require 'port-client)
(require 'port-session)
(require 'port-tooling)
(require 'xref)

(defun port-xref--symbol-at-point ()
  "Return the symbol at point as a string, or nil."
  (when-let ((s (thing-at-point 'symbol t)))
    (substring-no-properties s)))

(defun port-xref--query (sym ns)
  "Build the Clojure form that returns SYM's source location in NS."
  (format
   (concat "(when-let [ns (or (find-ns (quote %s)) (find-ns 'user))]"
           "  (when-let [v (try (ns-resolve ns (quote %s))"
           "                    (catch Throwable _ nil))]"
           "    (let [m (meta v)]"
           "      {:name (str (symbol v))"
           "       :file (:file m)"
           "       :line (:line m)"
           "       :column (:column m)})))")
   ns sym))

;;;###autoload
(defun port-find-definition (sym)
  "Jump to the definition of SYM, defaulting to the symbol at point."
  (interactive
   (list (or (port-xref--symbol-at-point)
             (read-string "Symbol: "))))
  (unless port-default-session
    (user-error "Port: not connected"))
  (let* ((ns (or (port-client-current-ns
                  (port-session-user-conn port-default-session))
                 "user"))
         (form (port-xref--query sym ns)))
    (port-tooling-call
     port-default-session form
     (lambda (result) (port-xref--handle-result sym result)))))

(defun port-xref--handle-result (sym result)
  "Dispatch on RESULT for SYM lookup: jump or message."
  (cond
   ((not (eq :ok (alist-get :tag result)))
    (message "Port: lookup of %s failed: %s"
             sym (or (alist-get :ex result) "unknown error")))
   (t
    (let ((decoded (port-tooling-decode-val (alist-get :val result))))
      (cond
       ((null decoded)
        (message "Port: no definition found for %s" sym))
       ((not (consp decoded))
        (message "Port: unexpected response for %s: %S" sym decoded))
       (t
        (port-xref--jump (alist-get :file decoded)
                         (alist-get :line decoded)
                         sym)))))))

(defun port-xref--jump (file line sym)
  "Visit FILE at LINE if locally accessible; otherwise message about SYM."
  (cond
   ((null file)
    (message "Port: no source file recorded for %s" sym))
   ((file-name-absolute-p file)
    (if (file-exists-p file)
        (port-xref--visit file line)
      (message "Port: source file %s is not locally accessible" file)))
   (t
    (let ((candidate (expand-file-name file default-directory)))
      (if (file-exists-p candidate)
          (port-xref--visit candidate line)
        (message "Port: cannot resolve %s to a local file (jar source not yet supported)"
                 file))))))

(defun port-xref--visit (file line)
  "Push the current location onto xref's marker stack and visit FILE at LINE."
  (xref-push-marker-stack)
  (find-file file)
  (when line
    (goto-char (point-min))
    (forward-line (1- line))))

(provide 'port-xref)

;;; port-xref.el ends here
