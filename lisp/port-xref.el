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

(defun port-xref--query (sym ns)
  "Build the Clojure form returning SYM's source location in NS.
The map carries `:file' / `:line' from var metadata, plus `:url'
\(the result of `clojure.java.io/resource' for the file) and
`:contents' \(the slurped string when the URL is a jar URL).  The
URL / contents pair is what makes \\[port-find-definition] work for
vars whose source lives inside a jar."
  (format
   (concat "(when-let [ns (or (find-ns (quote %s)) (find-ns 'user))]"
           "  (when-let [v (try (ns-resolve ns (quote %s))"
           "                    (catch Throwable _ nil))]"
           "    (let [m (meta v)"
           "          file (:file m)"
           "          url  (try (some-> file (clojure.java.io/resource))"
           "                    (catch Throwable _ nil))"
           "          jar? (and url (.startsWith (str url) \"jar:\"))]"
           "      {:name (str (symbol v))"
           "       :file file"
           "       :line (:line m)"
           "       :column (:column m)"
           "       :url (some-> url str)"
           "       :contents (when jar?"
           "                   (try (slurp url)"
           "                        (catch Throwable _ nil)))})))")
   ns sym))

;;;###autoload
(defun port-find-definition (sym)
  "Jump to the definition of SYM, defaulting to the symbol at point."
  (interactive
   (list (or (port-symbol-at-point)
             (read-string "Symbol: "))))
  (unless port-default-session
    (user-error "Port: not connected"))
  (let* ((ns (port-session-current-ns port-default-session))
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
        (port-xref--jump decoded sym)))))))

(defun port-xref--jump (decoded sym)
  "Open the location described by DECODED for SYM.
DECODED is the parsed result map (alist) returned by
`port-xref--query'.  Falls back through: absolute file →
project-relative file → jar URL with embedded contents → message."
  (let ((file     (alist-get :file decoded))
        (line     (alist-get :line decoded))
        (url      (alist-get :url decoded))
        (contents (alist-get :contents decoded)))
    (cond
     ((and file (file-name-absolute-p file) (file-exists-p file))
      (port-xref--visit file line))
     ((and file (file-exists-p (expand-file-name file default-directory)))
      (port-xref--visit (expand-file-name file default-directory) line))
     ((and url (string-prefix-p "jar:" url) contents)
      (port-xref--visit-jar url contents line))
     ((null file)
      (message "Port: no source file recorded for %s" sym))
     (t
      (message "Port: cannot resolve %s to a local file" file)))))

(defun port-xref--visit (file line)
  "Push the current location onto xref's marker stack and visit FILE at LINE."
  (xref-push-marker-stack)
  (find-file file)
  (when line
    (goto-char (point-min))
    (forward-line (1- line))))

(defun port-xref--visit-jar (url contents line)
  "Open a read-only buffer with CONTENTS for the jar URL.
URL is the original `jar:file:.../foo.jar!/inner.clj' string;
LINE is the 1-based line to jump to (or nil)."
  (xref-push-marker-stack)
  (let* ((name (port-xref--jar-buffer-name url))
         (buf  (get-buffer name)))
    (unless buf
      (setq buf (generate-new-buffer name))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert contents))
        (goto-char (point-min))
        (port-xref--enable-clojure-mode)
        (setq buffer-read-only t)
        (set-buffer-modified-p nil)
        (setq-local port-xref--jar-url url)))
    (pop-to-buffer-same-window buf)
    (when line
      (goto-char (point-min))
      (forward-line (1- line)))))

(defun port-xref--enable-clojure-mode ()
  "Enable a Clojure major mode in the current buffer if one is available.
Tries `clojure-ts-mode' first (the tree-sitter mode), then
`clojure-mode'.  Falls through silently when neither is loaded so
the buffer is at least viewable."
  (cond
   ((fboundp 'clojure-ts-mode) (clojure-ts-mode))
   ((fboundp 'clojure-mode)    (clojure-mode))))

(defun port-xref--jar-buffer-name (url)
  "Build a readable buffer name from a jar URL."
  (cond
   ((string-match "/\\([^/]+\\.jar\\)!/\\(.*\\)$" url)
    (format "*port-jar: %s!/%s*"
            (match-string 1 url) (match-string 2 url)))
   (t (format "*port-jar: %s*" url))))

(defvar-local port-xref--jar-url nil
  "URL the current jar-source buffer was opened from, if any.")

(provide 'port-xref)

;;; port-xref.el ends here
