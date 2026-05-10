;;; port-tooling-tests.el --- Tests for port-tooling -*- lexical-binding: t -*-

;;; Commentary:

;; Unit tests for the request/response correlation layer.  We don't
;; talk to a real prepl here: we synthesize the messages the tool
;; socket would deliver and verify the dispatch logic.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'port-client)
(require 'port-session)
(require 'port-tooling)

(defun port-tooling-tests--make-session ()
  "Build a session whose connections are dummies; only state matters."
  (port-session--make
   :host "h" :port 1
   :user-conn nil
   :tool-conn nil))

(ert-deftest port-tooling-test-read-ok-result ()
  (let* ((s "{:port/id 7, :tag :ok, :val \"3\", :out \"\", :err \"\"}")
         (m (port-tooling--read-result s)))
    (should (= 7 (alist-get :port/id m)))
    (should (eq :ok (alist-get :tag m)))
    (should (equal "3" (alist-get :val m)))))

(ert-deftest port-tooling-test-read-result-rejects-non-map ()
  "The bootstrap form's response is `#'port.tooling/-eval', not a map.
The reader shouldn't return that as a stray symbol -- callers do
`when-let*' on the result and would then try `alist-get' on it."
  (should (null (port-tooling--read-result "#'port.tooling/-eval")))
  (should (null (port-tooling--read-result "42")))
  (should (null (port-tooling--read-result "\"a string\""))))

(ert-deftest port-tooling-test-dispatch-tolerates-bootstrap-response ()
  "A :ret carrying a non-map :val (e.g. the var returned by the
bootstrap) should be a no-op, not a process-filter error."
  (let ((session (port-tooling-tests--make-session)))
    (port-tooling--dispatch
     session
     '((:tag . :ret) (:val . "#'port.tooling/-eval")))
    ;; No assertion needed -- if this errors, the test fails.
    (should t)))

(ert-deftest port-tooling-test-read-err-result ()
  (let* ((s (concat "{:port/id 9, :tag :err,"
                    " :ex \"{:via [], :cause \\\"divide by zero\\\"}\","
                    " :out \"\", :err \"\"}"))
         (m (port-tooling--read-result s)))
    (should (eq :err (alist-get :tag m)))
    (should (string-match-p "divide by zero" (alist-get :ex m)))))

(ert-deftest port-tooling-test-dispatch-fires-callback ()
  (let* ((session (port-tooling-tests--make-session))
         (got nil))
    (port-session-register-callback session 1 (lambda (r) (setq got r)))
    (port-tooling--dispatch
     session
     '((:tag . :ret)
       (:val . "{:port/id 1, :tag :ok, :val \"42\", :out \"\", :err \"\"}")))
    (should got)
    (should (= 1 (alist-get :port/id got)))
    (should (equal "42" (alist-get :val got)))
    ;; Pending registry is cleared after dispatch.
    (should (null (port-session-pending session)))))

(ert-deftest port-tooling-test-dispatch-ignores-unrelated-tags ()
  (let* ((session (port-tooling-tests--make-session))
         (got nil))
    (port-session-register-callback session 1 (lambda (r) (setq got r)))
    ;; Stray :out should not pop the pending entry.
    (port-tooling--dispatch
     session
     '((:tag . :out) (:val . "background chatter\n")))
    (should-not got)
    (should (= 1 (length (port-session-pending session))))))

(ert-deftest port-tooling-test-dispatch-unknown-id-is-noop ()
  (let* ((session (port-tooling-tests--make-session)))
    ;; No callback registered for id 99.  Should not error.
    (port-tooling--dispatch
     session
     '((:tag . :ret)
       (:val . "{:port/id 99, :tag :ok, :val \"x\", :out \"\", :err \"\"}")))
    (should (null (port-session-pending session)))))

(ert-deftest port-tooling-test-id-counter-monotonic ()
  (let ((s (port-tooling-tests--make-session)))
    (should (= 1 (port-session-next-id! s)))
    (should (= 2 (port-session-next-id! s)))
    (should (= 3 (port-session-next-id! s)))))

(ert-deftest port-tooling-test-bootstrap-uses-pprint ()
  "The bootstrap should pull in clojure.pprint and use it from -user-eval."
  (should (string-match-p "clojure\\.pprint" port-tooling-bootstrap))
  (should (string-match-p "with-out-str (clojure\\.pprint/pprint v)"
                          port-tooling-bootstrap)))

(ert-deftest port-tooling-test-clj-int ()
  (should (equal "5"   (port-tooling--clj-int 5)))
  (should (equal "0"   (port-tooling--clj-int 0)))
  (should (equal "nil" (port-tooling--clj-int nil)))
  (should (equal "nil" (port-tooling--clj-int 'whatever))))

(provide 'port-tooling-tests)

;;; port-tooling-tests.el ends here
