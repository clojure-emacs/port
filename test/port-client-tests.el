;;; port-client-tests.el --- Tests for port-client -*- lexical-binding: t -*-

;;; Commentary:

;; Smoke tests for the prepl message parser.

;;; Code:

(require 'buttercup)
(require 'port-client)
(require 'port-repl)

(describe "port-client--parse-messages"

  (it "parses a single :ret message"
    (let* ((input "{:tag :ret, :val \"3\", :ns \"user\", :ms 1, :form \"(+ 1 2)\"}\n")
           (parsed (port-client--parse-messages input))
           (msgs (car parsed))
           (m (car msgs)))
      (expect (cdr parsed) :to-equal "")
      (expect (length msgs) :to-equal 1)
      (expect (alist-get :tag m) :to-be :ret)
      (expect (alist-get :val m) :to-equal "3")
      (expect (alist-get :ns  m) :to-equal "user")
      (expect (alist-get :ms  m) :to-equal 1)))

  (it "decodes escaped newlines inside :out values"
    (let* ((input "{:tag :out, :val \"hello\\nworld\\n\"}\n")
           (msgs (car (port-client--parse-messages input))))
      (expect (length msgs) :to-equal 1)
      (expect (alist-get :val (car msgs)) :to-equal "hello\nworld\n")))

  (it "parses multiple messages in one chunk"
    (let* ((input (concat "{:tag :out, :val \"hi\\n\"}\n"
                          "{:tag :ret, :val \"42\", :ns \"user\", :ms 0, :form \"42\"}\n"))
           (msgs (car (port-client--parse-messages input))))
      (expect (length msgs) :to-equal 2)
      (expect (alist-get :tag (nth 0 msgs)) :to-be :out)
      (expect (alist-get :tag (nth 1 msgs)) :to-be :ret)))

  (it "buffers an incomplete message and returns it as leftover"
    (let* ((input "{:tag :ret, :val \"3\", :ns \"user")
           (parsed (port-client--parse-messages input)))
      (expect (car parsed) :to-be nil)
      (expect (cdr parsed) :to-equal input)))

  (it "completes a message split across two chunks"
    (let* ((part1 "{:tag :ret, :val \"3\"")
           (part2 ", :ns \"user\", :ms 0, :form \"(+ 1 2)\"}\n")
           (p1 (port-client--parse-messages part1))
           (leftover (cdr p1))
           (p2 (port-client--parse-messages (concat leftover part2)))
           (msgs (car p2)))
      (expect (car p1) :to-be nil)
      (expect (length msgs) :to-equal 1)
      (expect (alist-get :val (car msgs)) :to-equal "3")))

  (it "carries the :exception flag through"
    (let* ((input (concat "{:tag :ret, :val \"oops\", :ns \"user\","
                          " :ms 2, :form \"(/ 1 0)\", :exception true}\n"))
           (m (car (car (port-client--parse-messages input)))))
      (expect (alist-get :exception m) :to-be t)))

  (it "unescapes embedded quotes inside :out values"
    (let* ((input "{:tag :out, :val \"say \\\"hi\\\"\\n\"}\n")
           (msgs (car (port-client--parse-messages input))))
      (expect (alist-get :val (car msgs)) :to-equal "say \"hi\"\n"))))

(describe "port-client--read"

  (it "parses a vector of integers"
    (let ((res (port-client--read "[1 2 3]" 0)))
      (expect (car res) :to-equal '(1 2 3))
      (expect (cdr res) :to-equal 7)))

  (it "parses an empty vector as nil"
    (let ((res (port-client--read "[]" 0)))
      (expect (car res) :to-be nil)
      (expect (cdr res) :to-equal 2)))

  (it "parses a list with the same shape as a vector"
    (let ((res (port-client--read "(1 2 3)" 0)))
      (expect (car res) :to-equal '(1 2 3))
      (expect (cdr res) :to-equal 7)))

  (it "parses nested vectors"
    (let ((res (port-client--read "[[1 2] [3 4]]" 0)))
      (expect (car res) :to-equal '((1 2) (3 4)))))

  (it "parses a vector embedded in a map"
    (let* ((res (port-client--read "{:trace [1 2 3]}" 0))
           (m (car res)))
      (expect (alist-get :trace m) :to-equal '(1 2 3))))

  (it "parses a representative Throwable->map shape"
    (let* ((s (concat "{:via [{:type clojure.lang.ExceptionInfo"
                      " :message \"boom\" :data {:foo 1}}]"
                      " :trace [[clojure.core$eval invoke \"core.clj\" 3214]]"
                      " :cause \"boom\"}"))
           (m (car (port-client--read s 0))))
      (expect (alist-get :cause m) :to-equal "boom")
      (let ((via (alist-get :via m)))
        (expect (length via) :to-equal 1)
        (expect (alist-get :message (car via)) :to-equal "boom"))
      (let ((trace (alist-get :trace m)))
        (expect (length trace) :to-equal 1)
        (expect (nth 2 (car trace)) :to-equal "core.clj")
        (expect (nth 3 (car trace)) :to-equal 3214))))

  (it "signals `port-edn-incomplete' on an unterminated vector"
    (expect (port-client--read "[1 2" 0)
            :to-throw 'port-edn-incomplete))

  (it "signals `port-edn-incomplete' on a truncated \\u escape"
    ;; `\u00' was previously an out-of-range substring slice that
    ;; bubbled up as a generic error and dropped a byte.
    (expect (port-client--read "\"\\u00" 0)
            :to-throw 'port-edn-incomplete))

  (it "decodes a full \\uXXXX escape"
    (expect (car (port-client--read "\"\\u0041\"" 0))
            :to-equal "A")))

(describe "port-repl--input-complete-p"

  (it "accepts balanced forms"
    (expect (port-repl--input-complete-p "(+ 1 2)") :to-be-truthy)
    (expect (port-repl--input-complete-p "42") :to-be-truthy))

  (it "rejects unbalanced parens or strings"
    (expect (port-repl--input-complete-p "(+ 1") :to-be nil)
    (expect (port-repl--input-complete-p "\"unterminated") :to-be nil))

  (it "ignores closers inside strings and line comments"
    (expect (port-repl--input-complete-p "\"a string with ) inside\"")
            :to-be-truthy)
    (expect (port-repl--input-complete-p "(do ;; comment with )\n  1)")
            :to-be-truthy)))

(provide 'port-client-tests)

;;; port-client-tests.el ends here
