;;; port-stacktrace.el --- Stacktrace buffer for Port -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Renders a parsed `Throwable->map' (as produced by the JVM) into a
;; readable buffer.  The cause chain is shown at the top, ex-data
;; expanded, and the frame list at the bottom with file:line links.
;;
;; Both the user socket (`:exception true' on `:ret') and the tool
;; socket (`:tag :err' result maps) feed into the same renderer, so
;; the user sees a consistent error UI regardless of the path that
;; produced the exception.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'port-client)
(require 'port-tooling)
(require 'port-xref)

(defgroup port-stacktrace nil
  "Stacktrace rendering for Port."
  :group 'port)

(defcustom port-stacktrace-auto-open t
  "If non-nil, pop the stacktrace buffer automatically on exception."
  :type 'boolean
  :group 'port-stacktrace)

(defcustom port-stacktrace-hide-clojure-internals t
  "If non-nil, hide common Clojure/Java internal frames from the trace.
Frames whose class starts with `clojure.lang.', `clojure.core$',
`clojure.main', `java.', `javax.', `sun.', `jdk.', or `nrepl.'
are filtered out (see `port-stacktrace--noise-frame-p')."
  :type 'boolean
  :group 'port-stacktrace)

(defconst port-stacktrace-buffer-name "*port-stacktrace*")

(defface port-stacktrace-cause-face
  '((t :inherit error :weight bold))
  "Face for cause headings."
  :group 'port-stacktrace)

(defface port-stacktrace-message-face
  '((t :inherit font-lock-string-face))
  "Face for exception messages."
  :group 'port-stacktrace)

(defface port-stacktrace-data-face
  '((t :inherit font-lock-constant-face))
  "Face for ex-data."
  :group 'port-stacktrace)

(defface port-stacktrace-frame-face
  '((t :inherit default))
  "Face for trace frames."
  :group 'port-stacktrace)

(defface port-stacktrace-file-face
  '((t :inherit link))
  "Face for the file:line portion of a trace frame."
  :group 'port-stacktrace)

(defvar port-stacktrace-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'port-stacktrace-jump)
    (define-key map (kbd "n")   #'port-stacktrace-next-frame)
    (define-key map (kbd "p")   #'port-stacktrace-previous-frame)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `port-stacktrace-mode'.")

(define-derived-mode port-stacktrace-mode special-mode "Port-Stack"
  "Major mode for browsing a parsed Clojure stacktrace."
  :group 'port-stacktrace
  (setq buffer-read-only t)
  (setq-local truncate-lines t))

(defun port-stacktrace-display (ex-map &optional ex-message)
  "Render EX-MAP — a parsed Throwable->map — into the stacktrace buffer.
EX-MESSAGE, if given, is the exception's message string (sometimes
provided alongside the printed map by the tool wrapper).  When
`port-stacktrace-auto-open' is non-nil, pop the buffer."
  (let ((buf (get-buffer-create port-stacktrace-buffer-name)))
    (with-current-buffer buf
      (port-stacktrace-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (port-stacktrace--render ex-map ex-message)
        (goto-char (point-min))))
    (when port-stacktrace-auto-open
      (display-buffer buf))
    buf))

(defun port-stacktrace--render (m ex-message)
  "Render parsed map M into the current buffer; EX-MESSAGE is optional."
  (let ((via   (alist-get :via m))
        (trace (alist-get :trace m))
        (cause (alist-get :cause m)))
    (cond
     (via
      (port-stacktrace--render-causes via))
     (cause
      (port-stacktrace--insert-cause-line nil cause nil)))
    (when (and ex-message (null via) (null cause))
      (port-stacktrace--insert-cause-line nil ex-message nil))
    (insert "\n")
    (port-stacktrace--render-trace trace)))

(defun port-stacktrace--render-causes (via)
  "Render the `:via' chain VIA at point."
  (let ((first t))
    (dolist (entry via)
      (let ((type    (alist-get :type entry))
            (message (alist-get :message entry))
            (data    (alist-get :data entry))
            (at      (alist-get :at entry)))
        (unless first (insert "\n"))
        (setq first nil)
        (port-stacktrace--insert-cause-line type message data)
        (when at
          (insert "  thrown at: ")
          (port-stacktrace--insert-frame at)
          (insert "\n"))))))

(defun port-stacktrace--insert-cause-line (type message data)
  "Insert a single cause line with TYPE, MESSAGE, and ex-data DATA."
  (when type
    (insert (propertize (format "%s" type) 'face 'port-stacktrace-cause-face))
    (insert ": "))
  (when message
    (insert (propertize message 'face 'port-stacktrace-message-face)))
  (insert "\n")
  (when data
    (insert "  data: ")
    (insert (propertize (port-stacktrace--format-data data)
                        'face 'port-stacktrace-data-face))
    (insert "\n")))

(defun port-stacktrace--format-data (data)
  "Format DATA (an alist or atom) for display."
  (cond
   ((null data) "nil")
   ((stringp data) data)
   ((and (consp data) (consp (car data)))
    ;; alist (map)
    (concat "{"
            (mapconcat (lambda (kv)
                         (format "%s %s"
                                 (port-stacktrace--format-data (car kv))
                                 (port-stacktrace--format-data (cdr kv))))
                       data ", ")
            "}"))
   ((listp data)
    (concat "[" (mapconcat #'port-stacktrace--format-data data " ") "]"))
   ((symbolp data) (symbol-name data))
   ((numberp data) (number-to-string data))
   (t (format "%s" data))))

(defun port-stacktrace--render-trace (trace)
  "Render TRACE — a list of frame vectors — at point."
  (let ((frames (if port-stacktrace-hide-clojure-internals
                    (cl-remove-if #'port-stacktrace--noise-frame-p trace)
                  trace)))
    (cond
     ((null frames)
      (when trace
        (insert "Trace:\n  (all frames hidden — toggle "
                "`port-stacktrace-hide-clojure-internals')\n")))
     (t
      (insert "Trace:\n")
      (dolist (frame frames)
        (insert "  ")
        (port-stacktrace--insert-frame frame)
        (insert "\n"))
      (when (and port-stacktrace-hide-clojure-internals
                 (< (length frames) (length trace)))
        (insert (format "  (%d frames hidden)\n"
                        (- (length trace) (length frames)))))))))

(defun port-stacktrace--insert-frame (frame)
  "Insert FRAME (a list of [class method file line]) as a clickable line."
  (let* ((class  (nth 0 frame))
         (method (nth 1 frame))
         (file   (nth 2 frame))
         (line   (nth 3 frame))
         (start  (point)))
    (insert (format "%s %s "
                    (port-stacktrace--symbol-name class)
                    (port-stacktrace--symbol-name method)))
    (let ((file-start (point)))
      (insert (format "(%s:%s)"
                      (or file "?")
                      (if (numberp line) (number-to-string line) "?")))
      (add-text-properties file-start (point)
                           `(face port-stacktrace-file-face
                             port-stacktrace-frame ,frame
                             mouse-face highlight)))
    (add-text-properties start (point)
                         `(port-stacktrace-frame ,frame))))

(defun port-stacktrace--symbol-name (x)
  "Return X printed as a name; symbols print without leading colon."
  (cond
   ((null x) "?")
   ((symbolp x) (symbol-name x))
   ((stringp x) x)
   (t (format "%s" x))))

(defun port-stacktrace--noise-frame-p (frame)
  "Non-nil if FRAME should be hidden as Clojure/Java internal noise."
  (let ((class (port-stacktrace--symbol-name (nth 0 frame))))
    (or (string-prefix-p "clojure.lang." class)
        (string-prefix-p "clojure.core$" class)
        (string-prefix-p "clojure.main" class)
        (string-prefix-p "java." class)
        (string-prefix-p "javax." class)
        (string-prefix-p "sun." class)
        (string-prefix-p "jdk." class)
        (string-prefix-p "nrepl." class))))

(defun port-stacktrace-jump ()
  "Visit the source for the trace frame at point, if resolvable."
  (interactive)
  (let ((frame (get-text-property (point) 'port-stacktrace-frame)))
    (cond
     ((null frame)
      (user-error "No frame at point"))
     (t
      (let ((file (nth 2 frame))
            (line (nth 3 frame)))
        (port-stacktrace--visit-frame
         (port-stacktrace--symbol-name file)
         (and (numberp line) line)))))))

(defun port-stacktrace--visit-frame (file line)
  "Best-effort visit of FILE at LINE.
File paths in `Throwable->map' are typically classpath-relative.
We try (1) absolute paths, (2) under `default-directory', (3)
common project source roots."
  (cond
   ((or (null file) (equal file "?"))
    (message "Port: no file recorded for this frame"))
   ((file-name-absolute-p file)
    (if (file-exists-p file)
        (port-xref--visit file line)
      (message "Port: %s is not locally accessible" file)))
   (t
    (let ((found (port-stacktrace--locate-relative file)))
      (if found
          (port-xref--visit found line)
        (message "Port: cannot resolve %s to a local file" file))))))

(declare-function port-jack-in--detect-project-root "port-jack-in")

(defun port-stacktrace--locate-relative (file)
  "Try to locate a classpath-relative FILE under the current project.
Anchors the search at the jack-in-detected project root when
possible (so a stacktrace rendered from a sub-directory still
resolves frames against the top-level `src/' tree), falling back
to `default-directory'."
  (let* ((root  (or (and (fboundp 'port-jack-in--detect-project-root)
                         (port-jack-in--detect-project-root))
                    default-directory))
         (roots (list root
                      (expand-file-name "src" root)
                      (expand-file-name "test" root)
                      (expand-file-name "src/main/clojure" root)
                      (expand-file-name "src/test/clojure" root))))
    (cl-loop for r in roots
             for candidate = (expand-file-name file r)
             when (file-exists-p candidate) return candidate)))

(defun port-stacktrace-next-frame ()
  "Move point to the next trace frame."
  (interactive)
  (let ((next (next-single-property-change (point) 'port-stacktrace-frame)))
    (when next
      (goto-char next)
      (unless (get-text-property (point) 'port-stacktrace-frame)
        (let ((after (next-single-property-change (point) 'port-stacktrace-frame)))
          (when after (goto-char after)))))))

(defun port-stacktrace-previous-frame ()
  "Move point to the previous trace frame."
  (interactive)
  (let ((prev (previous-single-property-change (point) 'port-stacktrace-frame)))
    (when prev
      (goto-char prev)
      (unless (get-text-property (point) 'port-stacktrace-frame)
        (let ((before (previous-single-property-change
                       (point) 'port-stacktrace-frame)))
          (when before (goto-char before)))))))

(defun port-stacktrace-parse (val)
  "Parse VAL — a printed Throwable->map string — into an alist.
Returns nil if VAL isn't a string or doesn't parse as a map.
A thin wrapper around `port-tooling--read-result' so the two
parse-as-map paths share an implementation."
  (and (stringp val) (port-tooling--read-result val)))

(defun port-stacktrace-pop-from-result (result)
  "Display a stacktrace buffer for an `:err' RESULT from the tool socket.
RESULT is an alist with at least `:ex' (the printed Throwable->map).
No-op if `:ex' isn't present or doesn't parse."
  (let* ((ex      (alist-get :ex result))
         (msg     (alist-get :ex-message result))
         (parsed  (port-stacktrace-parse ex)))
    (when parsed
      (port-stacktrace-display parsed msg))))

(provide 'port-stacktrace)

;;; port-stacktrace.el ends here
