;;; port-eldoc.el --- Eldoc support via the tool socket -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Show the arglist (and first line of the docstring) for the function
;; whose call surrounds point.  Implemented via
;; `eldoc-documentation-functions' (Emacs 28+) with the async callback
;; form: a request goes out on the tool socket and the result is
;; delivered to eldoc when it returns, so the editor never blocks.
;;
;; The default server-side form returns a small map of `:name',
;; `:arglists', and (when present) `:doc'.  On the Elisp side we parse
;; the Clojure-shape arglists, pick the arity matching the current
;; argument position, and highlight the active parameter with
;; `eldoc-highlight-function-argument'.  Form templates that return a
;; plain string (e.g. the older Orchard variant) still render — just
;; without highlighting — so customisations stay backward compatible.

;;; Code:

(require 'cl-lib)
(require 'port-client)
(require 'port-session)
(require 'port-tooling)

(defcustom port-eldoc-form
  (concat "(when-let [ns (or (find-ns (quote %s)) (find-ns 'user))]"
          " (when-let [v (try (ns-resolve ns (quote %s))"
          "                   (catch Throwable _ nil))]"
          "  (let [m (meta v)]"
          "   (when (:arglists m)"
          "    {:name (str (symbol v))"
          "     :arglists (pr-str (:arglists m))"
          "     :doc (when-let [d (:doc m)]"
          "            (when (string? d)"
          "              (subs d 0 (min 80 (count d)))))}))))")
  "Format string for the eldoc query.
The first %s is replaced with the user-socket namespace; the
second with the symbol whose arglists are being looked up.  The
form must return either:

- a map with `:name', `:arglists' (a printed Clojure arglist like
  `\"([a b])\"' or `\"([] [a] [a b])\"'), and optionally `:doc'
  (a short docstring excerpt), or
- a plain string to be displayed verbatim (legacy/3rd-party form
  templates), or
- nil to indicate \"no eldoc to show\".

The Elisp side parses the arglist on receipt and highlights the
active parameter."
  :type 'string :group 'port)

(defvar port-eldoc-arg-index-function #'port-eldoc--current-arg-index
  "Function returning the 0-indexed arg position at point, or nil.
Called with no arguments.  The default works for any Lisp-flavored
major mode via `forward-sexp'; replace it for languages where
argument boundaries aren't sexps.")

(defvar port-eldoc-arglist-formatter #'port-eldoc-format-lispy-arglist
  "Function (INFO ARG-INDEX) -> string, or nil to skip display.
INFO is an alist with `:name', `:arglists', and optionally `:doc';
ARG-INDEX is the 0-based position the user is currently typing
into, or nil when unknown.  The default expects Clojure/Lisp-shape
arglists; override for servers reporting arglists in a different
syntax.")


;;; Target + arg-index detection

(defun port-eldoc--target ()
  "Return the symbol eldoc should look up around point, or nil.
Prefers the symbol at point; if there isn't one (point is in
whitespace inside a form, e.g. `(str |)') falls back to the head
of the enclosing list so eldoc shows the arglist for the call
being constructed.  Walks outward as far as needed, which gives
sensible results in nested calls: from `(str (sub |))' you get
`sub'."
  (or (port-symbol-at-point)
      (save-excursion
        (let ((parse (syntax-ppss)))
          (when (nth 1 parse)
            (goto-char (1+ (nth 1 parse)))
            (port-symbol-at-point))))))

(defun port-eldoc--current-arg-index ()
  "Return the 0-indexed arg position at point in the enclosing call.
Returns nil when point isn't inside a call.  Walks via
`forward-sexp', so it follows the buffer's syntax table and works
in any Lisp-flavored major mode."
  (save-excursion
    (let ((origin (point)))
      (when (ignore-errors (backward-up-list) t)
        (forward-char 1)
        (when (ignore-errors (forward-sexp 1) t) ; past the head
          (let ((idx 0))
            (while (let ((before (point)))
                     (and (ignore-errors (forward-sexp 1) t)
                          (> (point) before)
                          (<= (point) origin)))
              (cl-incf idx))
            idx))))))

(defun port-eldoc--user-ns ()
  "Return the current namespace of the active session's user socket."
  (if port-default-session
      (port-session-current-ns port-default-session)
    "user"))

(defun port-eldoc--query (sym ns)
  "Build the Clojure form that resolves SYM in NS.
Uses `port-eldoc-form' as the template; the first placeholder is
the namespace, the second the symbol."
  (format port-eldoc-form ns sym))


;;; Arglist parsing + highlighting

(defun port-eldoc--parse-arglist (arglist-str)
  "Parse a Clojure/Lisp-shape ARGLIST-STR into a list of arities.
Each arity is a list of param tokens (strings); `&' is kept as
its own token.  Returns nil if parsing fails (e.g. destructuring
forms containing maps), in which case the caller should fall back
to the raw string."
  (ignore-errors
    (let* ((s (replace-regexp-in-string "\\[" "(" arglist-str))
           (s (replace-regexp-in-string "\\]" ")" s))
           (form (car (read-from-string s))))
      (cond
       ;; `[]' -> nil; treat as a single empty arity.
       ((null form) '(()))
       ;; `([] [x] ...)' -> every element is a list (nil counts).
       ((cl-every #'listp form)
        (mapcar (lambda (a) (mapcar #'symbol-name a)) form))
       ;; `[f coll]' -> flat list of symbols.
       ((consp form)
        (list (mapcar #'symbol-name form)))))))

(defun port-eldoc--pick-arity (arities arg-index)
  "Return the arity in ARITIES that best matches ARG-INDEX, or nil."
  (cl-find-if
   (lambda (arity)
     (let ((amp (cl-position "&" arity :test #'equal)))
       (if amp
           (>= arg-index amp)
         (< arg-index (length arity)))))
   arities))

(defun port-eldoc--render-arity (arity highlight-pos)
  "Render ARITY as `[a b c]', wrapping the param at HIGHLIGHT-POS in a face.
HIGHLIGHT-POS of -1 disables highlighting."
  (let ((i 0))
    (concat "["
            (mapconcat
             (lambda (p)
               (prog1
                   (if (= i highlight-pos)
                       (propertize p 'face
                                   'eldoc-highlight-function-argument)
                     p)
                 (cl-incf i)))
             arity " ")
            "]")))

(defun port-eldoc--highlight-arglist (arglist-str arg-index)
  "Return ARGLIST-STR with the param at ARG-INDEX highlighted.
Falls back to the original string when parsing fails or no arity
fits ARG-INDEX (e.g. user has typed more args than any arity
takes)."
  (or (when (and arglist-str arg-index)
        (let ((arities (port-eldoc--parse-arglist arglist-str)))
          (when arities
            (let ((chosen (port-eldoc--pick-arity arities arg-index)))
              (when chosen
                (let* ((amp (cl-position "&" chosen :test #'equal))
                       (hi (cond
                            ((and amp (>= arg-index amp)) (1+ amp))
                            (t (min arg-index (1- (length chosen))))))
                       (parts (mapcar
                               (lambda (a)
                                 (port-eldoc--render-arity
                                  a (if (eq a chosen) hi -1)))
                               arities)))
                  (if (= (length arities) 1)
                      (car parts)
                    (concat "(" (mapconcat #'identity parts " ") ")"))))))))
      arglist-str))

(defun port-eldoc-format-lispy-arglist (info arg-index)
  "Default `port-eldoc-arglist-formatter'.
Formats INFO's `:name', `:arglists', and `:doc' for eldoc display,
with the param at ARG-INDEX highlighted when given.  INFO is an
alist as produced by the default `port-eldoc-form'."
  (let* ((name     (alist-get :name info))
         (arglists (alist-get :arglists info))
         (doc      (alist-get :doc info))
         (styled   (and arglists
                        (port-eldoc--highlight-arglist arglists arg-index)))
         (first-doc-line (and (stringp doc)
                              (car (split-string doc "\n")))))
    (cond
     ((and name styled first-doc-line)
      (format "%s: %s — %s" name styled first-doc-line))
     ((and name styled) (format "%s: %s" name styled))
     ((and styled first-doc-line) (format "%s: %s" styled first-doc-line))
     (styled styled)
     (first-doc-line first-doc-line))))


;;; Eldoc backend

;;;###autoload
(defun port-eldoc-function (callback &rest _ignored)
  "Async eldoc function suitable for `eldoc-documentation-functions'.
Returns non-nil when a request was dispatched, so eldoc knows to
wait for CALLBACK rather than fall through to the next function.

The dispatched form returns either a map (the default shape, used
for arg-position-aware highlighting) or a plain string (legacy
shape, rendered verbatim)."
  (when port-default-session
    (when-let ((sym (port-eldoc--target)))
      (let ((arg-index (funcall port-eldoc-arg-index-function)))
        (port-tooling-call
         port-default-session
         (port-eldoc--query sym (port-eldoc--user-ns))
         (lambda (result)
           (when (eq (alist-get :tag result) :ok)
             (let ((decoded (port-tooling-decode-val
                             (alist-get :val result))))
               (when-let ((str (port-eldoc--format decoded arg-index)))
                 (funcall callback str
                          :thing sym
                          :face 'font-lock-function-name-face))))))
        t))))

(defun port-eldoc--format (decoded arg-index)
  "Turn DECODED (a map or string) into an eldoc display string, or nil.
Maps go through `port-eldoc-arglist-formatter' with ARG-INDEX so the
active parameter can be highlighted; strings pass through verbatim
\(ARG-INDEX is unused in that branch)."
  (cond
   ((null decoded) nil)
   ((stringp decoded) decoded)
   ((consp decoded)
    (and port-eldoc-arglist-formatter
         (funcall port-eldoc-arglist-formatter decoded arg-index)))))

;;;###autoload
(defun port-eldoc-setup ()
  "Hook `port-eldoc-function' into the current buffer's eldoc."
  (add-hook 'eldoc-documentation-functions #'port-eldoc-function nil t))

(defun port-eldoc-teardown ()
  "Remove `port-eldoc-function' from the current buffer's eldoc."
  (remove-hook 'eldoc-documentation-functions #'port-eldoc-function t))

(provide 'port-eldoc)

;;; port-eldoc.el ends here
