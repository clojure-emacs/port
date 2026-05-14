;;; port-xref.el --- xref backend for Port -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; An `xref-backend-functions' implementation that resolves Clojure
;; symbols against a running prepl over the tool socket.  Installing
;; this backend on a Clojure source buffer means `M-.', `M-,', and the
;; rest of the xref machinery work without Port needing its own
;; command set or keybindings.
;;
;; Two operations are supported: `xref-backend-definitions' (one
;; matching definition per identifier, via `port-xref-form') and
;; `xref-backend-apropos' (matching symbols + locations across loaded
;; namespaces, via `port-xref-apropos-form').  References aren't
;; implemented; finding actual references needs static analysis and
;; clojure-lsp is the right tool for that.
;;
;; The backend is installed by `port-mode' (see `port-xref-setup' /
;; `port-xref-teardown'); the underlying queries block via
;; `port-tooling-call-sync', since the xref API is synchronous.

;;; Code:

(require 'cl-lib)
(require 'port-client)
(require 'port-session)
(require 'port-tooling)
(require 'xref)

(defcustom port-xref-form
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
  "Format string for the find-definition query.
The first %s is replaced with the user-socket namespace, the
second with the symbol being looked up.  The form must return a
map with `:name', `:file', `:line', `:column', `:url', and
optionally `:contents' (slurped source when the file lives inside
a jar URL).  The default relies on `clojure.java.io/resource' and
on `slurp', both JVM-only — non-JVM dialects need a rewrite that
omits the jar branch."
  :type 'string :group 'port)

(defcustom port-xref-apropos-form
  (concat "(let [pat (re-pattern %S)]"
          "  (->> (all-ns)"
          "       (mapcat (fn [ns]"
          "                 (->> (ns-publics ns)"
          "                      (filter (fn [[s _]] (re-find pat (str s))))"
          "                      (keep (fn [[s v]]"
          "                              (let [m (meta v)"
          "                                    f (:file m)"
          "                                    d (:doc m)]"
          "                                (when (and (string? f)"
          "                                           (not (.startsWith f"
          "                                                              \"jar:\")))"
          "                                  {:name (str (ns-name ns) \"/\" s)"
          "                                   :file f"
          "                                   :line (or (:line m) 1)"
          "                                   :doc  (when (string? d)"
          "                                           (subs d 0"
          "                                             (min 80 (count d))))})))))))"
          "       vec))")
  "Format string for the xref-apropos query.
%S is replaced with the search pattern as a Clojure *regex* string
literal (compiled to a regex via `re-pattern' server-side; the
pattern is not anchored, so plain substrings work but regex
metacharacters are honoured).  The form must return a vector of
maps with `:name', `:file', `:line', and optionally `:doc'.
Jar-internal entries are filtered out by the default form because
slurping every jar for an apropos list is too costly to do up front."
  :type 'string :group 'port)

(defcustom port-xref-apropos-timeout 5.0
  "Seconds to wait for an apropos response on the tool socket.
Apropos walks every loaded namespace and can take noticeable time
on a large classpath."
  :type 'number :group 'port)

(defcustom port-xref-definitions-timeout 2.0
  "Seconds to wait for a find-definition response on the tool socket.
A single var-meta lookup is cheap, so the default is short enough
to feel snappy on `M-.' while still tolerating GC pauses."
  :type 'number :group 'port)


;;; Query helpers (also re-used by stacktrace / test buffers)

(defun port-xref--query (sym ns)
  "Build the Clojure form returning SYM's source location in NS.
Uses `port-xref-form'; the first placeholder is NS, the second SYM."
  (format port-xref-form ns sym))

(defun port-xref--apropos-query (pattern)
  "Build the Clojure form returning matches for PATTERN.
Uses `port-xref-apropos-form'; the placeholder is the pattern as
a Clojure string literal."
  (format port-xref-apropos-form pattern))

(defun port-xref--visit (file line)
  "Push the current location onto xref's marker stack and visit FILE at LINE.
Shared utility used by `port-stacktrace' and `port-test' when they
need to jump to a resolved local file, without going through the
full xref backend."
  (xref-push-marker-stack)
  (find-file file)
  (when line
    (goto-char (point-min))
    (forward-line (1- line))))


;;; Jar-source buffers

(defvar-local port-xref--jar-url nil
  "URL the current jar-source buffer was opened from, if any.")

(defun port-xref--jar-buffer-name (url)
  "Build a readable buffer name from a jar URL."
  (cond
   ((string-match "/\\([^/]+\\.jar\\)!/\\(.*\\)$" url)
    (format "*port-jar: %s!/%s*"
            (match-string 1 url) (match-string 2 url)))
   (t (format "*port-jar: %s*" url))))

(defun port-xref--enable-clojure-mode ()
  "Enable a Clojure major mode in the current buffer if one is available.
Tries `clojure-ts-mode' first (the tree-sitter mode), then
`clojure-mode'.  Falls through silently when neither is loaded so
the buffer is at least viewable."
  (cond
   ((fboundp 'clojure-ts-mode) (clojure-ts-mode))
   ((fboundp 'clojure-mode)    (clojure-mode))))

(defun port-xref--get-or-create-jar-buffer (url contents)
  "Return a read-only buffer holding CONTENTS for the jar URL.
Reuses an existing buffer with the same name when one already
exists; the buffer is set up with the appropriate Clojure major
mode and `port-xref--jar-url' recorded for later reference."
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
    buf))


;;; xref backend

;;;###autoload
(defun port-xref-backend ()
  "Return the Port xref backend when a session is live.
Suitable for adding to `xref-backend-functions'."
  (and port-default-session 'port))

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql 'port)))
  "Return the Clojure symbol at point as a string."
  (port-symbol-at-point))

(cl-defmethod xref-backend-identifier-completion-table ((_backend (eql 'port)))
  "Return the completion table for `xref-find-definitions' prompting.
Currently nil: we don't pre-enumerate symbols, so the user types
freely.  Wiring this up against `port-completion-form' would be a
follow-up if symbol listing turns out cheap enough on the prepl."
  nil)

(cl-defmethod xref-backend-definitions ((_backend (eql 'port)) identifier)
  "Return a one-element list of `xref-item' for IDENTIFIER, or nil.
Blocks on the tool socket via `port-tooling-call-sync' for at
most `port-xref-definitions-timeout' seconds."
  (let* ((session (port-current-session))
         (ns      (port-session-current-ns session))
         (form    (port-xref--query identifier ns))
         (result  (port-tooling-call-sync session form
                                          port-xref-definitions-timeout)))
    (cond
     ((null result)
      (message "Port: definition lookup of %s timed out" identifier)
      nil)
     ((not (eq :ok (alist-get :tag result)))
      (message "Port: definition lookup of %s failed: %s"
               identifier (or (alist-get :ex-message result) "unknown error"))
      nil)
     (t
      (let ((decoded (port-tooling-decode-val (alist-get :val result))))
        (cond
         ((null decoded)
          nil)
         ((not (consp decoded))
          nil)
         (t
          (when-let ((item (port-xref--decoded->item identifier decoded)))
            (list item)))))))))

(cl-defmethod xref-backend-references ((_backend (eql 'port)) _identifier)
  "Return nil.  Port doesn't implement reference lookup.
Static call-site analysis isn't something prepl introspection can
deliver well; clojure-lsp (via eglot or lsp-mode) is the supported
path for users who need it.  Returning nil here is important: the
default `xref-backend-references' implementation runs `find | grep'
across the project root *and* every external root, which on a
Clojure classpath means greppping the entire local Maven cache."
  nil)

(cl-defmethod xref-backend-apropos ((_backend (eql 'port)) pattern)
  "Return a list of `xref-item' matching PATTERN across loaded namespaces.
Blocks on the tool socket via `port-tooling-call-sync' with the
larger `port-xref-apropos-timeout', since walking every loaded
namespace can take seconds on a fat classpath."
  (let* ((session (port-current-session))
         (form    (port-xref--apropos-query pattern))
         (result  (port-tooling-call-sync session form
                                          port-xref-apropos-timeout)))
    (cond
     ((null result)
      (message "Port: apropos timed out (try a more specific pattern)")
      nil)
     ((not (eq :ok (alist-get :tag result)))
      (message "Port: apropos failed: %s"
               (or (alist-get :ex-message result) "unknown error"))
      nil)
     (t
      (let ((decoded (port-tooling-decode-val (alist-get :val result))))
        (when (listp decoded)
          (delq nil (mapcar #'port-xref--apropos-row->item decoded))))))))

(defun port-xref--decoded->item (sym decoded)
  "Build an `xref-item' for SYM from DECODED definition map, or nil.
DECODED is the parsed result map of `port-xref-form'.  Returns nil
if no usable location is present.  Jar entries are materialised
into a read-only buffer up front so the resulting location is a
`xref-buffer-location' the xref UI can navigate to directly."
  (let* ((name     (or (alist-get :name decoded) sym))
         (file     (alist-get :file decoded))
         (line     (or (alist-get :line decoded) 1))
         (url      (alist-get :url decoded))
         (contents (alist-get :contents decoded)))
    (cond
     ((and (stringp file) (file-name-absolute-p file) (file-exists-p file))
      (xref-make name (xref-make-file-location file line 0)))
     ((and (stringp file)
           (file-exists-p (expand-file-name file default-directory)))
      (xref-make name (xref-make-file-location
                       (expand-file-name file default-directory) line 0)))
     ((and (stringp url) (string-prefix-p "jar:" url) (stringp contents))
      (let ((buf (port-xref--get-or-create-jar-buffer url contents)))
        (xref-make name
                   (xref-make-buffer-location
                    buf
                    (with-current-buffer buf
                      (save-excursion
                        (goto-char (point-min))
                        (forward-line (1- line))
                        (point)))))))
     (t nil))))

(defun port-xref--apropos-row->item (row)
  "Build an `xref-item' for an apropos ROW (an alist), or nil."
  (let* ((name (alist-get :name row))
         (file (alist-get :file row))
         (line (or (alist-get :line row) 1))
         (doc  (alist-get :doc row))
         (summary (if (and (stringp doc) (not (string-empty-p doc)))
                      (format "%s — %s" name doc)
                    name)))
    (cond
     ((not (stringp file)) nil)
     ((and (file-name-absolute-p file) (file-exists-p file))
      (xref-make summary (xref-make-file-location file line 0)))
     ((file-exists-p (expand-file-name file default-directory))
      (xref-make summary (xref-make-file-location
                          (expand-file-name file default-directory) line 0)))
     (t nil))))


;;; Setup / teardown

(defun port-xref-setup ()
  "Install Port's xref backend on the current buffer.
Called from `port-mode' on enable; adds `port-xref-backend' to a
buffer-local copy of `xref-backend-functions' so it composes with
whatever other backends a major mode has already registered."
  (add-hook 'xref-backend-functions #'port-xref-backend nil t))

(defun port-xref-teardown ()
  "Remove Port's xref backend from the current buffer.
Called from `port-mode' on disable."
  (remove-hook 'xref-backend-functions #'port-xref-backend t))

(provide 'port-xref)

;;; port-xref.el ends here
