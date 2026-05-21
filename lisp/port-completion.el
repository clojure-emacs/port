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
;; The default server-side form returns a tab- and newline-delimited
;; string (`"name\tCODE\tns\nname\t..."'), which the Elisp side splits
;; without any EDN allocation per candidate.  CODE is a short type
;; tag (`f' / `m' / `v' / `c') that the capf turns into a Compliment
;; kind keyword and uses for the annotation column in the
;; corfu/company popup.  Two other shapes still parse for backward
;; compatibility: the Compliment / Orchard rich shape (a vector of
;; `{:candidate :type :ns}' maps) and the oldest newline-only
;; string-of-names shape; neither is emitted by the default form.

;;; Code:

(require 'cl-lib)
(require 'port-client)
(require 'port-session)
(require 'port-tooling)

(defcustom port-completion-timeout 2.0
  "Seconds to wait for a completion response from the tool socket."
  :type 'number
  :group 'port)

(defconst port-completion--default-form
  (concat "(let [ns (or (find-ns (quote %s)) (find-ns 'user))"
          "      prefix %S]"
          "  (->> (ns-map ns)"
          "       (keep (fn [[s v]]"
          "               (let [n (str s)]"
          "                 (when (.startsWith ^String n prefix)"
          "                   (cond"
          "                     (class? v)"
          "                     (str n \"\\tc\\t\")"
          "                     (var? v)"
          "                     (let [m  (meta v)"
          "                           t  (cond (:macro m)    \"m\""
          "                                    (:arglists m) \"f\""
          "                                    :else         \"v\")"
          "                           vn (some-> (:ns m) ns-name str)]"
          "                       (str n \"\\t\" t \"\\t\" (or vn \"\")))"
          "                     :else"
          "                     (str n \"\\tv\\t\"))))))"
          "       distinct"
          "       sort"
          "       (clojure.string/join \"\\n\")))")
  "The default value of `port-completion-form'.
Pinned to a `defconst' so `port-completion--two-tier-p' can
detect whether the user has customized the form via a cheap
`eq'-fast `equal' check instead of round-tripping through
`get'/`eval' on every capf invocation.")

(defcustom port-completion-form port-completion--default-form
  "Format string for the completion query.
The first %s is replaced with the buffer's namespace; %S is
replaced with the typed prefix as a Clojure string literal.  The
form must return one of three shapes (the parser auto-detects):

- a tab- and newline-delimited string `\"name\\tCODE\\tns\\nname\\t...\"'
  (the default; CODE is a short type tag like `f', `m', `v', `c'
  per `port-completion--type-tags').  This is the fast path: no
  EDN allocation per candidate, just `split-string';

- a vector of maps shaped `{:candidate \"name\" :type :function
  :ns \"clojure.core\"}' (the Compliment / Orchard shape; `:type'
  is a Compliment kind keyword, `:ns' and `:arglists' optional);

- a newline-joined string of candidate names (oldest legacy
  shape, rendered without annotations).

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

(defcustom port-completion-use-core-cache t
  "When non-nil, cache symbols from `port-completion-core-namespaces' globally.
The core cache is fetched once per session and never expires
\(refresh manually via `port-completion-refresh-core').  Per-ns
queries skip these symbols server-side, so each per-ns response
shrinks from \"everything visible in this ns\" to just the
ns-local vars plus non-core requires — typically 10-100x smaller
in projects that mostly use `clojure.core'.

Only effective when `port-completion-use-cache' is non-nil and
the unmodified `port-completion-local-form' is in use; custom
forms (e.g. the Compliment override installed by
`port-enable-orchard') bypass the two-tier path automatically."
  :type 'boolean :group 'port)

(defcustom port-completion-core-namespaces
  '("clojure.core")
  "Namespaces whose public vars populate the global core cache.
Treated as immutable for the life of the session: the cache is
populated once and never expires.  Refresh manually via
`port-completion-refresh-core' after a hot-reload of one of
these.  Adding more namespaces here makes the core fetch heavier
but lets you skip more symbols on every per-ns query — useful
when your project ns's reliably alias the same stdlib set."
  :type '(repeat string) :group 'port)

(defcustom port-completion-core-form
  (concat "(let [core-nses %s]"
          "  (->> core-nses"
          "       (mapcat (fn [nsname]"
          "                 (when-let [ns (find-ns (symbol nsname))]"
          "                   (for [[s v] (ns-publics ns)"
          "                         :when (var? v)]"
          "                     (let [n (str s)"
          "                           m (meta v)"
          "                           t (cond (:macro m)    \"m\""
          "                                   (:arglists m) \"f\""
          "                                   :else         \"v\")]"
          "                       (str n \"\\t\" t \"\\t\" nsname))))))"
          "       distinct"
          "       sort"
          "       (clojure.string/join \"\\n\")))")
  "Format string for the core-cache query.
The single %s placeholder is replaced with a Clojure-syntax
vector of ns-name strings, e.g. `[\"clojure.core\"]'.  The form
must return the same tab/newline-delimited shape as
`port-completion-form'."
  :type 'string :group 'port)

(defcustom port-completion-local-form
  (concat "(let [ns (or (find-ns (quote %s)) (find-ns 'user))"
          "      prefix %S"
          "      core-nses %s]"
          "  (->> (ns-map ns)"
          "       (keep (fn [[s v]]"
          "               (let [n (str s)]"
          "                 (when (.startsWith ^String n prefix)"
          "                   (cond"
          "                     (class? v)"
          "                     (str n \"\\tc\\t\")"
          "                     (var? v)"
          "                     (let [m  (meta v)"
          "                           vn (some-> (:ns m) ns-name str)"
          "                           t  (cond (:macro m)    \"m\""
          "                                    (:arglists m) \"f\""
          "                                    :else         \"v\")]"
          "                       (when-not (contains? core-nses vn)"
          "                         (str n \"\\t\" t \"\\t\" (or vn \"\"))))"
          "                     :else"
          "                     (str n \"\\tv\\t\"))))))"
          "       distinct"
          "       sort"
          "       (clojure.string/join \"\\n\")))")
  "Format string for the per-namespace query in two-tier mode.
Three placeholders: %s ns, %S prefix, %s core-ns set literal
\(e.g. `#{\"clojure.core\"}').  Same return shape as
`port-completion-form'; vars whose source ns is in the core set
are dropped server-side."
  :type 'string :group 'port)


;;; Type tags

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

(defconst port-completion--type-keyword-by-code
  (mapcar (lambda (pair) (cons (cdr pair) (car pair)))
          port-completion--type-tags)
  "Inverse of `port-completion--type-tags' keyed by short code.
Used by `port-completion--decode-row' to recover the Compliment
kind keyword from the wire-format code.  Codes that collide
\(e.g. `s' for both `:special-form' and `:symbol') resolve to
whichever appears first in `port-completion--type-tags' — the
default form only emits f/m/v/c, so collisions don't bite in
practice.")

(defun port-completion--type-tag (type)
  "Return a short string tag for TYPE (a Compliment kind keyword)."
  (or (alist-get type port-completion--type-tags)
      (and (symbolp type) (substring (symbol-name type) 1 2))
      ""))

(defun port-completion--decode-row (row)
  "Decode one tab-delimited ROW into a candidate alist (or plain name).
ROW is `\"name\\tCODE\\tns\"' as emitted by the default
`port-completion-form'.  Missing CODE and NS both decode to a
plain string candidate.  Returns nil when the name field is
empty — an empty candidate name would shadow every core entry
under `port-completion--merge-with-core'."
  (let* ((parts (split-string row "\t"))
         (name  (nth 0 parts))
         (code  (nth 1 parts))
         (ns    (nth 2 parts))
         (has-code (and code (not (string-empty-p code))))
         (has-ns   (and ns   (not (string-empty-p ns)))))
    (cond
     ((or (null name) (string-empty-p name)) nil)
     ((and (not has-code) (not has-ns)) name)
     (t
      (let ((alist (list (cons :candidate name))))
        (when has-code
          (push (cons :type
                      (or (alist-get code port-completion--type-keyword-by-code
                                     nil nil #'equal)
                          ;; Forward-compat: unknown code passes through
                          ;; as `:CODE' so a custom annotation function
                          ;; can still match on it.
                          (intern (concat ":" code))))
                alist))
        (when has-ns
          (push (cons :ns ns) alist))
        (nreverse alist))))))


;;; Cache

(defvar port-completion--cache (make-hash-table :test 'equal)
  "Per-namespace cache of completion candidate lists.
Keys are namespace strings; values are `(TIMESTAMP . CANDIDATES)'
pairs.  TIMESTAMP is the `float-time' the entry was written; nil
means \"sentinel pending fetch\".  CANDIDATES is either a list of
plain candidate strings (legacy form-template shape) or a list of
`((:candidate . NAME) (:type . KIND) ...)' alists (default rich
shape).  In two-tier mode this holds only the per-ns local set;
the core set lives in `port-completion--core-cache' and gets
merged on read.")

(defvar port-completion--core-cache nil
  "Cached candidate list for `port-completion-core-namespaces'.
Populated once per session by `port-completion--fetch-core' (sync
or async) and never expires automatically.  Cleared by
`port-completion-refresh-core' or `port-completion-invalidate'
with no argument.  When nil and two-tier mode is active, the
per-ns merge falls back to just the local list — completion still
works, just without the core symbols.")

(defvar port-completion--core-cache-pending nil
  "Non-nil while an async core-cache fetch is in flight.
Prevents stacking warm-ups when multiple `port-mode' buffers light
up in quick succession.")

(defun port-completion--two-tier-p ()
  "Return non-nil when the two-tier cache path should be used.
Off when caching is disabled wholesale, when the user has flipped
`port-completion-use-core-cache' off, or when the per-ns form has
been customized away from the default (e.g. Compliment) — in that
case `port-completion-form' is the source of truth and the
two-tier filter would silently drop symbols the custom form
expects to see."
  (and port-completion-use-cache
       port-completion-use-core-cache
       port-completion-core-namespaces
       (equal port-completion-form port-completion--default-form)))

(defun port-completion--core-set-literal ()
  "Render `port-completion-core-namespaces' as a Clojure set literal."
  (concat "#{"
          (mapconcat (lambda (n) (format "%S" n))
                     port-completion-core-namespaces " ")
          "}"))

(defun port-completion--core-vec-literal ()
  "Render `port-completion-core-namespaces' as a Clojure vector literal."
  (concat "["
          (mapconcat (lambda (n) (format "%S" n))
                     port-completion-core-namespaces " ")
          "]"))

(defun port-completion--cached-symbols (ns)
  "Return the cached candidate list for NS, or nil when stale/missing.
TTL is `port-completion-cache-ttl'; a nil value disables expiry.
In two-tier mode the result is the per-ns locals merged with the
core cache, with locals shadowing any name conflicts."
  (when port-completion-use-cache
    (let ((entry (gethash ns port-completion--cache)))
      (when (and entry
                 (consp entry)
                 (car entry)              ; not a pending sentinel
                 (or (null port-completion-cache-ttl)
                     (< (- (float-time) (car entry))
                        port-completion-cache-ttl)))
        (port-completion--merge-with-core (cdr entry))))))

(defun port-completion--merge-with-core (locals)
  "Return LOCALS unioned with the core cache, locals shadowing on name conflict.
In single-tier mode (`port-completion--two-tier-p' returns nil) or
with an empty core cache, returns LOCALS unchanged."
  (cond
   ((or (null port-completion--core-cache)
        (not (port-completion--two-tier-p)))
    locals)
   (t
    (let ((seen (make-hash-table :test 'equal)))
      (dolist (c locals)
        (puthash (port-completion--name c) t seen))
      (append locals
              (cl-remove-if (lambda (c) (gethash (port-completion--name c) seen))
                            port-completion--core-cache))))))

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
RESULT is the alist delivered by `port-tooling-call-data' /
`port-tooling-call-data-sync'.  Recognises three shapes:

- a tab- and newline-delimited string (the default form's output)
  decodes via `port-completion--decode-row' into alists carrying
  `:candidate', `:type' (a Compliment kind keyword), and `:ns';
- a vector of `{:candidate :type :ns ...}' maps (the Compliment /
  Orchard override) decodes to a list of alists and is returned
  verbatim;
- a newline-only string of names (oldest legacy shape) is split
  and returned as plain strings (no annotations)."
  (when (and result (eq :ok (alist-get :tag result)))
    (let ((val (alist-get :val result)))
      (cond
       ;; New default: tab/newline-delimited string.
       ((and (stringp val)
             (not (string-empty-p val))
             (string-search "\t" val))
        (delq nil
              (mapcar #'port-completion--decode-row
                      (split-string val "\n" t))))
       ;; Compliment / Orchard rich: vector of alists.
       ((and (consp val)
             (consp (car val))
             (alist-get :candidate (car val)))
        val)
       ;; Custom form returning a plain vector of strings.
       ((and (consp val) (stringp (car val)))
        val)
       ;; Oldest legacy: newline-only string of names.
       ((and (stringp val) (not (string-empty-p val)))
        (split-string val "\n" t))))))


;;; Query helpers

(defun port-completion--query (prefix ns)
  "Build the Clojure form that lists symbols in NS starting with PREFIX.
In two-tier mode (`port-completion--two-tier-p') uses
`port-completion-local-form' with the core-ns set as a third
argument; otherwise uses the single-tier `port-completion-form'."
  (cond
   ((port-completion--two-tier-p)
    (format port-completion-local-form
            ns prefix (port-completion--core-set-literal)))
   (t
    (format port-completion-form ns prefix))))

(defun port-completion--core-query ()
  "Build the Clojure form that lists symbols in `port-completion-core-namespaces'."
  (format port-completion-core-form (port-completion--core-vec-literal)))

(defun port-completion--fetch-and-cache (ns)
  "Synchronously fetch all symbols in NS and cache the result.
Returns the candidate list (merged with the core cache when
two-tier is active), or nil on timeout / error.  Subsequent capf
invocations filter from the cache on the Elisp side.  In two-tier
mode this also synchronously populates the core cache when it's
still empty, so the first cold-cache capf returns the union of
locals and core rather than just locals."
  (when port-default-session
    (port-completion--fetch-core-sync)
    (let* ((form   (port-completion--query "" ns))
           (result (port-tooling-call-data-sync port-default-session form
                                                port-completion-timeout))
           (cands  (port-completion--parse-response result)))
      (when cands
        (when port-completion-use-cache
          (port-completion--store ns cands))
        (port-completion--merge-with-core cands)))))

(defun port-completion--fetch-core-sync ()
  "Synchronously populate `port-completion--core-cache'.
Returns the candidate list, or nil on timeout / error.  No-op
when an entry is already cached or two-tier mode is off.
Called as a fallback from `port-completion--fetch-and-cache' when
the async warm-up hasn't completed by the time the user types."
  (when (and (port-completion--two-tier-p)
             port-default-session
             (null port-completion--core-cache))
    ;; Clear the async-pending flag — we're about to satisfy it
    ;; synchronously, and leaving it stuck would block future warm-ups.
    (setq port-completion--core-cache-pending nil)
    (let* ((result (port-tooling-call-data-sync
                    port-default-session
                    (port-completion--core-query)
                    port-completion-timeout))
           (cands  (port-completion--parse-response result)))
      (when cands
        (setq port-completion--core-cache cands)
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
         (port-tooling-call-data-sync
          port-default-session
          (port-completion--query prefix ns)
          port-completion-timeout)))))))


;;; Annotation formatting

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
silently gives up; a real capf invocation will retry as needed.

In two-tier mode also kicks off the core warm-up via
`port-completion--warm-core' (idempotent)."
  (port-completion--warm-core)
  (when (and port-completion-use-cache
             port-default-session
             (null (gethash ns port-completion--cache)))
    (puthash ns (cons nil nil) port-completion--cache) ; pending sentinel
    (condition-case _
        (port-tooling-call-data
         port-default-session
         (port-completion--query "" ns)
         (lambda (result)
           (let ((cands (port-completion--parse-response result)))
             (cond
              (cands (port-completion--store ns cands))
              (t     (remhash ns port-completion--cache))))))
      (error (remhash ns port-completion--cache)))))

(defun port-completion--warm-core ()
  "Asynchronously populate `port-completion--core-cache' once.
No-op when two-tier mode is off, when the core cache already
holds an entry, or when a warm-up is already in flight.  Errors
from the tool socket clear the in-flight flag and silently give
up; subsequent capf invocations will retry via
`port-completion--fetch-core-sync' as needed."
  (when (and (port-completion--two-tier-p)
             port-default-session
             (null port-completion--core-cache)
             (null port-completion--core-cache-pending))
    (setq port-completion--core-cache-pending t)
    (condition-case _
        (port-tooling-call-data
         port-default-session
         (port-completion--core-query)
         (lambda (result)
           (let ((cands (port-completion--parse-response result)))
             (setq port-completion--core-cache-pending nil)
             (when cands
               (setq port-completion--core-cache cands)))))
      (error (setq port-completion--core-cache-pending nil)))))

;;;###autoload
(defun port-completion-invalidate (&optional ns)
  "Invalidate the per-namespace completion cache.
With NS, drop only that namespace's entry; without, clear
everything.  Called eagerly when `port-load-file' or `port-set-ns'
runs, so newly-defined vars show up immediately rather than
waiting for the TTL.  The core cache is intentionally untouched
\(refresh it manually via `port-completion-refresh-core')."
  (interactive)
  (cond
   (ns (remhash ns port-completion--cache))
   (t  (clrhash port-completion--cache))))

(defalias 'port-completion-clear-cache #'port-completion-invalidate)

;;;###autoload
(defun port-completion-refresh-core ()
  "Drop and re-fetch the core completion cache.
The core cache normally persists for the life of the session on
the assumption that `port-completion-core-namespaces' don't change
\(see `port-completion-use-core-cache').  Call this after a
hot-reload of `clojure.core' or after adding/removing a namespace
in `port-completion-core-namespaces'."
  (interactive)
  (setq port-completion--core-cache nil
        port-completion--core-cache-pending nil)
  (cond
   ((not (port-completion--two-tier-p))
    (message "Port: two-tier completion cache disabled; nothing to refresh"))
   ((not port-default-session)
    (message "Port: not connected; core cache will populate on next capf"))
   (t
    (port-completion--warm-core)
    (message "Port: refreshing core completion cache..."))))


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
