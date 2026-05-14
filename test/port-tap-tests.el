;;; port-tap-tests.el --- Tests for port-tap -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the tap history buffer: append, trim, and clear.

;;; Code:

(require 'buttercup)
(require 'port-tap)

(defmacro port-tap-tests--with-fresh-buffer (&rest body)
  "Run BODY with a fresh tap buffer and counter, then clean up."
  (declare (indent 0))
  `(let ((port-tap-buffer-name "*port-tap-test*")
         (port-tap-auto-show nil)
         (port-tap--entry-count 0))
     (unwind-protect
         (progn ,@body)
       (when-let ((buf (get-buffer port-tap-buffer-name)))
         (kill-buffer buf)))))

(describe "port-tap-append"

  (it "creates the buffer lazily and appends a value with a header"
    (port-tap-tests--with-fresh-buffer
      (port-tap-append "{:foo 1}")
      (with-current-buffer (get-buffer port-tap-buffer-name)
        (let ((contents (buffer-substring-no-properties (point-min) (point-max))))
          (expect contents :to-match "^;; tap @ ")
          (expect contents :to-match "{:foo 1}")))))

  (it "separates successive entries with a blank line and a new header"
    (port-tap-tests--with-fresh-buffer
      (port-tap-append "1")
      (port-tap-append "2")
      (with-current-buffer (get-buffer port-tap-buffer-name)
        (let ((headers (count-matches "^;; tap @ " (point-min) (point-max))))
          (expect headers :to-equal 2)))))

  (it "increments the entry counter"
    (port-tap-tests--with-fresh-buffer
      (port-tap-append "1")
      (port-tap-append "2")
      (port-tap-append "3")
      (expect port-tap--entry-count :to-equal 3)))

  (it "trims the oldest entry when over the cap"
    (port-tap-tests--with-fresh-buffer
      (let ((port-tap-max-entries 2))
        (port-tap-append "\"first\"")
        (port-tap-append "\"second\"")
        (port-tap-append "\"third\"")
        (expect port-tap--entry-count :to-equal 2)
        (with-current-buffer (get-buffer port-tap-buffer-name)
          (let ((contents (buffer-substring-no-properties
                           (point-min) (point-max))))
            (expect contents :not :to-match "first")
            (expect contents :to-match "second")
            (expect contents :to-match "third")))))))

(describe "port-clear-taps"
  (it "empties the buffer and resets the counter"
    (port-tap-tests--with-fresh-buffer
      (port-tap-append "1")
      (port-tap-append "2")
      (port-clear-taps)
      (expect port-tap--entry-count :to-equal 0)
      (with-current-buffer (get-buffer port-tap-buffer-name)
        (expect (buffer-size) :to-equal 0)))))

(provide 'port-tap-tests)

;;; port-tap-tests.el ends here
