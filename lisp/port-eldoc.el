;;; port-eldoc.el --- Eldoc support via the tool socket -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Show the arglists of the function whose call surrounds point.
;; Implemented via `eldoc-documentation-functions' (Emacs 28+) with
;; the async callback form, so a request goes out on the tool socket
;; and the result is delivered to eldoc when it returns.

;;; Code:

(require 'port-client)
(require 'port-session)
(require 'port-tooling)

(defun port-eldoc--target ()
  "Return the head symbol of the enclosing list form at point, as a string.
Returns nil if point is not inside a list, or there is no symbol there."
  (save-excursion
    (let ((parse (syntax-ppss)))
      (when (nth 1 parse)
        (goto-char (1+ (nth 1 parse)))
        (when-let ((sym (thing-at-point 'symbol t)))
          (substring-no-properties sym))))))

(defun port-eldoc--user-ns ()
  "Return the current namespace of the active session's user socket."
  (if port-default-session
      (port-session-current-ns port-default-session)
    "user"))

(defun port-eldoc--query (sym ns)
  "Build the Clojure form that resolves SYM in NS and return its arglists string."
  (format
   (concat "(when-let [ns (or (find-ns (quote %s)) (find-ns 'user))]"
           " (when-let [v (try (ns-resolve ns (quote %s))"
           "                   (catch Throwable _ nil))]"
           "  (let [m (meta v)]"
           "   (when-let [a (:arglists m)]"
           "    (str (symbol v) \": \" a)))))")
   ns sym))

;;;###autoload
(defun port-eldoc-function (callback &rest _ignored)
  "Async eldoc function suitable for `eldoc-documentation-functions'.
Returns non-nil when a request was dispatched, so eldoc knows to
wait for CALLBACK rather than fall through to the next function."
  (when port-default-session
    (when-let ((sym (port-eldoc--target)))
      (port-tooling-call
       port-default-session
       (port-eldoc--query sym (port-eldoc--user-ns))
       (lambda (result)
         (when (eq (alist-get :tag result) :ok)
           (let ((decoded (port-tooling-decode-val (alist-get :val result))))
             (when (stringp decoded)
               (funcall callback decoded
                        :thing sym
                        :face 'font-lock-function-name-face))))))
      t)))

;;;###autoload
(defun port-eldoc-setup ()
  "Hook `port-eldoc-function' into the current buffer's eldoc."
  (add-hook 'eldoc-documentation-functions #'port-eldoc-function nil t))

(defun port-eldoc-teardown ()
  "Remove `port-eldoc-function' from the current buffer's eldoc."
  (remove-hook 'eldoc-documentation-functions #'port-eldoc-function t))

(provide 'port-eldoc)

;;; port-eldoc.el ends here
