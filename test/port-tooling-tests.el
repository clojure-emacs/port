;;; port-tooling-tests.el --- Tests for port-tooling -*- lexical-binding: t -*-

;;; Commentary:

;; Unit tests for the request/response correlation layer.  We don't
;; talk to a real prepl here: we synthesize the messages the tool
;; socket would deliver and verify the dispatch logic.

;;; Code:

(require 'buttercup)
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

(describe "port-tooling--read-result"

  (it "decodes an :ok result map"
    (let* ((s "{:port/id 7, :tag :ok, :val \"3\", :out \"\", :err \"\"}")
           (m (port-tooling--read-result s)))
      (expect (alist-get :port/id m) :to-equal 7)
      (expect (alist-get :tag m) :to-be :ok)
      (expect (alist-get :val m) :to-equal "3")))

  (it "decodes an :err result map"
    (let* ((s (concat "{:port/id 9, :tag :err,"
                      " :ex \"{:via [], :cause \\\"divide by zero\\\"}\","
                      " :out \"\", :err \"\"}"))
           (m (port-tooling--read-result s)))
      (expect (alist-get :tag m) :to-be :err)
      (expect (alist-get :ex m) :to-match "divide by zero")))

  ;; The bootstrap form's response is `#'port.tooling/-eval', not a
  ;; map.  Returning that as a stray symbol would break callers that
  ;; do `when-let*' followed by `alist-get'.
  (it "rejects values that aren't maps"
    (expect (port-tooling--read-result "#'port.tooling/-eval") :to-be nil)
    (expect (port-tooling--read-result "42") :to-be nil)
    (expect (port-tooling--read-result "\"a string\"") :to-be nil)))

(describe "port-tooling--dispatch"

  (it "is a no-op on a :ret with a non-map :val (the bootstrap response)"
    (let ((session (port-tooling-tests--make-session)))
      ;; If this errored, the process filter would die.
      (port-tooling--dispatch
       session
       '((:tag . :ret) (:val . "#'port.tooling/-eval")))
      (expect t :to-be-truthy)))

  (it "fires the registered callback and clears it from the pending alist"
    (let* ((session (port-tooling-tests--make-session))
           (got nil))
      (port-session-register-callback session 1 (lambda (r) (setq got r)))
      (port-tooling--dispatch
       session
       '((:tag . :ret)
         (:val . "{:port/id 1, :tag :ok, :val \"42\", :out \"\", :err \"\"}")))
      (expect got :to-be-truthy)
      (expect (alist-get :port/id got) :to-equal 1)
      (expect (alist-get :val got) :to-equal "42")
      (expect (port-session-pending session) :to-be nil)))

  (it "ignores tags other than :ret"
    (let* ((session (port-tooling-tests--make-session))
           (got nil))
      (port-session-register-callback session 1 (lambda (r) (setq got r)))
      ;; A stray :out shouldn't pop the pending entry.
      (port-tooling--dispatch
       session
       '((:tag . :out) (:val . "background chatter\n")))
      (expect got :to-be nil)
      (expect (length (port-session-pending session)) :to-equal 1)))

  (it "is a no-op when no callback is registered for the id"
    (let* ((session (port-tooling-tests--make-session)))
      (port-tooling--dispatch
       session
       '((:tag . :ret)
         (:val . "{:port/id 99, :tag :ok, :val \"x\", :out \"\", :err \"\"}")))
      (expect (port-session-pending session) :to-be nil))))

(describe "port-session-next-id!"
  (it "hands out monotonically increasing ids"
    (let ((s (port-tooling-tests--make-session)))
      (expect (port-session-next-id! s) :to-equal 1)
      (expect (port-session-next-id! s) :to-equal 2)
      (expect (port-session-next-id! s) :to-equal 3))))

(describe "port-tooling-bootstrap"
  (it "wires clojure.pprint into the -user-eval wrapper"
    (expect port-tooling-bootstrap :to-match "clojure\\.pprint")
    (expect port-tooling-bootstrap :to-match
            "with-out-str (clojure\\.pprint/pprint v)")))

(describe "port-tooling--clj-int"

  (it "renders integers as their decimal string"
    (expect (port-tooling--clj-int 5) :to-equal "5")
    (expect (port-tooling--clj-int 0) :to-equal "0"))

  (it "renders nil and non-integers as the string \"nil\""
    (expect (port-tooling--clj-int nil) :to-equal "nil")
    (expect (port-tooling--clj-int 'whatever) :to-equal "nil")))

(provide 'port-tooling-tests)

;;; port-tooling-tests.el ends here
