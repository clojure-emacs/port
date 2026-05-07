;;; port-jack-in-tests.el --- Tests for port-jack-in -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for project detection, command construction, and the server
;; form builder.  We don't try to spawn a real JVM here.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'port-jack-in)

(defmacro port-jack-in-tests--with-fixture (markers &rest body)
  "Create a temporary directory containing each filename in MARKERS, run BODY
with `default-directory' bound to it, then clean up."
  (declare (indent 1))
  `(let ((root (file-name-as-directory (make-temp-file "port-fixture" t))))
     (unwind-protect
         (let ((default-directory root))
           (dolist (m ,markers) (with-temp-file (expand-file-name m root) (insert "")))
           ,@body)
       (delete-directory root t))))

(ert-deftest port-jack-in-test-detect-tools-deps ()
  (port-jack-in-tests--with-fixture '("deps.edn")
    (let ((root (port-jack-in--detect-project-root)))
      (should (file-equal-p root default-directory))
      (should (eq 'tools-deps (port-jack-in--detect-project-type root))))))

(ert-deftest port-jack-in-test-detect-leiningen ()
  (port-jack-in-tests--with-fixture '("project.clj")
    (let ((root (port-jack-in--detect-project-root)))
      (should (eq 'leiningen (port-jack-in--detect-project-type root))))))

(ert-deftest port-jack-in-test-detect-babashka ()
  (port-jack-in-tests--with-fixture '("bb.edn")
    (let ((root (port-jack-in--detect-project-root)))
      (should (eq 'babashka (port-jack-in--detect-project-type root))))))

(ert-deftest port-jack-in-test-detect-bare ()
  (port-jack-in-tests--with-fixture '()
    (let ((root (port-jack-in--detect-project-root)))
      (should (eq 'bare (port-jack-in--detect-project-type root))))))

(ert-deftest port-jack-in-test-detect-precedence ()
  ;; deps.edn wins over project.clj, project.clj over bb.edn.
  (port-jack-in-tests--with-fixture '("deps.edn" "project.clj" "bb.edn")
    (let ((root (port-jack-in--detect-project-root)))
      (should (eq 'tools-deps (port-jack-in--detect-project-type root))))))

(ert-deftest port-jack-in-test-server-form-contains-port ()
  (let ((form (port-jack-in--server-form 6789)))
    (should (string-match-p ":port 6789" form))
    (should (string-match-p "clojure.core.server/start-server" form))
    (should (string-match-p "clojure.core.server/io-prepl" form))
    (should (string-match-p "@(promise)" form))))

(ert-deftest port-jack-in-test-build-command-tools-deps ()
  (let ((cmd (port-jack-in--build-command 'tools-deps 5555)))
    (should (equal "clojure" (car cmd)))
    (should (equal "-e" (nth 1 cmd)))
    (should (string-match-p ":port 5555" (nth 2 cmd)))))

(ert-deftest port-jack-in-test-build-command-leiningen ()
  (let ((cmd (port-jack-in--build-command 'leiningen 5555)))
    (should (equal "lein" (car cmd)))
    (should (member "trampoline" cmd))
    (should (member "clojure.main" cmd))
    (should (cl-some (lambda (s) (string-match-p ":port 5555" s)) cmd))))

(ert-deftest port-jack-in-test-build-command-bare-uses-clojure ()
  (let ((cmd (port-jack-in--build-command 'bare 5555)))
    (should (equal "clojure" (car cmd)))))

(ert-deftest port-jack-in-test-build-command-babashka-errors ()
  (should-error (port-jack-in--build-command 'babashka 5555) :type 'user-error))

(provide 'port-jack-in-tests)

;;; port-jack-in-tests.el ends here
