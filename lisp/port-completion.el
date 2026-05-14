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
          "      prefix %S"
          "      cands (->> (keys (ns-map ns))"
          "                 (map str)"
          "                 (filter #(.startsWith ^String %% prefix))"
          "                 distinct"
          "                 sort)]"
          "  (apply str (interpose \"\\n\" cands)))")
  "Format string for the completion query.
The first %s is replaced with the buffer's namespace; %S is
replaced with the typed prefix as a Clojure string literal.  The
form must return a newline-joined string of candidate names.

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
means \"sentinel pending fetch\".  Candidates are lists of strings.")

(defun port-completion--cached-symbols (ns)
  "Return the cached symbol list for NS, or nil when stale/missing.
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

(defun port-completion--store (ns cands)
  "Store CANDS as the cached candidate list for NS, timestamped now."
  (puthash ns (cons (float-time) cands) port-completion--cache))

(defun port-completion--parse-response (result)
  "Return a list of candidate strings from RESULT, or nil.
RESULT is the alist delivered by `port-tooling-call' /
`port-tooling-call-sync'.  Empty payloads decode to nil."
  (when (and result (eq :ok (alist-get :tag result)))
    (let ((decoded (port-tooling-decode-val (alist-get :val result))))
      (when (and (stringp decoded) (not (string-empty-p decoded)))
        (split-string decoded "\n" t)))))


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
  "Return a list of candidates matching PREFIX, or nil.
With caching on, walks the cached symbol list (fetching it first
when the namespace hasn't been seen yet).  With caching off,
issues a sync prefix-filtered query on every call."
  (when port-default-session
    (let ((ns (port-session-current-ns port-default-session)))
      (cond
       (port-completion-use-cache
        (let ((all (or (port-completion--cached-symbols ns)
                       (port-completion--fetch-and-cache ns))))
          (when all
            (cl-remove-if-not (lambda (s) (string-prefix-p prefix s)) all))))
       (t
        (port-completion--parse-response
         (port-tooling-call-sync
          port-default-session
          (port-completion--query prefix ns)
          port-completion-timeout)))))))


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
             (cands  (port-completion--candidates prefix)))
        (when cands
          (list start end cands :exclusive 'no))))))

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
