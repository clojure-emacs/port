;;; port-orchard.el --- Optional Orchard / Compliment integration -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Port's default helper-command forms target `clojure.repl/*' so they
;; work on any JVM Clojure (and on Babashka / ClojureCLR).  When the
;; running JVM also has Orchard (the introspection library that powers
;; CIDER) and Compliment on its classpath, we can swap in richer
;; equivalents: `orchard.info/info' for doc / eldoc / find-definition,
;; `orchard.apropos/find-symbols' for apropos, and
;; `compliment.core/completions' for completion-at-point.
;;
;; The forms in this file are designed to return the *same shape* the
;; default forms return -- strings for doc / apropos, an arglists-string
;; for eldoc, a printed map for xref, a newline-joined list for
;; completion -- so the Elisp-side rendering layer needs no changes.
;; Opt in either persistently
;;
;;     (require 'port-orchard)
;;     (setq port-doc-form        port-orchard-doc-form
;;           port-eldoc-form      port-orchard-eldoc-form
;;           port-apropos-form    port-orchard-apropos-form
;;           port-xref-form       port-orchard-xref-form
;;           port-completion-form port-compliment-completion-form)
;;
;; or interactively via `M-x port-enable-orchard', which probes the
;; running prepl for Orchard and Compliment availability before
;; swapping the defcustoms.

;;; Code:

(require 'port-completion)
(require 'port-eldoc)
(require 'port-mode)
(require 'port-session)
(require 'port-tooling)
(require 'port-xref)

;; Declare the defcustoms we mutate as special — the requires above
;; already pull them in at runtime, but these declarations make the
;; byte-compiler treat the `setq's in `port-orchard--apply' as dynamic
;; under lexical-binding, so `let'-binding from tests scopes properly.
(defvar port-doc-form)
(defvar port-eldoc-form)
(defvar port-apropos-form)
(defvar port-xref-form)
(defvar port-completion-form)

(defconst port-orchard-doc-form
  (concat "(if-let [m (orchard.info/info (quote %s) (quote %s))]"
          "  (with-out-str"
          "    (println \"-------------------------\")"
          "    (println (str (or (:ns m) (:class m)) \"/\""
          "                  (or (:name m) (:member m))))"
          "    (when (:arglists m) (println (str \"  \" (:arglists m))))"
          "    (when (:doc m) (println (str \"  \" (:doc m))))"
          "    (when (seq (:see-also m))"
          "      (println \"See also:\")"
          "      (doseq [s (:see-also m)] (println (str \"  \" s)))))"
          "  \"\")")
  "Orchard-flavored replacement for `port-doc-form'.
First %s is the buffer's namespace, second is the symbol.  Returns
a printed doc block on success; an empty string when the symbol
doesn't resolve (Port's emitter filters empty values).  Beyond
`clojure.repl/doc' you get Java member info, namespace aliases,
spec, and a `See also' section pulled from ClojureDocs.")

(defconst port-orchard-eldoc-form
  (concat "(when-let [m (orchard.info/info (quote %s) (quote %s))]"
          "  (when (:arglists m)"
          "    (str (or (:ns m) (:class m)) \"/\""
          "         (or (:name m) (:member m)) \": \""
          "         (:arglists m))))")
  "Orchard-flavored replacement for `port-eldoc-form'.
First %s is namespace, second is symbol.  Returns a string
matching Port's existing eldoc rendering shape.")

(defconst port-orchard-apropos-form
  (concat "(with-out-str"
          "  (doseq [m (orchard.apropos/find-symbols"
          "             {:var-query {:search (re-pattern %S)"
          "                          :search-property :name}"
          "              :full-doc? false})]"
          "    (println (:name m))))")
  "Orchard-flavored replacement for `port-apropos-form'.
%S is the search pattern as a Clojure string literal (compiled to
a regex via `re-pattern' server-side).  Returns one line per
matching symbol.")

(defconst port-orchard-xref-form
  (concat "(when-let [m (orchard.info/info (quote %s) (quote %s))]"
          "  (let [file (:file m)"
          "        url  (str file)"
          "        jar? (and file (.startsWith url \"jar:\"))]"
          "    {:name (str (:ns m) \"/\" (:name m))"
          "     :file file"
          "     :line (:line m)"
          "     :column (:column m)"
          "     :url url"
          "     :contents (when jar?"
          "                 (try (slurp file)"
          "                      (catch Throwable _ nil)))}))")
  "Orchard-flavored replacement for `port-xref-form'.
First %s is namespace, second is symbol.  Returns a map shaped
exactly like the default form's result (`:name', `:file', `:line',
`:column', `:url', `:contents'), so the Elisp xref handler needs
no changes.  Wins over the default mostly come from Orchard's
better jar / Java / REPL-temp-file resolution inside `info'.")

(defconst port-compliment-completion-form
  (concat "(let [ns (quote %s)"
          "      prefix %S]"
          "  (clojure.string/join \"\\n\""
          "    (map :candidate"
          "      (compliment.core/completions prefix"
          "        {:ns ns :sort-order :by-length}))))")
  "Compliment-flavored replacement for `port-completion-form'.
First %s is namespace, %S is the prefix as a Clojure string
literal.  Returns a newline-joined string of candidate names,
matching the wire format the existing completion code expects.")

(defconst port-orchard--probe-form
  (concat "{:orchard (try (require 'orchard.info)"
          "               (require 'orchard.apropos)"
          "               :ok (catch Throwable _ :missing))"
          " :compliment (try (require 'compliment.core)"
          "                  :ok (catch Throwable _ :missing))}")
  "Form sent on the tool socket to detect what's on the classpath.
Returns a map with `:orchard' and `:compliment' keys, each `:ok'
or `:missing'.  Each is required independently because users may
have only one.")

(defun port-orchard--apply (probe)
  "Swap in Orchard / Compliment forms for the features available in PROBE.
PROBE is the alist parsed from `port-orchard--probe-form''s
response.  Returns a list of human-readable feature names that
were enabled."
  (let (enabled)
    (when (eq :ok (alist-get :orchard probe))
      (setq port-doc-form      port-orchard-doc-form
            port-eldoc-form    port-orchard-eldoc-form
            port-apropos-form  port-orchard-apropos-form
            port-xref-form     port-orchard-xref-form)
      (setq enabled (append enabled '("doc" "eldoc" "apropos" "xref"))))
    (when (eq :ok (alist-get :compliment probe))
      (setq port-completion-form port-compliment-completion-form)
      (setq enabled (append enabled '("completion"))))
    enabled))

(defcustom port-enable-orchard-on-connect nil
  "When non-nil, run `port-enable-orchard' after each successful connect.
Driven via `port-after-connect-hook'; the probes fire asynchronously
on the tool socket, so the swap happens a moment after Port reports
the connection.  If neither Orchard nor Compliment is on the
classpath the probe just messages so."
  :type 'boolean :group 'port)

(defun port-orchard--maybe-enable-on-connect ()
  "Hook function for `port-after-connect-hook'.
Defers to `port-enable-orchard-on-connect' so toggling the
defcustom is enough — no `add-hook' / `remove-hook' dance."
  (when port-enable-orchard-on-connect
    (port-enable-orchard)))

(add-hook 'port-after-connect-hook #'port-orchard--maybe-enable-on-connect)

;;;###autoload
(defun port-enable-orchard ()
  "Swap Port's helper forms for Orchard / Compliment equivalents.
Probes the running prepl on the tool socket to confirm
`orchard.info', `orchard.apropos', and `compliment.core' are
loadable, then `setq's the matching `port-*-form' defcustoms.
The two probes are independent: if the project has Orchard but
not Compliment (or vice versa) only the available half is
swapped."
  (interactive)
  (unless port-default-session
    (user-error "Port: not connected"))
  (port-tooling-call
   port-default-session
   port-orchard--probe-form
   (lambda (result)
     (cond
      ((not (eq :ok (alist-get :tag result)))
       (message "Port: probe failed: %s"
                (or (alist-get :ex-message result) "unknown error")))
      (t
       (let* ((decoded (port-tooling-decode-val (alist-get :val result)))
              (enabled (and (consp decoded) (port-orchard--apply decoded))))
         (cond
          (enabled
           (message "Port: enabled Orchard features: %s"
                    (mapconcat #'identity enabled ", ")))
          (t
           (message "Port: neither Orchard nor Compliment is on the classpath")))))))))

(provide 'port-orchard)

;;; port-orchard.el ends here
