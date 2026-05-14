;;; port-test-tests.el --- Tests for port-test -*- lexical-binding: t -*-

;;; Commentary:

;; Buttercup specs for the parts of the test runner that don't require
;; a live prepl: the form builders, the report renderer, and the
;; deftest-at-point regex.

;;; Code:

(require 'buttercup)
(require 'cl-lib)
(require 'port-client)
(require 'port-test)

(defconst port-test-tests--sample-results
  ;; Mimics the printed payload returned by port.test/-run-ns after a
  ;; mixed pass/fail/error run, then parsed by Port's EDN-ish reader.
  ;; The reader decodes Clojure vectors as Elisp lists, so :results
  ;; holds a list of event alists.
  '((:summary . ((:test . 3) (:pass . 1) (:fail . 1) (:error . 1)))
    (:results
     ((:type . :pass)
      (:ns   . "my.app-test")
      (:var  . "test-ok"))
     ((:type . :fail)
      (:ns   . "my.app-test")
      (:var  . "test-bad")
      (:file . "my/app_test.clj")
      (:line . 42)
      (:message . "should be equal")
      (:expected . "(= 1 2)")
      (:actual . "(not (= 1 2))"))
     ((:type . :error)
      (:ns   . "my.app-test")
      (:var  . "test-boom")
      (:file . "my/app_test.clj")
      (:line . 60)
      (:message . nil)
      (:expected . "(do-thing)")
      (:actual . "Divide by zero")
      (:ex . "{:via [...]}")
      (:ex-message . "Divide by zero"))))
  "Sample decoded result map used by the renderer tests.")


(describe "form builders honour defcustom overrides"

  (it "run-ns substitutes the namespace"
    (expect (format port-test-run-ns-form "my.ns")
            :to-equal "(port.test/-run-ns (quote my.ns))"))

  (it "run-var substitutes ns and var"
    (expect (format port-test-run-var-form "my.ns" "test-foo")
            :to-equal "(port.test/-run-var (quote my.ns) (quote test-foo))"))

  (it "leaves run-all and rerun-failed alone"
    (expect port-test-run-all-form
            :to-equal "(port.test/-run-all)")
    (expect port-test-rerun-failed-form
            :to-equal "(port.test/-rerun-failed)"))

  (it "can be redirected wholesale (dialect override)"
    (let ((port-test-run-ns-form "(my.runner/run-ns '%s)"))
      (expect (format port-test-run-ns-form "x")
              :to-equal "(my.runner/run-ns 'x)"))))


(describe "port-test--var-at-point"

  (it "extracts the name from a plain deftest"
    (with-temp-buffer
      (insert "(deftest some-test\n  (is (= 1 1)))\n")
      (goto-char (point-min))
      (forward-char 5)
      (expect (port-test--var-at-point) :to-equal "some-test")))

  (it "handles a leading metadata keyword"
    (with-temp-buffer
      (insert "(deftest ^:slow flaky-test\n  (is (= 1 1)))\n")
      (goto-char (point-min))
      (forward-char 5)
      (expect (port-test--var-at-point) :to-equal "flaky-test")))

  (it "returns nil when no deftest surrounds point"
    (with-temp-buffer
      (insert "(defn foo [] 1)\n")
      (goto-char (point-min))
      (forward-char 5)
      (expect (port-test--var-at-point) :to-be nil))))


(describe "port-test--render"

  (it "renders summary + each failure/error with file:line link"
    (let* ((port-test-auto-open nil)
           (buf (port-test--render port-test-tests--sample-results
                                   "run-tests my.app-test"
                                   (lambda () nil))))
      (unwind-protect
          (with-current-buffer buf
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (expect text :to-match "port-test: run-tests my.app-test")
              (expect text :to-match "3 assertions, 1 passed, 1 failed, 1 errored")
              (expect text :to-match "\\[FAIL\\] my.app-test/test-bad")
              (expect text :to-match "my/app_test.clj:42")
              (expect text :to-match "(= 1 2)")
              (expect text :to-match "(not (= 1 2))")
              (expect text :to-match "\\[ERROR\\] my.app-test/test-boom")
              (expect text :to-match "Divide by zero")
              (expect text :to-match "RET to show stacktrace")))
        (kill-buffer buf))))

  (it "stores the rerun thunk buffer-locally"
    (let* ((port-test-auto-open nil)
           (called 0)
           (buf (port-test--render port-test-tests--sample-results
                                   "run-tests x"
                                   (lambda () (cl-incf called)))))
      (unwind-protect
          (with-current-buffer buf
            (port-test-rerun)
            (expect called :to-equal 1))
        (kill-buffer buf))))

  (it "emits a 'no assertions' line when results are empty"
    (let* ((port-test-auto-open nil)
           (empty '((:summary . ((:test . 0) (:pass . 0)
                                 (:fail . 0) (:error . 0)))
                    (:results)))
           (buf (port-test--render empty "run-tests x" (lambda () nil))))
      (unwind-protect
          (with-current-buffer buf
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (expect text :to-match "No assertions ran.")))
        (kill-buffer buf))))

  (it "marks file:line text with the jump target property"
    (let* ((port-test-auto-open nil)
           (buf (port-test--render port-test-tests--sample-results
                                   "x" (lambda () nil))))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (re-search-forward "my/app_test.clj:42")
            (let ((target (get-text-property (1- (point))
                                             'port-test-jump-target)))
              (expect (car target) :to-equal "my/app_test.clj")
              (expect (cdr target) :to-equal 42)))
        (kill-buffer buf)))))


(describe "bootstrap form sanity"

  (it "contains the four entry points and references clojure.test"
    (expect port-test-bootstrap-form :to-match "defn -run-ns")
    (expect port-test-bootstrap-form :to-match "defn -run-var")
    (expect port-test-bootstrap-form :to-match "defn -run-all")
    (expect port-test-bootstrap-form :to-match "defn -rerun-failed")
    (expect port-test-bootstrap-form :to-match "clojure.test")
    (expect port-test-bootstrap-form :to-match "with-redefs")))


(describe "port-mode keybindings"

  (it "binds the four C-c C-t test entries"
    (require 'port-mode)
    (expect (lookup-key port-mode-map (kbd "C-c C-t t"))
            :to-equal #'port-test-run-at-point)
    (expect (lookup-key port-mode-map (kbd "C-c C-t n"))
            :to-equal #'port-test-run-ns)
    (expect (lookup-key port-mode-map (kbd "C-c C-t p"))
            :to-equal #'port-test-run-project)
    (expect (lookup-key port-mode-map (kbd "C-c C-t r"))
            :to-equal #'port-test-rerun-failed))

  (it "leaves the existing tap bindings intact"
    (require 'port-mode)
    (expect (lookup-key port-mode-map (kbd "C-c C-t v"))
            :to-equal #'port-show-taps)
    (expect (lookup-key port-mode-map (kbd "C-c C-t c"))
            :to-equal #'port-clear-taps)))

;;; port-test-tests.el ends here
