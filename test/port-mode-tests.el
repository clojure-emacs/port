;;; port-mode-tests.el --- Tests for port-mode helper commands -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the small interactive helpers in port-mode.el (the
;; commands bound on `port-mode-map' that send forms to the prepl).

;;; Code:

(require 'ert)
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

(ert-deftest port-mode-test-set-ns-uses-user-socket-regardless-of-display ()
  "`port-set-ns' must send `in-ns' on the user socket even when
`port-eval-display' is set to a tool-socket mode -- the tool
socket wraps each eval in `binding' for *ns*, which would
immediately unwind the namespace switch."
  (dolist (display '(minibuffer repl both))
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
            (should (eq sent-conn user-conn))
            (should-not (eq sent-conn tool-conn))
            (should (equal "(in-ns 'my.ns)" sent-form)))
        (kill-buffer buf)))))

(provide 'port-mode-tests)

;;; port-mode-tests.el ends here
