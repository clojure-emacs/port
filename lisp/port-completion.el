;;; port-completion.el --- completion-at-point via the tool socket -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; A `completion-at-point-functions' member that asks the running
;; prepl which symbols are visible in the buffer's namespace.  The
;; tool socket evaluates a small form that walks `ns-map' and returns
;; the prefix-matching names, newline-joined.

;;; Code:

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

For richer completion (locals, classes, keywords, java methods)
swap the default for a Compliment-based variant that requires
`compliment.core' and calls `compliment.core/completions' with
the prefix and the buffer ns.  Compliment is on the classpath of
any project pulling in `cider-nrepl' transitively."
  :type 'string :group 'port)

(defun port-completion--query (prefix ns)
  "Build the Clojure form that lists symbols in NS starting with PREFIX.
Uses `port-completion-form'; the first placeholder is NS, the
second PREFIX."
  (format port-completion-form ns prefix))

(defun port-completion--candidates (prefix)
  "Return a list of candidates matching PREFIX, or nil."
  (when port-default-session
    (let* ((ns (port-session-current-ns port-default-session))
           (form (port-completion--query prefix ns))
           (result (port-tooling-call-sync port-default-session form
                                           port-completion-timeout)))
      (when (and result (eq :ok (alist-get :tag result)))
        (let ((decoded (port-tooling-decode-val (alist-get :val result))))
          (when (and (stringp decoded) (not (string-empty-p decoded)))
            (split-string decoded "\n" t)))))))

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
  "Hook `port-completion-at-point' into the current buffer."
  (add-hook 'completion-at-point-functions
            #'port-completion-at-point nil t))

(defun port-completion-teardown ()
  "Remove `port-completion-at-point' from the current buffer."
  (remove-hook 'completion-at-point-functions
               #'port-completion-at-point t))

(provide 'port-completion)

;;; port-completion.el ends here
