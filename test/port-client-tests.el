;;; port-client-tests.el --- Tests for port-client -*- lexical-binding: t -*-

;;; Commentary:

;; Smoke tests for the prepl message parser.

;;; Code:

(require 'ert)
(require 'port-client)
(require 'port-repl)

(ert-deftest port-client-test-parse-single-ret ()
  (let* ((input "{:tag :ret, :val \"3\", :ns \"user\", :ms 1, :form \"(+ 1 2)\"}\n")
         (parsed (port-client--parse-messages input))
         (msgs (car parsed)))
    (should (equal "" (cdr parsed)))
    (should (= 1 (length msgs)))
    (let ((m (car msgs)))
      (should (eq :ret (alist-get :tag m)))
      (should (equal "3" (alist-get :val m)))
      (should (equal "user" (alist-get :ns m)))
      (should (= 1 (alist-get :ms m))))))

(ert-deftest port-client-test-parse-stdout-with-newlines ()
  (let* ((input "{:tag :out, :val \"hello\\nworld\\n\"}\n")
         (parsed (port-client--parse-messages input))
         (msgs (car parsed)))
    (should (= 1 (length msgs)))
    (should (equal "hello\nworld\n" (alist-get :val (car msgs))))))

(ert-deftest port-client-test-parse-multiple ()
  (let* ((input (concat "{:tag :out, :val \"hi\\n\"}\n"
                        "{:tag :ret, :val \"42\", :ns \"user\", :ms 0, :form \"42\"}\n"))
         (msgs (car (port-client--parse-messages input))))
    (should (= 2 (length msgs)))
    (should (eq :out (alist-get :tag (nth 0 msgs))))
    (should (eq :ret (alist-get :tag (nth 1 msgs))))))

(ert-deftest port-client-test-parse-incomplete-buffered ()
  (let* ((input "{:tag :ret, :val \"3\", :ns \"user")
         (parsed (port-client--parse-messages input)))
    (should (null (car parsed)))
    (should (equal input (cdr parsed)))))

(ert-deftest port-client-test-parse-completes-after-buffering ()
  (let* ((part1 "{:tag :ret, :val \"3\"")
         (part2 ", :ns \"user\", :ms 0, :form \"(+ 1 2)\"}\n")
         (p1 (port-client--parse-messages part1))
         (leftover (cdr p1))
         (p2 (port-client--parse-messages (concat leftover part2)))
         (msgs (car p2)))
    (should (null (car p1)))
    (should (= 1 (length msgs)))
    (should (equal "3" (alist-get :val (car msgs))))))

(ert-deftest port-client-test-parse-exception-flag ()
  (let* ((input (concat "{:tag :ret, :val \"oops\", :ns \"user\","
                        " :ms 2, :form \"(/ 1 0)\", :exception true}\n"))
         (msgs (car (port-client--parse-messages input)))
         (m (car msgs)))
    (should (eq t (alist-get :exception m)))))

(ert-deftest port-client-test-parse-escaped-quotes ()
  (let* ((input "{:tag :out, :val \"say \\\"hi\\\"\\n\"}\n")
         (msgs (car (port-client--parse-messages input))))
    (should (equal "say \"hi\"\n" (alist-get :val (car msgs))))))

(ert-deftest port-client-test-input-complete-p ()
  (should (port-repl--input-complete-p "(+ 1 2)"))
  (should (port-repl--input-complete-p "42"))
  (should-not (port-repl--input-complete-p "(+ 1"))
  (should-not (port-repl--input-complete-p "\"unterminated"))
  (should (port-repl--input-complete-p "\"a string with ) inside\""))
  (should (port-repl--input-complete-p "(do ;; comment with )\n  1)")))

(provide 'port-client-tests)

;;; port-client-tests.el ends here
