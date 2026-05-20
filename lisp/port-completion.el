;;; port-completion.el --- completion-at-point via the tool socket -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A `completion-at-point-functions' member that resolves Clojure
;; symbols against a running prepl over the tool socket.  The
;; underlying capf API is synchronous, but Port pre-fetches all
;; symbols visible in the buffer's namespace once and filters
;; Elisp-side from the cache on each keystroke.  Under
;; corfu/company-mode auto-popup this means the second character
;; onwards costs nothing on the wire.
;;
;; The cache is keyed by namespace and expires after
;; `port-completion-cache-ttl' seconds; it's also cleared eagerly
;; when `port-load-file' or `port-set-ns' runs (those are the
;; common ways a Port user adds vars or changes namespaces).  When
;; caching is off (`port-completion-use-cache' = nil) we fall back
;; to the old behaviour of issuing one synchronous prefix-filtered
;; query per keystroke.
;;
;; The default server-side form returns a vector of
;; `{:candidate :type :ns}' maps, which lets the capf attach a
;; short annotation (the kind tag plus the source ns) next to each
;; candidate in the corfu/company popup.  Form templates that
;; instead return the legacy newline-joined string of names still
;; render — just without annotations — so any user customisation
;; carried over from earlier versions keeps working.

;;; Code:

(require 'cl-lib)
(require 'port-client)
(require 'port-session)
(require 'port-tooling)

(defcustom port-completion-timeout 2.0
  "Seconds to wait for a completion response from the tool socket."
  :type 'number
  :group 'port)

(defcustom port-completion-form
  (concat "(let [ns (or (find-ns (quote %s)) (find-ns 'user))"
          "      prefix %S]"
          "  (->> (ns-map ns)"
          "       (keep (fn [[s v]]"
          "               (let [n (str s)]"
          "                 (when (.startsWith ^String n prefix)"
          "                   (cond"
          "                     (class? v)"
          "                     {:candidate n :type :class}"
          "                     (var? v)"
          "                     (let [m (meta v)]"
          "                       {:candidate n"
          "                        :type (cond (:macro m)    :macro"
          "                                    (:arglists m) :function"
          "                                    :else         :var)"
          "                        :ns (some-> (:ns m) ns-name str)})"
          "                     :else"
          "                     {:candidate n :type :var})))))"
          "       distinct"
          "       (sort-by :candidate)"
          "       vec))")
  "Format string for the completion query.
The first %s is replaced with the buffer's namespace; %S is
replaced with the typed prefix as a Clojure string literal.  The
form must return either:

- a vector of maps shaped `{:candidate \"name\" :type :function
  :ns \"clojure.core\"}' (the rich shape; `:type' may be one of
  the Compliment kinds: `:function', `:macro', `:var', `:class',
  `:keyword', `:namespace', `:method', `:static-method',
  `:field', `:static-field', `:special-form', `:local'; `:ns' and
  `:arglists' are optional), or
- a newline-joined string of candidate names (legacy shape,
  rendered without annotations).

When `port-completion-use-cache' is non-nil (the default), Port
calls this form once per namespace with prefix=\"\" to fetch the
full symbol list, caches the result, and filters Elisp-side on
each keystroke.  When caching is off, the form is called with the
actual user prefix on every capf invocation.

For richer completion (locals, classes, keywords, java methods)
swap the default for a Compliment-based variant that requires
`compliment.core' and calls `compliment.core/completions' with
the prefix and the buffer ns.  Compliment is on the classpath of
any project pulling in `cider-nrepl' transitively."
  :type 'string :group 'port)

(defcustom port-completion-use-cache t
  "When non-nil, cache per-namespace symbol lists for completion.
The cache is populated lazily on the first capf in a buffer (and,
when a session is live at `port-mode' enable time, eagerly via an
async pre-fetch).  Set to nil to fall back to the historical
behaviour of one synchronous prefix-filtered query per keystroke."
  :type 'boolean :group 'port)

(defcustom port-completion-cache-ttl 10.0
  "Seconds before a cached symbol list for a namespace expires.
Lower values pick up REPL-typed `def's faster; higher values save
round-trips.  The cache is also cleared eagerly by
`port-completion-invalidate' when `port-load-file' or `port-set-ns'
runs.  Set to nil for no expiry (only manual / event-driven
invalidation)."
  :type '(choice number (const :tag "Never expire" nil))
  :group 'port)


;;; Cache

(defvar port-completion--cache (make-hash-table :test 'equal)
  "Per-namespace cache of completion candidate lists.
Keys are namespace strings; values are `(TIMESTAMP . CANDIDATES)'
pairs.  TIMESTAMP is the `float-time' the entry was written; nil
means \"sentinel pending fetch\".  CANDIDATES is either a list of
plain candidate strings (legacy form-template shape) or a list of
`((:candidate . NAME) (:type . KIND) ...)' alists (default rich
shape).")

(defun port-completion--cached-symbols (ns)
  "Return the cached candidate list for NS, or nil when stale/missing.
TTL is `port-completion-cache-ttl'; a nil value disables expiry."
  (when port-completion-use-cache
    (let ((entry (gethash ns port-completion--cache)))
      (when (and entry
                 (consp entry)
                 (car entry)              ; not a pending sentinel
                 (or (null port-completion-cache-ttl)
                     (< (- (float-time) (car entry))
                        port-completion-cache-ttl)))
        (cdr entry)))))

(defun port-completion-candidate-names (ns)
  "Return the cached candidate *names* for NS as a list of strings.
Works regardless of whether the cache holds rich annotation maps
or plain strings.  Used by `port-xref' to drive the
`xref-find-definitions' prompt's completion table."
  (let ((cands (port-completion--cached-symbols ns)))
    (cond
     ((null cands) nil)
     ((stringp (car cands)) cands)
     (t (mapcar #'port-completion--name cands)))))

(defun port-completion--name (cand)
  "Return the candidate name of CAND (a string or an alist)."
  (if (stringp cand) cand (alist-get :candidate cand)))

(defun port-completion--store (ns cands)
  "Store CANDS as the cached candidate list for NS, timestamped now."
  (puthash ns (cons (float-time) cands) port-completion--cache))

(defun port-completion--parse-response (result)
  "Return a candidate list from RESULT, or nil.
RESULT is the alist delivered by `port-tooling-call' /
`port-tooling-call-sync'.  Recognises two shapes:

- a Clojure vector of `{:candidate :type :ns ...}' maps decodes
  to a list of alists; returned verbatim, so the capf can
  attach an `:annotation-function';
- a newline-joined string of names (legacy) decodes to a string;
  split on `\\n' and returned as a list of plain strings (no
  annotations possible from this shape)."
  (when (and result (eq :ok (alist-get :tag result)))
    (let ((decoded (port-tooling-decode-val (alist-get :val result))))
      (cond
       ;; Rich shape: vector of maps → list of alists.
       ((and (consp decoded)
             (consp (car decoded))
             (alist-get :candidate (car decoded)))
        decoded)
       ;; Legacy shape: newline-joined string of names.
       ((and (stringp decoded) (not (string-empty-p decoded)))
        (split-string decoded "\n" t))))))


;;; Query helpers

(defun port-completion--query (prefix ns)
  "Build the Clojure form that lists symbols in NS starting with PREFIX.
Uses `port-completion-form'; the first placeholder is NS, the
second PREFIX."
  (format port-completion-form ns prefix))

(defun port-completion--fetch-and-cache (ns)
  "Synchronously fetch all symbols in NS and cache the result.
Returns the candidate list, or nil on timeout / error.  Issues
`port-completion-form' with an empty prefix so the server-side
filter returns the entire namespace; subsequent capf invocations
filter from the cache on the Elisp side."
  (when port-default-session
    (let* ((form   (port-completion--query "" ns))
           (result (port-tooling-call-sync port-default-session form
                                           port-completion-timeout))
           (cands  (port-completion--parse-response result)))
      (when cands
        (when port-completion-use-cache
          (port-completion--store ns cands))
        cands))))

(defun port-completion--candidates (prefix)
  "Return a candidate list matching PREFIX, or nil.
With caching on, walks the cached candidate list (fetching it
first when the namespace hasn't been seen yet).  With caching
off, issues a sync prefix-filtered query on every call.  Elements
are either strings (legacy form template) or alists carrying
`:candidate' plus annotation fields."
  (when port-default-session
    (let ((ns (port-session-current-ns port-default-session)))
      (cond
       (port-completion-use-cache
        (let ((all (or (port-completion--cached-symbols ns)
                       (port-completion--fetch-and-cache ns))))
          (when all
            (cl-remove-if-not
             (lambda (c) (string-prefix-p prefix (port-completion--name c)))
             all))))
       (t
        (port-completion--parse-response
         (port-tooling-call-sync
          port-default-session
          (port-completion--query prefix ns)
          port-completion-timeout)))))))


;;; Annotation formatting

(defconst port-completion--type-tags
  '((:function      . "f")
    (:macro         . "m")
    (:var           . "v")
    (:class         . "c")
    (:keyword       . "k")
    (:namespace     . "n")
    (:method        . "im")
    (:static-method . "sm")
    (:field         . "if")
    (:static-field  . "sf")
    (:special-form  . "s")
    (:local         . "l")
    (:symbol        . "s")
    (:resource      . "r"))
  "Short tag shown in capf annotations for each Compliment kind.
Letters chosen for visual density in the corfu/company popup;
override `port-completion-format-annotation' to customise.")

(defun port-completion--type-tag (type)
  "Return a short string tag for TYPE (a Compliment kind keyword)."
  (or (alist-get type port-completion--type-tags)
      (and (symbolp type) (substring (symbol-name type) 1 2))
      ""))

(defun port-completion-format-annotation (cand)
  "Default formatter for capf annotations.
CAND is one of the alists returned by the rich form template.
Returns a short string like ` f clojure.core' (note the leading
space — corfu and company both expect annotations to start with
their own separator).  Returns nil when CAND has no usable
metadata."
  (let* ((type (alist-get :type cand))
         (ns   (alist-get :ns cand))
         (tag  (and type (port-completion--type-tag type))))
    (cond
     ((and tag ns (not (string-empty-p tag)))
      (format " %s %s" tag ns))
     ((and tag (not (string-empty-p tag)))
      (format " %s" tag))
     (ns
      (format " %s" ns)))))

(defvar port-completion-annotation-function
  #'port-completion-format-annotation
  "Function (CAND-ALIST) -> string used to render capf annotations.
Called once per rich-shape candidate at popup time.  Receives the
`:candidate'/`:type'/`:ns'/`:arglists' alist as input; should
return a short display string (with the leading space corfu
expects), or nil to omit the annotation.")

(defun port-completion--annot-table (cands)
  "Build a hash table mapping CANDS' candidate names to annotation strings."
  (let ((tbl (make-hash-table :test 'equal)))
    (dolist (c cands)
      (let ((name (port-completion--name c))
            (ann  (and (consp c)
                       port-completion-annotation-function
                       (funcall port-completion-annotation-function c))))
        (when (and name ann)
          (puthash name ann tbl))))
    tbl))


;;; Async pre-fetch + invalidation

(defun port-completion--warm-cache (ns)
  "Asynchronously pre-fetch symbols in NS into the cache.
Used on `port-mode' enable so the first user keystroke already
sees a populated cache.  No-op when caching is disabled, when
there's no session, or when an entry for NS is already cached and
unexpired.  Best-effort: any error from the tool socket (e.g.
the connection isn't live yet) clears the pending sentinel and
silently gives up; a real capf invocation will retry as needed."
  (when (and port-completion-use-cache
             port-default-session
             (null (port-completion--cached-symbols ns))
             ;; Don't fire a second warm-up over an outstanding one.
             (null (gethash ns port-completion--cache)))
    (puthash ns (cons nil nil) port-completion--cache) ; pending sentinel
    (condition-case _
        (port-tooling-call
         port-default-session
         (port-completion--query "" ns)
         (lambda (result)
           (let ((cands (port-completion--parse-response result)))
             (cond
              (cands (port-completion--store ns cands))
              (t     (remhash ns port-completion--cache))))))
      (error (remhash ns port-completion--cache)))))

;;;###autoload
(defun port-completion-invalidate (&optional ns)
  "Invalidate the completion cache.
With NS, drop only that namespace's entry; without, clear
everything.  Called eagerly when `port-load-file' or `port-set-ns'
runs, so newly-defined vars show up immediately rather than waiting
for the TTL."
  (interactive)
  (cond
   (ns (remhash ns port-completion--cache))
   (t  (clrhash port-completion--cache))))

(defalias 'port-completion-clear-cache #'port-completion-invalidate)


;;; capf wiring

;;;###autoload
(defun port-completion-at-point ()
  "`completion-at-point-functions' member for Port-managed buffers."
  (when port-default-session
    (when-let ((bounds (bounds-of-thing-at-point 'symbol)))
      (let* ((start  (car bounds))
             (end    (cdr bounds))
             (prefix (buffer-substring-no-properties start end))
             (raw    (port-completion--candidates prefix)))
        (when raw
          (let* ((rich  (and (consp raw) (consp (car raw))))
                 (names (if rich (mapcar #'port-completion--name raw) raw))
                 (annot (and rich (port-completion--annot-table raw))))
            (append
             (list start end names :exclusive 'no)
             (when (and annot (> (hash-table-count annot) 0))
               (list :annotation-function
                     (lambda (cand) (gethash cand annot)))))))))))

;;;###autoload
(defun port-completion-setup ()
  "Hook `port-completion-at-point' into the current buffer.
Also fires an async cache warm-up for the buffer's namespace when
a session is live, so the first popup avoids the round-trip."
  (add-hook 'completion-at-point-functions
            #'port-completion-at-point nil t)
  (when (and port-default-session
             port-completion-use-cache)
    (port-completion--warm-cache
     (port-session-current-ns port-default-session))))

(defun port-completion-teardown ()
  "Remove `port-completion-at-point' from the current buffer."
  (remove-hook 'completion-at-point-functions
               #'port-completion-at-point t))

(provide 'port-completion)

;;; port-completion.el ends here
