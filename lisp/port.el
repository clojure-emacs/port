;;; port.el --- Clojure Interactive Programming over prepl -*- lexical-binding: t -*-

;; Copyright © 2026 Bozhidar Batsov and Port contributors

;; Author: Bozhidar Batsov <bozhidar@batsov.dev>
;; Maintainer: Bozhidar Batsov <bozhidar@batsov.dev>
;; Homepage: https://github.com/bbatsov/port
;; Keywords: languages, clojure, port, prepl
;; Version: 0.1.0-snapshot
;; Package-Requires: ((emacs "28") (clojure-mode "5.19"))

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Port is a minimalist Clojure interactive programming environment for
;; Emacs, in the spirit of CIDER and monroe, but built on top of
;; Clojure's built-in prepl (`clojure.core.server/io-prepl`) instead of
;; nREPL.

;; To start a prepl server from your project:
;;
;;   clj -X clojure.core.server/start-server \
;;       :name '"port"' :port 5555 \
;;       :accept clojure.core.server/io-prepl
;;
;; Then `M-x port-connect' to attach.

;;; Code:

(require 'port-client)
(require 'port-session)
(require 'port-tooling)
(require 'port-repl)
(require 'port-eval)
(require 'port-eldoc)
(require 'port-completion)
(require 'port-xref)
(require 'port-jack-in)
(require 'port-mode)

(defgroup port nil
  "Clojure Interactive Programming over prepl."
  :prefix "port-"
  :group 'applications
  :link '(url-link :tag "GitHub" "https://github.com/bbatsov/port"))

(defconst port-version "0.1.0-snapshot"
  "The current version of Port.")

(defcustom port-default-host "localhost"
  "Default host to use when connecting to a prepl."
  :type 'string
  :group 'port)

(defcustom port-default-port 5555
  "Default port to use when connecting to a prepl."
  :type 'integer
  :group 'port)

;;;###autoload
(defun port-connect (host port)
  "Connect to a running prepl server at HOST:PORT.
Opens a user socket for the REPL and a separate tool socket for
correlated helper-command requests, then pops to the REPL buffer."
  (interactive
   (list (read-string (format "Host (default %s): " port-default-host)
                      nil nil port-default-host)
         (read-number "Port: " port-default-port)))
  (let* ((user-conn (port-client-connect host port))
         (tool-conn (port-client-connect host port))
         (session   (port-session--make
                     :host host :port port
                     :user-conn user-conn
                     :tool-conn tool-conn))
         (buf       (port-repl-create-buffer session)))
    (setq port-default-session session)
    (port-tooling-install session)
    (pop-to-buffer buf)
    (message "Port connected to %s:%d (user + tool sockets)" host port)
    session))

;;;###autoload
(defun port-disconnect ()
  "Disconnect the current Port session (both sockets)."
  (interactive)
  (when port-default-session
    (port-session-shutdown port-default-session)
    (message "Port disconnected.")))

(provide 'port)

;;; port.el ends here
