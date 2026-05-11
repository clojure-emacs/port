;;; port-mode-tests.el --- Tests for port-mode helper commands -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the small interactive helpers in port-mode.el (the
;; commands bound on `port-mode-map' that send forms to the prepl).

;;; Code:

(require 'buttercup)
(require 'cl-lib)
(require 'port-client)
(require 'port-session)
(require 'port-repl)
(require 'port-eval)
(require 'port-mode)

(defun port-mode-tests--make-session ()
  "Build a session with distinct user/tool stub connections."
  (let ((user (port-client--make :host "h" :port 1 :process nil
                                 :buffer nil :pending ""
                                 :current-ns "user" :handler #'ignore))
        (tool (port-client--make :host "h" :port 1 :process nil
                                 :buffer nil :pending ""
                                 :current-ns "user" :handler #'ignore)))
    (port-session--make :host "h" :port 1
                        :user-conn user :tool-conn tool)))

(describe "port-set-ns"

  ;; The tool socket wraps each eval in `binding' for *ns*, which would
  ;; immediately unwind the namespace switch.  So `in-ns' must always
  ;; go on the user socket regardless of `port-eval-display'.
  (dolist (display '(minibuffer repl both))
    (it (format "always sends in-ns on the user socket (display=%s)" display)
      (let* ((session (port-mode-tests--make-session))
             (user-conn (port-session-user-conn session))
             (tool-conn (port-session-tool-conn session))
             (port-default-session session)
             (port-eval-display display)
             (buf (port-repl-create-buffer session))
             sent-conn sent-form)
        (unwind-protect
            (progn
              (cl-letf (((symbol-function 'port-client-send)
                         (lambda (conn form)
                           (setq sent-conn conn sent-form form))))
                (port-set-ns "my.ns"))
              (expect sent-conn :to-be user-conn)
              (expect sent-conn :not :to-be tool-conn)
              (expect sent-form :to-equal "(in-ns 'my.ns)"))
          (kill-buffer buf))))))

(describe "port-macroexpand-1"
  (it "raises a user-error when point isn't on a sexp"
    (with-temp-buffer
      (let* ((session (port-mode-tests--make-session))
             (port-default-session session))
        (expect (port-macroexpand-1) :to-throw 'user-error)))))

(provide 'port-mode-tests)

;;; port-mode-tests.el ends here
