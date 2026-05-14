;;; port-test.el --- Test runner for clojure.test -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Drives `clojure.test' over the tool socket and renders the results in
;; a navigable buffer.  Architecturally this mirrors `port-stacktrace':
;; a structured payload comes back from the JVM, gets parsed by Port's
;; EDN-ish reader, and renders into a `special-mode' buffer with
;; file:line links on each failure.
;;
;; The Clojure side lives in `port-test-bootstrap-form'.  It defines a
;; `port.test' namespace with private helpers that wrap each run in
;; `with-redefs' on `clojure.test/report', capturing per-assertion
;; events (`:pass', `:fail', `:error', `:summary') into an atom.  The
;; entry points return a result map of `{:summary {...} :results [...]}'
;; suitable for re-parsing on the Elisp side.
;;
;; Failure of a single assertion carries `:ns', `:var', `:file',
;; `:line', `:expected', `:actual', plus (for errors) `:ex' and
;; `:ex-message' so a stacktrace can be popped on demand.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'port-client)
(require 'port-eval)
(require 'port-session)
(require 'port-stacktrace)
(require 'port-tooling)
(require 'port-xref)

(defgroup port-test nil
  "Test runner for Port."
  :group 'port)

(defcustom port-test-auto-open t
  "If non-nil, pop the test report buffer automatically after each run."
  :type 'boolean
  :group 'port-test)

(defconst port-test-buffer-name "*port-test-report*")

(defface port-test-summary-face
  '((t :inherit font-lock-comment-face))
  "Face for the summary header line."
  :group 'port-test)

(defface port-test-success-face
  '((t :inherit success))
  "Face for the pass count when everything is green."
  :group 'port-test)

(defface port-test-failure-face
  '((t :inherit error :weight bold))
  "Face for the `[FAIL]' / fail-count markers."
  :group 'port-test)

(defface port-test-error-face
  '((t :inherit warning :weight bold))
  "Face for the `[ERROR]' / error-count markers."
  :group 'port-test)

(defface port-test-pass-face
  '((t :inherit success))
  "Face for `[PASS]' markers (only used when passes are shown)."
  :group 'port-test)

(defface port-test-var-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the `ns/var' headings of failing tests."
  :group 'port-test)

(defface port-test-label-face
  '((t :inherit font-lock-keyword-face))
  "Face for `expected:' / `actual:' / `at:' labels."
  :group 'port-test)

(defface port-test-file-face
  '((t :inherit link))
  "Face for the file:line link on a failure."
  :group 'port-test)


;;; Bootstrap

(defconst port-test-bootstrap-form
  "(do (clojure.core/ns port.test
         (:require [clojure.test :as ct]))
       (clojure.core/defonce ^:private port-test-state
         (atom {:events nil :summary nil :failed nil}))
       (clojure.core/defn- port-test-capture [m]
         (case (:type m)
           :pass
           (swap! port-test-state update :events
             (fnil conj [])
             {:type :pass
              :ns  (some-> ct/*testing-vars* first meta :ns ns-name str)
              :var (some-> ct/*testing-vars* first meta :name str)})
           (:fail :error)
           (let [v (first ct/*testing-vars*)
                 vm (some-> v meta)
                 actual (:actual m)
                 throwable? (instance? Throwable actual)
                 base {:type (:type m)
                       :ns   (some-> vm :ns ns-name str)
                       :var  (some-> vm :name str)
                       :file (or (:file m) (:file vm))
                       :line (or (:line m) (:line vm))
                       :message  (when (:message m) (str (:message m)))
                       :expected (pr-str (:expected m))
                       :actual   (if throwable?
                                   (or (.getMessage ^Throwable actual)
                                       (.getName (class actual)))
                                   (pr-str actual))
                       :contexts (vec ct/*testing-contexts*)}]
             (swap! port-test-state update :events
               (fnil conj [])
               (cond-> base
                 throwable?
                 (assoc :ex (pr-str (Throwable->map actual))
                        :ex-message (or (.getMessage ^Throwable actual)
                                        (.getName (class actual)))))))
           :summary
           (swap! port-test-state assoc :summary
             (select-keys m [:test :pass :fail :error]))
           nil))
       (clojure.core/defn- port-test-run* [thunk]
         (swap! port-test-state assoc :events [] :summary nil)
         (let [orig ct/report]
           ;; Chain to the original report so `inc-report-counter!' still
           ;; fires; the `:summary' event we capture afterwards then
           ;; carries accurate counts.  Diagnostic prints from `orig'
           ;; flow into the tooling wrapper's captured `*out*' / `*err*'
           ;; and are discarded.
           (with-redefs [ct/report (fn [m] (port-test-capture m) (orig m))]
             (thunk)))
         (let [s       @port-test-state
               events  (or (:events s) [])
               counts  (frequencies (map :type events))
               ;; `run-tests' emits a `:summary' event we capture; `test-vars'
               ;; doesn't, so fall back to counts derived from events.
               summary (or (:summary s)
                           {:test  (count (distinct (map :var events)))
                            :pass  (get counts :pass 0)
                            :fail  (get counts :fail 0)
                            :error (get counts :error 0)})
               failed  (->> events
                            (filter #(#{:fail :error} (:type %)))
                            (map (juxt :ns :var))
                            distinct vec)]
           (swap! port-test-state assoc :failed failed)
           {:summary summary :results events}))
       (clojure.core/defn -run-ns [ns-sym]
         (require ns-sym)
         (port-test-run* #(ct/run-tests ns-sym)))
       (clojure.core/defn -run-var [ns-sym var-sym]
         (require ns-sym)
         (if-let [v (ns-resolve ns-sym var-sym)]
           (port-test-run* #(ct/test-vars [v]))
           {:summary {:test 0 :pass 0 :fail 0 :error 0} :results []}))
       (clojure.core/defn -run-all []
         (let [nses (->> (all-ns)
                         (filter (fn [n]
                                   (some (comp :test meta val) (ns-interns n))))
                         (map ns-name)
                         vec)]
           (if (seq nses)
             (port-test-run* #(apply ct/run-tests nses))
             {:summary {:test 0 :pass 0 :fail 0 :error 0} :results []})))
       (clojure.core/defn -rerun-failed []
         (let [pairs (:failed @port-test-state)
               vars (keep (fn [[n s]]
                            (try
                              (let [n-sym (symbol n)
                                    s-sym (symbol s)]
                                (require n-sym)
                                (ns-resolve n-sym s-sym))
                              (catch Throwable _ nil)))
                          pairs)]
           (if (seq vars)
             (port-test-run* #(ct/test-vars (vec vars)))
             {:summary {:test 0 :pass 0 :fail 0 :error 0} :results []}))))"
  "Clojure form that installs the `port.test' namespace on the tool socket.
Sent lazily before the first run command.  Defines `-run-ns',
`-run-var', `-run-all', and `-rerun-failed' entry points; each
captures `clojure.test/report' events into a per-session atom and
returns a printed result map of `{:summary {...} :results [...]}'.")

(defcustom port-test-run-ns-form "(port.test/-run-ns (quote %s))"
  "Format string for the run-ns command.
%s is the target namespace as a symbol."
  :type 'string :group 'port-test)

(defcustom port-test-run-var-form
  "(port.test/-run-var (quote %s) (quote %s))"
  "Format string for the run-var command.
First %s is the namespace, second is the var name."
  :type 'string :group 'port-test)

(defcustom port-test-run-all-form "(port.test/-run-all)"
  "Format string for the run-all-loaded-test-namespaces command."
  :type 'string :group 'port-test)

(defcustom port-test-rerun-failed-form "(port.test/-rerun-failed)"
  "Format string for the rerun-failed command."
  :type 'string :group 'port-test)


;;; Lazy bootstrap

(defvar port-test--installed-sessions nil
  "Sessions that have already received `port-test-bootstrap-form'.
Tracked weakly enough for our purposes: when a session is shut
down, `port-default-session' becomes nil and any stale entry is
harmless until Emacs is restarted.")

(defun port-test--ensure-installed (session)
  "Send `port-test-bootstrap-form' on SESSION's tool socket if not yet sent."
  (unless (memq session port-test--installed-sessions)
    (port-tooling-call session port-test-bootstrap-form
                       (lambda (_result) nil))
    (push session port-test--installed-sessions)))

(defun port-test--dispatch (form on-result)
  "Send FORM on the current session's tool socket; call ON-RESULT with parsed payload.
ON-RESULT receives the decoded `{:summary :results}' alist, or nil
when the response was an error.  An error result still pops the
stacktrace buffer through the usual path."
  (let ((session (port-current-session)))
    (port-test--ensure-installed session)
    (port-tooling-call
     session form
     (lambda (result)
       (cond
        ((not (eq :ok (alist-get :tag result)))
         (message "Port: test run failed: %s"
                  (or (alist-get :ex-message result) "unknown error"))
         (port-stacktrace-pop-from-result result)
         (funcall on-result nil))
        (t
         (let ((decoded (port-tooling-decode-val (alist-get :val result))))
           (funcall on-result decoded))))))))


;;; Interactive commands

(defvar-local port-test--last-rerun nil
  "Buffer-local thunk that re-runs the command that produced this report.")

(defun port-test--var-at-point ()
  "Return the deftest name enclosing point as a string, or nil.
Recognises plain `(deftest name ...)' and simple
`(deftest ^:tag name ...)' forms.  Returns nil if no enclosing
deftest is detectable."
  (save-excursion
    (when (ignore-errors (beginning-of-defun) t)
      (let* ((start (point))
             (end   (save-excursion (ignore-errors (forward-sexp 1)) (point)))
             (text  (and (> end start)
                         (buffer-substring-no-properties start end))))
        (when (and text
                   (string-match
                    (concat "\\`(\\s-*deftest"
                            "\\(?:\\s-+\\^[^[:space:]\n]+\\)*"
                            "\\s-+\\([^[:space:]\n()]+\\)")
                    text))
          (match-string-no-properties 1 text))))))

;;;###autoload
(defun port-test-run-ns (&optional ns)
  "Run every deftest in NS via `clojure.test/run-tests' on the tool socket.
NS defaults to the current buffer's namespace.  Results are
rendered in `*port-test-report*'."
  (interactive
   (list (read-string "Test namespace: "
                      (or (port-current-buffer-ns) "user"))))
  (let* ((ns* ns)
         (form (format port-test-run-ns-form ns*))
         (rerun (lambda () (port-test-run-ns ns*))))
    (port-test--dispatch
     form
     (lambda (decoded)
       (when decoded
         (port-test--render decoded
                            (format "run-tests %s" ns*)
                            rerun))))))

;;;###autoload
(defun port-test-run-at-point ()
  "Run the deftest enclosing point.
Falls back to prompting for the var name when no deftest can be
detected at point.  Results go to `*port-test-report*'."
  (interactive)
  (let* ((ns (or (port-current-buffer-ns)
                 (user-error "Port: cannot determine current namespace")))
         (var (or (port-test--var-at-point)
                  (read-string "Test var: " (port-symbol-at-point))))
         (form (format port-test-run-var-form ns var))
         (rerun (lambda () (port-test--rerun-var ns var))))
    (port-test--dispatch
     form
     (lambda (decoded)
       (when decoded
         (port-test--render decoded
                            (format "test-var %s/%s" ns var)
                            rerun))))))

(defun port-test--rerun-var (ns var)
  "Internal helper used by the report buffer's `g' binding for a single-var run.
Re-invokes `port-test-run-var-form' for VAR in NS."
  (let* ((form (format port-test-run-var-form ns var))
         (rerun (lambda () (port-test--rerun-var ns var))))
    (port-test--dispatch
     form
     (lambda (decoded)
       (when decoded
         (port-test--render decoded
                            (format "test-var %s/%s" ns var)
                            rerun))))))

;;;###autoload
(defun port-test-run-project ()
  "Run every deftest across all loaded test-bearing namespaces.
A namespace is considered test-bearing when at least one of its
interned vars has `:test' metadata (which `deftest' attaches)."
  (interactive)
  (let ((rerun (lambda () (port-test-run-project))))
    (port-test--dispatch
     port-test-run-all-form
     (lambda (decoded)
       (when decoded
         (port-test--render decoded "run-all" rerun))))))

;;;###autoload
(defun port-test-rerun-failed ()
  "Re-run only the deftest vars that failed or errored on the last run."
  (interactive)
  (let ((rerun (lambda () (port-test-rerun-failed))))
    (port-test--dispatch
     port-test-rerun-failed-form
     (lambda (decoded)
       (when decoded
         (port-test--render decoded "rerun-failed" rerun))))))


;;; Report buffer

(defvar port-test-report-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'port-test-jump)
    (define-key map (kbd "n")   #'port-test-next-failure)
    (define-key map (kbd "p")   #'port-test-previous-failure)
    (define-key map (kbd "g")   #'port-test-rerun)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `port-test-report-mode'.")

(define-derived-mode port-test-report-mode special-mode "Port-Test"
  "Major mode for browsing a Port test report."
  :group 'port-test
  (setq buffer-read-only t)
  (setq-local truncate-lines nil))

(defun port-test--render (decoded label rerun)
  "Render DECODED test results into the report buffer.
LABEL is shown in the summary header; RERUN is stored as a
buffer-local thunk for the `g' binding."
  (let ((buf (get-buffer-create port-test-buffer-name)))
    (with-current-buffer buf
      (port-test-report-mode)
      (setq port-test--last-rerun rerun)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (port-test--insert-summary decoded label)
        (insert "\n")
        (port-test--insert-failures decoded)
        (goto-char (point-min))))
    (when port-test-auto-open
      (display-buffer buf))
    buf))

(defun port-test--insert-summary (decoded label)
  "Insert the summary header for DECODED labeled LABEL."
  (let* ((summary (alist-get :summary decoded))
         (test  (or (alist-get :test summary) 0))
         (pass  (or (alist-get :pass summary) 0))
         (fail  (or (alist-get :fail summary) 0))
         (error (or (alist-get :error summary) 0))
         (clean (and (zerop fail) (zerop error))))
    (insert (propertize (format ";; port-test: %s\n" label)
                        'face 'port-test-summary-face))
    (insert (format "%d assertions, " test))
    (insert (propertize (format "%d passed" pass)
                        'face (if (and clean (> pass 0))
                                  'port-test-success-face
                                'default)))
    (insert ", ")
    (insert (propertize (format "%d failed" fail)
                        'face (if (zerop fail)
                                  'default
                                'port-test-failure-face)))
    (insert ", ")
    (insert (propertize (format "%d errored" error)
                        'face (if (zerop error)
                                  'default
                                'port-test-error-face)))
    (insert "\n")))

(defun port-test--insert-failures (decoded)
  "Insert the per-failure detail sections for DECODED."
  (let ((results (alist-get :results decoded))
        (any nil))
    (dolist (ev results)
      (let ((type (alist-get :type ev)))
        (when (memq type '(:fail :error))
          (setq any t)
          (port-test--insert-event ev))))
    (when (and (not any) results)
      (insert "All tests passed.\n"))
    (when (null results)
      (insert "No assertions ran.\n"))))

(defun port-test--insert-event (ev)
  "Insert one failure/error entry from EV at point."
  (let* ((type (alist-get :type ev))
         (ns   (alist-get :ns ev))
         (var  (alist-get :var ev))
         (file (alist-get :file ev))
         (line (alist-get :line ev))
         (msg  (alist-get :message ev))
         (exp  (alist-get :expected ev))
         (act  (alist-get :actual ev))
         (ex   (alist-get :ex ev))
         (header (if (eq type :error) "[ERROR]" "[FAIL]"))
         (header-face (if (eq type :error)
                          'port-test-error-face
                        'port-test-failure-face))
         (entry-start (point)))
    (insert "\n")
    (insert (propertize header 'face header-face))
    (insert " ")
    (insert (propertize (format "%s/%s" (or ns "?") (or var "?"))
                        'face 'port-test-var-face))
    (insert "\n")
    (when (and file line)
      (insert "  ")
      (insert (propertize "at:" 'face 'port-test-label-face))
      (insert "       ")
      (let ((link-start (point)))
        (insert (format "%s:%d" file line))
        (add-text-properties link-start (point)
                             `(face port-test-file-face
                                    port-test-jump-target (,file . ,line)
                                    mouse-face highlight))))
    (insert "\n")
    (when msg
      (insert "  ")
      (insert (propertize "message:" 'face 'port-test-label-face))
      (insert "  ")
      (insert msg)
      (insert "\n"))
    (when exp
      (insert "  ")
      (insert (propertize "expected:" 'face 'port-test-label-face))
      (insert " ")
      (insert exp)
      (insert "\n"))
    (when act
      (insert "  ")
      (insert (propertize "actual:" 'face 'port-test-label-face))
      (insert "   ")
      (insert act)
      (insert "\n"))
    (when (and (eq type :error) ex)
      (let ((trace-start (point)))
        (insert "  ")
        (insert (propertize "(RET to show stacktrace)"
                            'face 'port-test-label-face))
        (insert "\n")
        (add-text-properties trace-start (point)
                             `(port-test-stacktrace ,ex
                                                    mouse-face highlight))))
    (add-text-properties entry-start (point)
                         `(port-test-failure t))))

(defun port-test-jump ()
  "Jump to source for the failure at point, or pop a stacktrace for errors."
  (interactive)
  (let ((target (get-text-property (point) 'port-test-jump-target))
        (ex     (get-text-property (point) 'port-test-stacktrace)))
    (cond
     (target
      (port-test--visit (car target) (cdr target)))
     (ex
      (when-let ((parsed (port-stacktrace-parse ex)))
        (port-stacktrace-display parsed nil)))
     (t
      (message "Port: nothing to jump to here")))))

(defun port-test--visit (file line)
  "Visit FILE at LINE.  FILE may be classpath-relative."
  (cond
   ((or (null file) (equal file "?"))
    (message "Port: no file recorded for this failure"))
   ((file-name-absolute-p file)
    (if (file-exists-p file)
        (port-xref--visit file line)
      (message "Port: %s is not locally accessible" file)))
   (t
    (let ((found (port-stacktrace--locate-relative file)))
      (if found
          (port-xref--visit found line)
        (message "Port: cannot resolve %s to a local file" file))))))

(defun port-test-next-failure ()
  "Move point to the next failure/error entry."
  (interactive)
  (port-test--move-to-failure 'next))

(defun port-test-previous-failure ()
  "Move point to the previous failure/error entry."
  (interactive)
  (port-test--move-to-failure 'previous))

(defun port-test--move-to-failure (dir)
  "Move point to the adjacent failure marker in DIR (`next' or `previous')."
  (let ((search (if (eq dir 'next)
                    #'next-single-property-change
                  #'previous-single-property-change)))
    (let ((pos (funcall search (point) 'port-test-failure)))
      (when pos
        (goto-char pos)
        (unless (get-text-property (point) 'port-test-failure)
          (let ((again (funcall search (point) 'port-test-failure)))
            (when again (goto-char again))))))))

(defun port-test-rerun ()
  "Re-run the last test selection from this report buffer."
  (interactive)
  (if port-test--last-rerun
      (funcall port-test--last-rerun)
    (user-error "Port: no previous test run to rerun")))

(provide 'port-test)

;;; port-test.el ends here
