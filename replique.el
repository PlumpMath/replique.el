;; replique.el ---   -*- lexical-binding: t; -*-

;; Copyright © 2016 Ewen Grosjean

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

;; This file is not part of GNU Emacs.

;; Version 0.0.5-SNAPSHOT
;; Package-Requires: ((emacs "25") (clojure-mode "5.6.0"))

;; Commentary:

;; Code:

(require 'subr-x)
(require 'comint)
(require 'clojure-mode)
(require 'replique-edn)
(require 'replique-async)
(require 'replique-hashmap)
(require 'replique-resources)
(require 'map)

(defmacro comment (&rest body)
  "Comment out one or more s-expressions."
  nil)

(defun replique/keyword-to-string (k)
  (substring (symbol-name k) 1))

(defun replique/message-nolog (format-string)
  (let ((message-log-max nil))
    (message "%s" format-string)))

(defun replique/visible-buffers ()
  (let ((buffers '()))
    (walk-windows
     (lambda (window) (push (window-buffer window) buffers))
     nil 'visible)
    buffers))

(defun replique/symprompt (prompt default)
  (list (let* ((prompt (if default
                           (format "%s (default %s): " prompt default)
                         (concat prompt ": ")))
               (ans (read-string prompt)))
          (if (zerop (length ans)) default ans))))

;; completing-read uses an alphabetical order by default. This function can be used too keep
;; the order of the candidates
(defun replique/presorted-completion-table (completions)
  (lambda (string pred action)
    (if (eq action 'metadata)
        `(metadata (display-sort-function . ,'identity))
      (complete-with-action action completions string pred))
    completions))

(defvar replique/repls nil)

(defun replique/pp-repls ()
  (string-join
   (thread-last replique/repls
     (mapcar (lambda (repl)
               (let* ((repl (if (replique/contains? repl :buffer)
                                (replique/assoc repl :buffer '**)
                              repl))
                      (repl (if (replique/contains? repl :proc)
                                (replique/assoc repl :proc '**)
                              repl))
                      (repl (if (replique/contains? repl :network-proc)
                                (replique/assoc repl :network-proc '**)
                              repl))
                      (repl (if (replique/contains? repl :chan)
                                (replique/assoc repl :chan '**)
                              repl)))
                 repl)))
     (mapcar 'replique-edn/pr-str))
   "\n"))

(defun replique/plist->alist (plist)
  (let ((alist '()))
    (while plist
      (setq alist (push `(,(car plist) . ,(cadr plist)) alist))
      (setq plist (cddr plist)))
    alist))

(defun replique/update-repl (old-repl updated-repl)
  (setq replique/repls (mapcar (lambda (repl)
                                 (if (eq repl old-repl)
                                     updated-repl
                                   repl))
                               replique/repls)))

(defun replique/repls-or-repl-by (filtering-fn source &rest args)
  (let* ((pred (lambda (repl)
                 (seq-every-p (lambda (arg)
                                (let ((k (car arg))
                                      (v (cdr arg)))
                                  (or (equal :error-on-nil k)
                                      (and (replique/contains? repl k)
                                           (equal v (replique/get repl k))))))
                              (replique/plist->alist args))))
         (found (funcall filtering-fn pred source)))
    (if (and (null found) (plist-get args :error-on-nil))
        (user-error "No started REPL")
      found)))

(defun replique/repl-by (&rest args)
  (apply 'replique/repls-or-repl-by 'seq-find replique/repls args))

(defun replique/repls-by (&rest args)
  (apply 'replique/repls-or-repl-by 'seq-filter replique/repls args))

(defun replique/get-by (source &rest args)
  (apply 'replique/repls-or-repl-by 'seq-find source args))

(defun replique/get-all-by (source &rest args)
  (apply 'replique/repls-or-repl-by 'seq-filter source args))

(defun replique/active-repl (repl-type &optional error-on-nil)
  (if error-on-nil
      (replique/repl-by :repl-type repl-type :error-on-nil error-on-nil)
    (replique/repl-by :repl-type repl-type)))

(defun replique/guess-project-root-dir ()
  (or (locate-dominating-file default-directory "project.clj")
      default-directory))

(defmacro replique/with-modes-dispatch (&rest modes-alist)
  (let* ((tooling-repl-sym (make-symbol "tooling-repl"))
         (clj-repl-sym (make-symbol "clj-repl-sym"))
         (cljs-repl-sym (make-symbol "cljs-repl-sym"))
         (clj-buff-sym (make-symbol "clj-buff-sym"))
         (cljs-buff-sym (make-symbol "cljs-buff-sym"))
         (dispatch-code
          (mapcar
           (lambda (item)
             (let ((m (car item))
                   (f (cdr item)))
               ;; The order of priority is the order of the modes as defined during
               ;; the use of the macro
               (cond ((equal 'clojure-mode m)
                      `((equal 'clojure-mode major-mode)
                        (funcall ,f ,tooling-repl-sym ,clj-repl-sym)))
                     ((equal 'clojurescript-mode m)
                      `((equal 'clojurescript-mode major-mode)
                        (funcall ,f ,tooling-repl-sym ,cljs-repl-sym)))
                     ((equal 'clojurec-mode m)
                      `((equal 'clojurec-mode major-mode)
                        (funcall ,f ,tooling-repl-sym ,clj-repl-sym ,cljs-repl-sym)))
                     ((equal 'css-mode m)
                      `((equal 'css-mode major-mode)
                        (funcall ,f ,tooling-repl-sym ,cljs-repl-sym)))
                     ((equal 'js-mode m)
                      `((equal 'js-mode major-mode)
                        (funcall ,f ,tooling-repl-sym ,cljs-repl-sym)))
                     ((equal 'sass-mode m)
                      `((equal 'sass-mode major-mode)
                        (funcall ,f ,tooling-repl-sym ,cljs-repl-sym)))
                     ((equal 'scss-mode m)
                      `((equal 'scss-mode major-mode)
                        (funcall ,f ,tooling-repl-sym ,cljs-repl-sym)))
                     ((equal 'less-css-mode m)
                      `((equal 'less-css-mode major-mode)
                        (funcall ,f ,tooling-repl-sym ,cljs-repl-sym)))
                     ((equal 'stylus-mode m)
                      `((equal 'stylus-mode major-mode)
                        (funcall ,f ,tooling-repl-sym ,cljs-repl-sym)))
                     ((equal '-mode m)
                      `((equal 'less-mode major-mode)
                        (funcall ,f ,tooling-repl-sym ,cljs-repl-sym)))
                     ((equal 'replique/mode m)
                      `((equal 'replique/mode major-mode)
                        (funcall ,f (replique/repl-by :buffer (current-buffer)))))
                     ((equal 't m)
                      `(t ,f)))))
           modes-alist)))
    `(let* ((,tooling-repl-sym (replique/active-repl :tooling t))
            (,clj-repl-sym (replique/active-repl :clj))
            (,cljs-repl-sym (replique/active-repl :cljs))
            (,clj-buff-sym (replique/get ,clj-repl-sym :buffer))
            (,cljs-buff-sym (replique/get ,cljs-repl-sym :buffer)))
       (cond ,@dispatch-code))))

;; Auto completion

(defconst replique/annotations-map
  (replique/hash-map
   :method "me"
   :field "fi"
   :static-method "sm"
   :static-field "sf"
   :keyword "k"
   :local "l"
   :namespace "n"
   :class "c"
   :macro "m"
   :function "f"
   :var "v"
   :resource "r"
   :special-form "s"))

(defun replique/make-candidate (c)
  (map-let ((:candidate candidate) (:type type) (:package package) (:ns ns)) c
    (propertize candidate 'meta (replique/hash-map :type type :package package :ns ns))))

(defun replique/auto-complete* (prefix callback tooling-repl msg-type ns)
  (let ((tooling-chan (replique/get tooling-repl :chan)))
    (replique/send-tooling-msg
     tooling-repl
     (replique/hash-map :type msg-type
                        :context (replique/form-with-prefix)
                        :ns ns
                        :prefix prefix
                        ;; whether the cursor is in a string
                        :is-string? (not (null (nth 3 (syntax-ppss))))))
    (replique-async/<!
     tooling-chan
     (lambda (resp)
       (when resp
         (let ((err (replique/get resp :error)))
           (if err
               (progn
                 (message "%s" (replique-edn/pr-str err))
                 (message "completion failed with prefix %s" prefix))
             (let* ((candidates (replique/get resp :candidates))
                    (candidates (mapcar 'replique/make-candidate candidates)))
               (funcall callback candidates)))))))))

(defun replique/auto-complete-session (prefix callback repl)
  (let* ((directory (replique/get repl :directory))
         (tooling-repl (replique/repl-by :directory directory :repl-type :tooling))
         (repl-type (replique/get repl :repl-type))
         (msg-type (cond ((equal :clj repl-type)
                          :clj-completion)
                         ((equal :cljs repl-type)
                          :cljs-completion)
                         (t (error "Invalid REPL type: %s" repl-type))))
         (ns (symbol-name (replique/get repl :ns))))
    (replique/auto-complete* prefix callback tooling-repl msg-type ns)))

(defun replique/auto-complete-clj (prefix callback tooling-repl clj-repl)
  (when clj-repl
    (replique/auto-complete* prefix callback tooling-repl
                             :clj-completion (clojure-find-ns))))

(defun replique/auto-complete-cljs (prefix callback tooling-repl cljs-repl)
  (when cljs-repl
    (replique/auto-complete* prefix callback tooling-repl
                             :cljs-completion (clojure-find-ns))))

(defun replique/auto-complete-cljc (prefix callback tooling-repl clj-repl cljs-repl)
  (when (and clj-repl cljs-repl)
    (replique/auto-complete* prefix callback tooling-repl
                             :cljc-completion (clojure-find-ns))))

(defun replique/auto-complete (prefix callback)
  (when (not (null (replique/active-repl :tooling)))
    (replique/with-modes-dispatch
     (replique/mode . (apply-partially 'replique/auto-complete-session prefix callback))
     (clojure-mode . (apply-partially 'replique/auto-complete-clj prefix callback))
     (clojurescript-mode . (apply-partially 'replique/auto-complete-cljs prefix callback))
     (clojurec-mode . (apply-partially 'replique/auto-complete-cljc prefix callback))
     (t . (funcall callback nil)))))

(defun replique/auto-complete-annotation (candidate)
  (when-let ((meta (get-text-property 0 'meta candidate)))
    (map-let ((:type type) (:package package) (:ns ns)) meta
      (let ((type (gethash type replique/annotations-map)))
        (cond ((and ns type)
               (format "%s <%s>" ns type))
              ((and package type)
               (format "%s <%s>" package type))
              (type
               (format "<%s>" type))
              (ns
               (format "%s" ns))
              (package
               (format "%s" package))
              (t nil))))))

(defun replique/repliquedoc-format-arglist (index arglist)
  (let ((args-index 1)
        (force-highlight nil))
    (thread-first
        (lambda (arg)
          (cond ((equal '& arg)
                 (when (<= args-index index)
                   (setq force-highlight t))
                 arg)
                ((or force-highlight (equal index args-index))
                 (setq args-index (1+ args-index))
                 (replique-edn/with-face :object arg :face 'eldoc-highlight-function-argument))
                (t
                 (setq args-index (1+ args-index))
                 arg)))
      (mapcar arglist)
      (seq-into 'vector))))

(defun replique/repliquedoc-format-arglists (index arglists)
  (thread-first (lambda (x) (replique/repliquedoc-format-arglist index x))
    (mapcar arglists)
    replique-edn/print-str))

(defun replique/repliquedoc-format (msg)
  (map-let ((:name name) (:arglists arglists) (:return return) (:index index)) msg
    (cond ((and arglists return)
           (format "%s: %s -> %s"
                   name (replique/repliquedoc-format-arglists index arglists) return))
          (arglists
           (format "%s: %s" name (replique/repliquedoc-format-arglists index arglists)))
          (name (format "%s" name))
          (t nil))))

;; Eldoc expects eldoc-documentation-function to be synchronous. In order to turn the eldoc
;; response into an asynchronous one, we always return eldoc-last-message and call
;; eldoc-message ourselves later
(defun replique/repliquedoc* (tooling-repl msg-type ns)
  (let ((tooling-chan (replique/get tooling-repl :chan)))
    (when tooling-chan
      (replique/send-tooling-msg
       tooling-repl
       (replique/hash-map :type msg-type
                          :context (replique/form-with-prefix)
                          :ns ns
                          :symbol (symbol-name (symbol-at-point))))
      (replique-async/<!
       tooling-chan
       (lambda (resp)
         (when resp
           (let ((err (replique/get resp :error)))
             (if err
                 (progn
                   (message "%s" (replique-edn/pr-str err))
                   (message "eldoc failed"))
               (with-demoted-errors "eldoc error: %s"
                 (when-let ((msg (replique/repliquedoc-format (replique/get resp :doc))))
                   (eldoc-message msg))))))))))
  eldoc-last-message)

(defun replique/repliquedoc-session (repl)
  (let* ((directory (replique/get repl :directory))
         (tooling-repl (replique/repl-by :directory directory :repl-type :tooling))
         (repl-type (replique/get repl :repl-type))
         (msg-type (cond ((equal :clj repl-type)
                          :repliquedoc-clj)
                         ((equal :cljs repl-type)
                          :repliquedoc-cljs)
                         (t (error "Invalid REPL type: %s" repl-type))))
         (ns (symbol-name (replique/get repl :ns))))
    (replique/repliquedoc* tooling-repl msg-type ns)))

(defun replique/repliquedoc-clj (tooling-repl clj-repl)
  (when clj-repl
    (replique/repliquedoc* tooling-repl :repliquedoc-clj (clojure-find-ns))))

(defun replique/repliquedoc-cljs (tooling-repl cljs-repl)
  (when cljs-repl
    (replique/repliquedoc* tooling-repl :repliquedoc-cljs (clojure-find-ns))))

(defun replique/repliquedoc-cljc (tooling-repl clj-repl cljs-repl)
  (when (and clj-repl cljs-repl)
    (replique/repliquedoc* tooling-repl :repliquedoc-cljc (clojure-find-ns))))

(defun replique/eldoc-documentation-function ()
  ;; Ensures a REPL is started, since eldoc-mode is enabled globally by default
  (when (not (null (replique/active-repl :tooling)))
    (replique/with-modes-dispatch
     (replique/mode . 'replique/repliquedoc-session)
     (clojure-mode . 'replique/repliquedoc-clj)
     (clojurescript-mode . 'replique/repliquedoc-cljs)
     (clojurec-mode . 'replique/repliquedoc-cljc)
     (t . nil))))

(defun replique/in-ns-clj (ns-name tooling-repl clj-repl)
  (if (not clj-repl)
      (user-error "No active Clojure REPL")
    (replique/send-input-from-source-clj
     (format "(clojure.core/in-ns '%s)" ns-name) tooling-repl clj-repl)))

(defun replique/in-ns-cljs (ns-name tooling-repl cljs-repl)
  (if (not cljs-repl)
      (user-error "No active Clojurescript REPL")
    (replique/send-input-from-source-cljs
     (format "(replique.interactive/cljs-in-ns '%s)" ns-name)
     tooling-repl cljs-repl)))

(defun replique/in-ns-cljc (ns-name tooling-repl clj-repl cljs-repl)
  (if (not (and clj-repl cljs-repl))
      (user-error "No active Clojure AND Clojurescript REPL")
    (replique/send-input-from-source-cljc
     (format "(clojure.core/in-ns '%s)" ns-name)
     (format "(replique.interactive/cljs-in-ns '%s)" ns-name)
     tooling-repl clj-repl cljs-repl)))

(defun replique/in-ns (ns-name)
  "Change the active REPL namespace"
  (interactive (replique/symprompt "Set ns to" (clojure-find-ns)))
  (replique/with-modes-dispatch
   (clojure-mode . (apply-partially 'replique/in-ns-clj ns-name))
   (clojurescript-mode . (apply-partially 'replique/in-ns-cljs ns-name))
   (clojurec-mode . (apply-partially 'replique/in-ns-cljc ns-name))
   (t . (user-error "Unsupported major mode: %s" major-mode))))

(defun replique/symbol-backward ()
  (let ((sym-bounds (bounds-of-thing-at-point 'symbol)))
    (when sym-bounds
      (buffer-substring-no-properties (car sym-bounds) (point)))))

(defmacro replique/temporary-invisible-change (&rest forms)
  "Executes FORMS with a temporary buffer-undo-list, undoing on return.
The changes you make within FORMS are undone before returning.
But more importantly, the buffer's buffer-undo-list is not affected.
This allows you to temporarily modify read-only buffers too."
  `(let* ((buffer-undo-list)
          (modified (buffer-modified-p))
          (inhibit-read-only t)
          (temporary-res nil)
          (temporary-point (point)))
     (unwind-protect
         (setq temporary-res (progn ,@forms))
       (primitive-undo (length buffer-undo-list) buffer-undo-list)
       (set-buffer-modified-p modified)
       (goto-char temporary-point))
     temporary-res))

(defun replique/strip-text-properties(txt)
  (set-text-properties 0 (length txt) nil txt)
  txt)

(defun replique/form-with-prefix* ()
  (let ((bounds (bounds-of-thing-at-point 'symbol)))
    (replique/temporary-invisible-change
     (progn
       (when bounds (delete-region (car bounds) (cdr bounds)))
       (insert "__prefix__")
       (thing-at-point 'defun t)))))

;; Execute in a temp buffer because company-mode expects the current buffer
;; to not change at all
(defun replique/form-with-prefix ()
  (let ((defun-bounds (bounds-of-thing-at-point 'defun)))
    (when defun-bounds
      (let* ((point-offset-backward (- (cdr defun-bounds) (point)))
             (defun-content (buffer-substring (car defun-bounds)
                                              (cdr defun-bounds))))
        (with-temp-buffer
          (clojure-mode-variables)
          (set-syntax-table clojure-mode-syntax-table)
          (insert defun-content)
          (backward-char point-offset-backward)
          (replique/form-with-prefix*))))))

(defun replique/company-backend (command &optional arg &rest ignored)
  (interactive (list 'interactive))
  (cond
   ((equal command 'interactive)
    (company-begin-backend 'replique/company-backend))
   ((equal command 'prefix) (when (or (derived-mode-p 'clojure-mode)
                                      (derived-mode-p 'replique/mode))
                              (replique/symbol-backward)))
   ((equal command 'sorted) t)
   ((equal command 'candidates)
    `(:async . ,(apply-partially 'replique/auto-complete arg)))
   ((equal command 'annotation) (replique/auto-complete-annotation arg))))

(defun replique/comint-is-closed-sexpr (start limit)
  (let ((depth (car (parse-partial-sexp start limit))))
    (if (<= depth 0) t nil)))

(defun replique/comint-send-input ()
  "Send the pending comint buffer input to the comint process if the pending input is well formed and point is after the prompt"
  (interactive)
  (let* ((buff (current-buffer))
         (proc (get-buffer-process buff)))
    (if (not proc) (user-error "Current buffer has no process")
      (widen)
      (let* ((pmark (process-mark proc)))
        (cond (;; Point is at the end of the line and the sexpr is
               ;; terminated
               (and (equal (point) (point-max))
                    (replique/comint-is-closed-sexpr pmark (point)))
               (comint-send-input))
              ;; Point is after the prompt but (before the end of line or
              ;; the sexpr is not terminated)
              ((comint-after-pmark-p) (comint-accumulate))
              ;; Point is before the prompt. Do nothing.
              (t nil))))))

(defun replique/format-eval-message (msg)
  (if (replique/get msg :error)
      (let ((value (replique/get msg :value))
            (repl-type (replique/get msg :repl-type))
            (ns (replique/get msg :ns)))
        (if (string-prefix-p "Error:" value)
            (format "(%s) %s=> %s"
                    (replique/keyword-to-string repl-type) ns value)
          (format "(%s) %s=> Error: %s"
                  (replique/keyword-to-string repl-type) ns value)))
    (let ((result (replique/get msg :result))
          (repl-type (replique/get msg :repl-type))
          (ns (replique/get msg :ns)))
      (format "(%s) %s=> %s"
              (replique/keyword-to-string repl-type) ns result))))

(defun replique/display-eval-result (msg buff)
  ;; Concat to the current message in order to handle displaying results from cljc files
  ;; Note that (current-message) is cleared on any user action
  (when (not (seq-contains (replique/visible-buffers) buff))
    (let ((current-message (if (current-message)
                               (concat (current-message) "\n")
                             (current-message))))
      (thread-last (replique/format-eval-message msg)
        (concat current-message)
        replique/message-nolog))))

(defmacro replique/return-nil-on-quit (&rest body)
  (let ((ret-sym (make-symbol "ret-sym")))
    `(let ((inhibit-quit t))
       (let ((,ret-sym (with-local-quit ,@body)))
         (setq quit-flag nil)
         ,ret-sym))))

(defun replique/comint-kill-input ()
  (let ((pmark (process-mark (get-buffer-process (current-buffer)))))
    (if (> (point) (marker-position pmark))
        (let ((killed (buffer-substring-no-properties pmark (point))))
          (kill-region pmark (point))
          killed)
      "")))

(defun replique/comint-send-input-from-source (input)
  (let ((process (get-buffer-process (current-buffer))))
    (when (not process)
      (user-error "Current buffer has no process"))
    (goto-char (point-max))
    (let ((old-input (replique/comint-kill-input)))
      (goto-char (process-mark process))
      (insert input)
      (replique/comint-send-input)
      (goto-char (process-mark process))
      (insert old-input))))

(defun replique/send-input-from-source-clj (input tooling-repl clj-repl)
  (if (not clj-repl)
      (user-error "No active Clojure REPL")
    (let ((buff (replique/get clj-repl :buffer)))
      (with-current-buffer buff
        (replique/comint-send-input-from-source input)))))

(defun replique/send-input-from-source-cljs (input tooling-repl cljs-repl)
  (if (not cljs-repl)
      (user-error "No active Clojurescript REPL")
    (let ((buff (replique/get cljs-repl :buffer)))
      (with-current-buffer buff
        (replique/comint-send-input-from-source input)))))

(defun replique/send-input-from-source-cljc
    (input-clj input-cljs tooling-repl clj-repl cljs-repl)
  (if (not (and clj-repl cljs-repl))
      (user-error "No active Clojure AND Clojurescript REPL")
    (let ((clj-buff (replique/get clj-repl :buffer))
          (cljs-buff (replique/get  cljs-repl :buffer)))
      (when clj-buff
        (with-current-buffer clj-buff
          (replique/comint-send-input-from-source input-clj)))
      (when cljs-buff
        (with-current-buffer cljs-buff
          (replique/comint-send-input-from-source input-cljs))))))

(defun replique/send-input-from-source-dispatch (input)
  (replique/with-modes-dispatch
   (clojure-mode . (apply-partially 'replique/send-input-from-source-clj input))
   (clojurescript-mode . (apply-partially'replique/send-input-from-source-cljs input))
   (clojurec-mode . (apply-partially'replique/send-input-from-source-cljc input input))
   (t . (user-error "Unsupported major mode: %s" major-mode))))

(defun replique/eval-region (start end)
  "Eval the currently highlighted region"
  (interactive "r")
  (let ((input (filter-buffer-substring start end)))
    (replique/send-input-from-source-dispatch input)))

(defun replique/eval-last-sexp ()
  "Eval the previous sexp"
  (interactive)
  (replique/eval-region
   (save-excursion
     (clojure-backward-logical-sexp 1) (point))
   (point)))

(defun replique/eval-defn ()
  "Eval the top level sexpr at point"
  (interactive)
  (replique/send-input-from-source-dispatch (thing-at-point 'defun)))

(defun replique/load-file-clj (file-path props clj-repl)
  (if (not clj-repl)
      (user-error "No active Clojure REPL")
    (replique/send-input-from-source-clj
     (format "(replique.interactive/load-file \"%s\")" file-path)
     props clj-repl)))

(defun replique/load-file-cljs (file-path props cljs-repl)
  (if (not cljs-repl)
      (user-error "No active Clojurescript REPL")
    (replique/send-input-from-source-cljs
     (format "(replique.interactive/load-file \"%s\")" file-path)
     props cljs-repl)))

(defun replique/load-file-cljc (file-path props clj-repl cljs-repl)
  (if (not (and clj-repl cljs-repl))
      (user-error "No active Clojure AND Clojurescript REPL")
    (replique/send-input-from-source-cljc
     (format "(replique.interactive/load-file \"%s\")" file-path)
     (format "(replique.interactive/load-file \"%s\")" file-path)
     props clj-repl cljs-repl)))

(defun replique/load-file (file-path)
  "Load a file in a replique REPL"
  (interactive (list (buffer-file-name)))
  (comint-check-source file-path)
  (replique/with-modes-dispatch
   (clojure-mode . (apply-partially 'replique/load-file-clj file-path))
   (clojurescript-mode . (apply-partially 'replique/load-file-cljs file-path))
   (clojurec-mode . (apply-partially 'replique/load-file-cljc file-path))
   (css-mode . (apply-partially 'replique/load-css file-path))
   (js-mode . (apply-partially 'replique/load-js file-path))
   (stylus-mode . (apply-partially 'replique/load-stylus file-path))
   (scss-mode . (apply-partially 'replique/load-scss file-path))
   (sass-mode . (apply-partially 'replique/load-sass file-path))
   (less-css-mode . (apply-partially 'replique/load-less file-path))))

(defun replique/browser ()
  "Open a browser tab on the port the REPL is listening to"
  (interactive)
  (let ((cljs-repl (replique/active-repl :cljs)))
    (when (not cljs-repl)
      (user-error "No active Clojurescript REPL"))
    (browse-url (format "http://localhost:%s" (replique/get cljs-repl :port)))))

(defun replique/switch-active-repl (repl-buff-name)
  "Switch the currently active REPL session"
  (interactive
   (let* ((active-repl (replique/active-repl :tooling t))
          (directory (replique/get active-repl :directory))
          (repls (seq-filter (lambda (repl)
                               (let ((repl-type (replique/get repl :repl-type))
                                     (d (replique/get repl :directory)))
                                 (and
                                  (equal d directory)
                                  (not (equal :tooling repl-type)))))
                             replique/repls))
          (repl-names (mapcar (lambda (repl)
                                (buffer-name (replique/get repl :buffer)))
                              repls)))
     (when (null repls)
       (user-error "No started REPL"))
     (list (completing-read "Switch to REPL: " repl-names nil t))))
  ;; All windows displaying the previously active repl are set to display the newly active
  ;; repl (repl with the same repl-type)
  (let* ((buffer (get-buffer repl-buff-name))
         (repl (replique/repl-by :buffer buffer))
         (repl-type (replique/get repl :repl-type))
         (prev-active-repl (replique/repl-by :repl-type repl-type))
         (prev-active-buffer (replique/get prev-active-repl :buffer))
         (prev-active-windows (get-buffer-window-list prev-active-buffer)))
    (setq replique/repls (delete repl replique/repls))
    (setq replique/repls (push repl replique/repls))
    (mapcar (lambda (window)
              (set-window-buffer window buffer))
            prev-active-windows)))

(defun replique/switch-active-process (proc-name)
  "Switch the currently active JVM process"
  (interactive
   (let* ((tooling-repls (replique/repls-by :repl-type :tooling))
          (directories (mapcar (lambda (repl) (replique/get repl :directory))
                               tooling-repls)))
     (when (not (car directories))
       (user-error "No started REPL"))
     (list (completing-read "Switch to process: " directories nil t))))
  (let* ((new-active-repls (replique/repls-by :directory proc-name))
         (prev-active-tooling-repl (replique/active-repl :tooling))
         (prev-active-directory (replique/get prev-active-tooling-repl :directory))
         (prev-repls (replique/repls-by :directory prev-active-directory))
         (prev-repl-types (mapcar (lambda (repl) (replique/get repl :repl-type)) prev-repls)))
    ;; All windows displaying the previously active repls are set to display the newly active
    ;; repls (repl with the same repl-type and same position in the replique/repls list)
    (dolist (repl-type prev-repl-types)
      (let* ((prev-active-repl (replique/repl-by :directory prev-active-directory
                                                 :repl-type repl-type))
             (prev-buffer (replique/get prev-active-repl :buffer))
             (new-active-repl (replique/repl-by
                               :directory proc-name
                               :repl-type repl-type))
             (new-buffer (replique/get new-active-repl :buffer))
             (windows (get-buffer-window-list prev-buffer)))
        (when new-buffer
          (dolist (window windows)
            (set-window-buffer window new-buffer)))))
    (dolist (repl (seq-reverse new-active-repls))
      (setq replique/repls (delete repl replique/repls))
      (setq replique/repls (push repl replique/repls)))))

(defun replique/list-cljs-namespaces (tooling-repl)
  (let ((tooling-chan (replique/get tooling-repl :chan))
        (out-chan (replique-async/chan)))
    (replique/send-tooling-msg
     tooling-repl
     (replique/hash-map :type :list-cljs-namespaces))
    (replique-async/<!
     tooling-chan
     (lambda (resp)
       (when resp
         (let ((err (replique/get resp :error)))
           (if err
               (progn
                 (message "%s" (replique-edn/pr-str err))
                 (message "list-cljs-namespaces failed")
                 (replique-async/close! out-chan))
             (replique-async/put! out-chan resp))))))
    out-chan))

(defun replique/cljs-repl ()
  "Start a Clojurescript REPL in the currently active Clojure REPL"
  (interactive)
  (let* ((tooling-repl (replique/active-repl :tooling t))
         (clj-repl (replique/active-repl :clj)))
    (when (not clj-repl)
      (user-error "No active Clojure REPL"))
    (replique/send-input-from-source-clj
     "(replique.interactive/cljs-repl)" tooling-repl clj-repl)))

(defun replique/output-main-js-file (output-to &optional main-ns)
  "Write a main javascript file to disk. The main javascript file acts as an entry point to your application and contains code to connect to the Clojurescript REPL"
  (interactive (list nil))
  (let* ((tooling-repl (replique/active-repl :tooling t))
         (tooling-chan (replique/get tooling-repl :chan)))
    (when-let ((output-to (or
                           output-to
                           (read-file-name "Output main js file to: "
                                           (replique/get tooling-repl :directory)))))
      (let ((output-to (file-truename output-to)))
        (when (file-directory-p output-to)
          (user-error "%s is a directory" output-to))
        (when (or (not (file-exists-p output-to))
                  (yes-or-no-p (format "Override %s?" output-to))) 
          (replique-async/<!
           (if main-ns
               (replique-async/default-chan (replique/hash-map :namespaces nil))
             (replique/list-cljs-namespaces tooling-repl))
           (lambda (resp)
             (when resp
               (let* ((namespaces (replique/get resp :namespaces))
                      (main-ns (cond (main-ns main-ns)
                                     ((seq-empty-p namespaces) nil)
                                     (t (replique/return-nil-on-quit
                                         (completing-read "Main Clojurescript namespace: "
                                                          namespaces nil t nil nil '(nil)))))))
                 (replique/send-tooling-msg
                  tooling-repl
                  (replique/hash-map :type :output-main-js-files
                                     :output-to output-to
                                     :main-ns main-ns))
                 (replique-async/<!
                  tooling-chan
                  (lambda (resp)
                    (when resp
                      (let ((err (replique/get resp :error)))
                        (if err
                            (progn
                              (message "%s" (replique-edn/pr-str err))
                              (message "output-main-js-file failed"))
                          (message "Main javascript file written to: %s" output-to)
                          ))))))))))))))

;; I don't know why goog/deps.js is needed here but is not needed in the init script returned
;; by the cljs repl
;; Wait a second before connecting to the cljs repl because there is no way to plug into
;; the goog.require loading mechanism
(defun replique/cljs-repl-connection-script ()
  (interactive)
  (let* ((tooling-repl (replique/active-repl :tooling t))
         (port (replique/get tooling-repl :port))
         (script (format "(function() {
  var scripts = [];
  var makeScript = function() {
    var script = document.createElement(\"script\");
    scripts.push(script);
    return script;
  }
  var execScripts = function() {
    if(scripts.length > 0) {
      scripts[0].onload = execScripts;
      document.body.appendChild(scripts.shift());
    }
  }
  makeScript().src = \"http://localhost:%s/goog/base.js\";
  makeScript().src = \"http://localhost:%s/goog/deps.js\";
  makeScript().src = \"http://localhost:%s/cljs_deps.js\";
  makeScript().src = \"http://localhost:%s/replique/cljs_env/bootstrap.js\";
  makeScript().textContent = \"goog.require(\\\"replique.cljs_env.repl\\\"); goog.require(\\\"replique.cljs_env.browser\\\");\";
  execScripts();
  setTimeout(function(){replique.cljs_env.repl.connect(\"http://localhost:%s\");}, 1000);
})();" port port port port port)))
    (kill-new script)
    (message script)))

(defun replique/list-css (tooling-repl)
  (let ((tooling-chan (replique/get tooling-repl :chan))
        (out-chan (replique-async/chan)))
    (replique/send-tooling-msg
     tooling-repl
     (replique/hash-map :type :list-css))
    (replique-async/<!
     tooling-chan
     (lambda (resp)
       (when resp
         (let ((err (replique/get resp :error)))
           (if err
               (progn
                 (message "%s" (replique-edn/pr-str err))
                 (message "list-css failed")
                 (replique-async/close! out-chan))
             (replique-async/put! out-chan resp))))))
    out-chan))

(defun replique/asset-url-matches? (file-name url)
  (let ((url-filename (file-name-nondirectory (url-filename (url-generic-parse-url url)))))
    (equal file-name url-filename)))

(defvar replique/css-prefered-files (replique/hash-map))

;; Choose a css url either by looking into replique/css-prefered-files (if the user already
;; has chosen one before) or by prompting the user
(defun replique/select-css-url (file-path css-urls)
  (or (replique/get replique/css-prefered-files file-path)
      (let ((selected-url (completing-read "Select the css file to reload: " css-urls nil t)))
        (setq replique/css-prefered-files (replique/assoc replique/css-prefered-files
                                                          file-path selected-url))
        selected-url)))

(defun replique/load-css (file-path tooling-repl cljs-repl)
  (when (not cljs-repl)
    (user-error "No active Clojurescript REPL"))
  (let ((tooling-chan (replique/get tooling-repl :chan)))
    (replique-async/<!
     (replique/list-css tooling-repl)
     (lambda (resp)
       (when resp
         (let* ((css-urls (replique/get resp :css-urls))
                (css-urls (seq-filter (apply-partially 'replique/asset-url-matches?
                                                       (file-name-nondirectory file-path))
                                      css-urls))
                (selected-url (cond ((equal 0 (length css-urls))
                                     ;; No stylesheet matches, do nothing
                                     nil)
                                    ((equal 1 (length css-urls))
                                     ;; Reload the stylesheet that matches
                                     (car css-urls))
                                    (t (replique/select-css-url file-path css-urls)))))
           (if (null selected-url)
               (message "Could not find a css file to reload")
             (replique/send-tooling-msg
              tooling-repl
              (replique/hash-map :type :load-css
                                 :url selected-url))
             (replique-async/<!
              tooling-chan
              (lambda (resp)
                (when resp
                  (let ((err (replique/get resp :error)))
                    (if err
                        (progn
                          (message "%s" (replique-edn/pr-str err))
                          (message "load-css %s: failed" file-path))
                      (message "load-css %s: done" file-path)))))))))))))

(defun replique/load-js (file-path tooling-repl cljs-repl)
  (when (not cljs-repl)
    (user-error "No active Clojurescript REPL"))
  (let ((tooling-chan (replique/get tooling-repl :chan)))
    (replique/send-tooling-msg
     tooling-repl
     (replique/hash-map :type :load-js :file-path file-path))
    (replique-async/<!
     tooling-chan
     (lambda (resp)
       (when resp
         (let ((err (replique/get resp :error)))
           (if err
               (progn
                 (message "%s" (replique-edn/pr-str err))
                 (message "load-js %s: failed" file-path))
             (message "load-js %s: done" file-path))))))))

;; {directory {css-preprocessor-type {:output-files {output-file main-source-file}
;;                                   {:last-selected-output-file output-file}}}}
;; When the user triggers a compilation, he is prompted for an output css file. The
;; compilation is performed using the main source file.
(defvar replique/css-preprocessors-output-files (replique/hash-map))

;; Move x to the first position in coll
(defun replique/move-to-front (coll x)
  (when (and coll (seq-contains coll x))
    (thread-last coll
      (seq-remove (lambda (y) (equal x y)))
      (cons x))))

(defcustom replique/stylus-executable "stylus"
  "Stylus executable path"
  :type 'string
  :group 'replique)

(defun replique/stylus-args-builder-default (input output)
  (list "-m" "--sourcemap-inline" "--out" output input))

(defvar replique/stylus-args-builder 'replique/stylus-args-builder-default
  "Function that returns the command to use when compiling stylus files")

(defcustom replique/sass-executable "sass"
  "Sass executable path"
  :type 'string
  :group 'replique)

(defun replique/sass-args-builder-default (input output)
  (list "--sourcemap=inline" input output))

(defvar replique/sass-args-builder 'replique/sass-args-builder-default
  "Function that returns the command to use when compiling sass files")

(defcustom replique/scss-executable "scss"
  "Scss executable path"
  :type 'string
  :group 'replique)

(defun replique/scss-args-builder-default (input output)
  (list "--sourcemap=inline" input output))

(defvar replique/scss-args-builder 'replique/scss-args-builder-default
  "Function that returns the command to use when compiling scss files")

(defcustom replique/less-executable "lessc"
  "Scss executable path"
  :type 'string
  :group 'replique)

(defun replique/less-args-builder-default (input output)
  (list "--source-map" "--source-map-less-inline" input output))

(defvar replique/less-args-builder 'replique/less-args-builder-default
  "Function that returns the command to use when compiling less files")

(defun replique/load-css-preprocessor
    (type executable args-builder file-path tooling-repl cljs-repl)
  (when (not cljs-repl)
    (user-error "No active Clojurescript REPL"))
  (let* ((tooling-chan (replique/get tooling-repl :chan))
         (directory (replique/get tooling-repl :directory))
         (output-files (replique/get-in replique/css-preprocessors-output-files
                                        `[,directory ,type :output-files]))
         (output-files (replique/keys output-files))
         (last-selected-output-file (replique/get-in
                                     replique/css-preprocessors-output-files
                                     `[,directory ,type :last-selected-output-file]))
         (output-files (replique/move-to-front output-files last-selected-output-file))
         ;; We don't want ivy to sort candidates by alphabetical order
         (ivy-sort-functions-alist nil)
         (output (if output-files
                     (completing-read "Compile to file: "
                                      ;; All candidates are lists in order for completing-read
                                      ;; to keep the order of the candidates
                                      (replique/presorted-completion-table
                                       (append output-files '("*new-file*")))
                                      nil t)
                   "*new-file*"))
         (is-new-file (equal output "*new-file*"))
         (output (if is-new-file
                     (read-file-name "Compile to file: "
                                     (replique/get tooling-repl :directory)
                                     nil t)
                   output))
         (main-source-file (if is-new-file
                               file-path
                             (replique/get-in replique/css-preprocessors-output-files
                                              `[,directory ,type :output-files ,output])))
         (output (file-truename output))
         (command-result 0))
    (when (file-directory-p output)
      (user-error "%s is a directory" output))
    (when (or (not is-new-file)
              (not (file-exists-p output))
              (yes-or-no-p (format "Override %s?" output)))
      (with-temp-buffer
        (setq command-result (apply 'call-process executable nil t nil
                                    (funcall args-builder main-source-file output)))
        (when (not (equal 0 command-result))
          (ansi-color-apply-on-region (point-min) (point-max))
          (message (buffer-substring (point-min) (point-max)))))
      (when (equal 0 command-result)
        (setq replique/css-preprocessors-output-files
              (replique/update-in
               replique/css-preprocessors-output-files
               `[,directory ,type]
               (lambda (x)
                 (thread-first x
                   (replique/assoc :last-selected-output-file output)
                   (replique/assoc-in `[:output-files ,output] main-source-file)))))
        (replique/load-css output tooling-repl cljs-repl)))))

(defun replique/load-stylus (file-path tooling-repl cljs-repl)
  (replique/load-css-preprocessor :stylus replique/stylus-executable
                                  replique/stylus-args-builder
                                  file-path tooling-repl cljs-repl))


(defun replique/load-scss (file-path tooling-repl cljs-repl)
  (replique/load-css-preprocessor :scss replique/scss-executable
                                  replique/scss-args-builder
                                  file-path tooling-repl cljs-repl))

(defun replique/load-sass (file-path tooling-repl cljs-repl)
  (replique/load-css-preprocessor :sass replique/sass-executable
                                  replique/sass-args-builder
                                  file-path tooling-repl cljs-repl))

(defun replique/load-less (file-path tooling-repl cljs-repl)
  (replique/load-css-preprocessor :less replique/less-executable
                                  replique/less-args-builder
                                  file-path tooling-repl cljs-repl))

(defun replique/eval-form (repl-type form-s)
  (let ((repl (replique/active-repl repl-type)))
    (if (null repl)
        (format "No active %s REPL" repl-type)
      (let* ((form-s (replace-regexp-in-string "\n" " " form-s))
             (tooling-repl (replique/active-repl :tooling t))
             (tooling-chan (replique/get tooling-repl :chan))
             (msg-type (thread-last (replique/keyword-to-string repl-type)
                         (concat ":eval-")
                         (make-symbol)))
             (done nil)
             (result nil)
             (p (start-process "eval-form-proc" nil nil)))
        (replique/send-tooling-msg
         tooling-repl
         (replique/hash-map :type msg-type :form form-s))
        (replique-async/<!
         tooling-chan
         (lambda (resp)
           (when resp
             (let ((err (replique/get resp :error)))
               (if err
                   (setq result (replique-edn/pr-str err))
                 (setq result (replique/get resp :result)))))
           (setq done t)
           (kill-process p)))
        ;; We are polling because accept-process-output does not work well with
        ;; run-at-time (replique-async)
        (while (not done)
          (accept-process-output p 0 200))
        result))))

(defun replique/jump-to-definition* (symbol tooling-repl msg-type)
  (let ((tooling-chan (replique/get tooling-repl :chan)))
    (replique/send-tooling-msg
     tooling-repl
     (replique/hash-map :type msg-type
                        :ns (clojure-find-ns)
                        :symbol symbol
                        ;; whether the cursor is in a string
                        :is-string? (not (null (nth 3 (syntax-ppss))))
                        :context (replique/form-with-prefix)))
    (replique-async/<!
     tooling-chan
     (lambda (resp)
       (when resp
         (let ((err (replique/get resp :error)))
           (if err
               (progn
                 (message "%s" (replique-edn/pr-str err))
                 (message "jump-to-definition failed with symbol: %s" symbol))
             (let* ((meta (replique/get resp :meta))
                    (file (replique/get-in resp [:meta :file]))
                    (line (replique/get-in resp [:meta :line]))
                    (column (replique/get-in resp [:meta :column])))
               (when-let (buff (replique-resources/find-file file))
                 (xref-push-marker-stack)
                 (pop-to-buffer-same-window buff)
                 (goto-char (point-min))
                 (when line
                   (forward-line (1- line))
                   (when column
                     (move-to-column column))))))))))))

(defun replique/jump-to-definition-session (symbol repl)
  (let* ((directory (replique/get repl :directory))
         (tooling-repl (replique/repl-by :directory directory :repl-type :tooling))
         (repl-type (replique/get repl :repl-type))
         (msg-type (cond ((equal :clj repl-type)
                          :meta-clj)
                         ((equal :cljs repl-type)
                          :meta-cljs)
                         (t (error "Invalid REPL type: %s" repl-type))))
         (ns (symbol-name (replique/get repl :ns))))
    (replique/jump-to-definition* symbol tooling-repl msg-type)))

(defun replique/jump-to-definition-clj (symbol tooling-repl clj-repl)
  (if (not clj-repl)
      (user-error "No active Clojure REPL")
    (replique/jump-to-definition* symbol tooling-repl :meta-clj)))

(defun replique/jump-to-definition-cljs (symbol tooling-repl cljs-repl)
  (if (not cljs-repl)
      (user-error "No active Clojurescript REPL")
    (replique/jump-to-definition* symbol tooling-repl :meta-cljs)))

(defun replique/jump-to-definition-cljc (symbol tooling-repl clj-repl cljs-repl)
  (if (not (and clj-repl cljs-repl))
      (user-error "No active Clojure AND Clojurescript REPL")
    (replique/jump-to-definition* symbol tooling-repl :meta-cljc)))

(defun replique/jump-to-definition (symbol)
  "Jump to symbol at point definition, if the metadata for the symbol at point contains enough information"
  (interactive (list (symbol-name (symbol-at-point))))
  (replique/with-modes-dispatch
   (replique/mode . (apply-partially 'replique/jump-to-definition-session symbol))
   (clojure-mode . (apply-partially 'replique/jump-to-definition-clj symbol))
   (clojurescript-mode . (apply-partially 'replique/jump-to-definition-cljs symbol))
   (clojurec-mode . (apply-partially 'replique/jump-to-definition-cljc symbol))
   (t . (user-error "Unsupported major mode: %s" major-mode))))

(defconst replique/client-version "0.0.5-SNAPSHOT")

(defcustom replique/version "0.0.5-SNAPSHOT"
  "Hook for customizing the version of the replique REPL server to be used"
  :type 'string
  :group 'replique)

(defcustom replique/prompt "^[^=> \n]+=> *"
  "Regexp to recognize prompts in the replique mode."
  :type 'regexp
  :group 'replique)

(defcustom replique/prompt-read-only t
  "Whether to make the prompt read-only or not"
  :type 'boolean
  :group 'replique)

(defcustom replique/lein-script nil
  "Leiningen script path"
  :type 'file
  :group 'replique)

(defcustom replique/default-lein-script "lein"
  "Name of the lein script to be used when replique/lein-script is not set. The script will 
be searched in exec-path."
  :type 'string
  :group 'replique)

(defcustom replique/host "localhost"
  "Replique REPLs listening socket host"
  :type 'string
  :group 'replique)

(defcustom replique/main-js-files-max-depth 5
  "Maximum directory nesting when search for main js files. Set to a negative value to
disable main js files refreshing."
  :type 'integer
  :group 'replique)

(defcustom replique/company-tooltip-align-annotations t
  "See company-tooltip-align-annotations"
  :type 'boolean
  :group 'replique)

(defvar replique/mode-hook '()
  "Hook for customizing replique mode.")

(defvar replique/mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map comint-mode-map)
    (define-key map "\C-m" 'replique/comint-send-input)
    (define-key map "\C-xr" 'replique/switch-active-repl)
    (define-key map "\M-." 'replique/jump-to-definition)
    map))

(defun replique/commons ())

(define-derived-mode replique/mode comint-mode "Replique"
  "Commands:\\<replique/mode-map>"
  (setq-local comint-prompt-regexp replique/prompt)
  (setq-local comint-prompt-read-only replique/prompt-read-only)
  (clojure-mode-variables)
  (clojure-font-lock-setup)
  (set-syntax-table clojure-mode-syntax-table)
  (when (boundp 'company-backends)
    (add-to-list 'company-backends 'replique/company-backend)
    (setq-local company-tooltip-align-annotations
    	      replique/company-tooltip-align-annotations))
  (add-function :before-until (local 'eldoc-documentation-function)
                'replique/eldoc-documentation-function))

(defvar replique/minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\C-c\C-r" 'replique/eval-region)
    (define-key map "\C-x\C-e" 'replique/eval-last-sexp)
    (define-key map "\C-\M-x" 'replique/eval-defn)
    (define-key map "\C-c\C-l" 'replique/load-file)
    (define-key map "\C-c\M-n" 'replique/in-ns)
    (define-key map "\C-xr" 'replique/switch-active-repl)
    (define-key map "\M-." 'replique/jump-to-definition)
    (define-key map "\M-," 'xref-pop-marker-stack)
    (easy-menu-define replique/minor-mode-menu map
      "Replique Minor Mode Menu"
      '("Replique"
        ["Eval region" replique/eval-region t]
        ["Eval last sexp" replique/eval-last-sexp t]
        ["Eval defn" replique/eval-defn t]
        "--"
        ["Load file" replique/load-file t]
        "--"
        ["Set REPL ns" replique/in-ns t]
        "--"
        ["Switch active REPL" replique/switch-active-repl t]
        "--"
        ["Jump to definition" replique/jump-to-definition t]
        ))
    map))

;;;###autoload
(define-minor-mode replique/minor-mode
  "Minor mode for interacting with the replique process buffer.

The following commands are available:

\\{replique/minor-mode-map}"
  :lighter "Replique" :keymap replique/minor-mode-map
  (when (boundp 'company-backends)
    (add-to-list 'company-backends 'replique/company-backend)
    (setq-local company-tooltip-align-annotations
                replique/company-tooltip-align-annotations))
  (add-function :before-until (local 'eldoc-documentation-function)
                'replique/eldoc-documentation-function))

;; lein update-in :plugins conj "[replique/replique \"0.0.1-SNAPSHOT\"]" -- trampoline replique

(defun replique/lein-command (host port directory)
  `(,(or replique/lein-script (executable-find replique/default-lein-script))
    "update-in" ":plugins" "conj" 
    ,(format "[replique/replique \"%s\"]" replique/version)
    "--"
    "trampoline" "replique"
    ,(format "%s" host) ,(format "%s" port)
    ,(format "%s" directory)))

(defun replique/process-filter-chan (proc)
  (let ((chan (replique-async/chan)))
    (set-process-filter
     proc (lambda (proc string)
            (replique-async/put! chan string)))
    chan))

(defun replique/is-valid-port-nb? (port-nb)
  (< -1 port-nb 65535))

(defun replique/send-tooling-msg (tooling-repl msg)
  (let* ((tooling-network-proc (replique/get tooling-repl :network-proc))
         (process-id (replique/get tooling-repl :directory))
         (msg (replique/assoc msg :process-id process-id)))
    (process-send-string
     tooling-network-proc
     (format "(replique.tooling-msg/tooling-msg-handle %s)\n"
             (replique-edn/pr-str msg)))))

(defun replique/close-tooling-repl (tooling-repl)
  (let ((tooling-proc (replique/get tooling-repl :proc)))
    (when (process-live-p tooling-proc)
      ;; SIGINT, the jvm should stop, even if there is pending non daemon threads, shutdown
      ;; hooks should run
      (interrupt-process tooling-proc))
    (setq replique/repls (delete tooling-repl replique/repls))))

(defun replique/maybe-close-tooling-repl (host port)
  (let ((other-repls (replique/repls-by :host host :port port)))
    (when (seq-every-p (lambda (repl)
                         (equal :tooling (replique/get repl :repl-type)))
                       other-repls)
      (mapcar (lambda (tooling-repl)
                (replique/close-tooling-repl tooling-repl))
              other-repls))))

(defun replique/close-repl (repl kill-buffers)
  (let* ((buffer (replique/get repl :buffer))
         (host (replique/get repl :host))
         (port (replique/get repl :port))
         (proc (get-buffer-process buffer)))
    (when proc
      (set-process-sentinel proc nil)
      (delete-process proc))
    (if kill-buffers
        (kill-buffer buffer)
      (with-current-buffer buffer
        ;; Disable replique/mode
        (fundamental-mode)
        (save-excursion
          (goto-char (point-max))
          (insert (concat "\nConnection broken by remote peer\n")))))
    (setq replique/repls (delete repl replique/repls))
    ;; If the only repl left is a tooling repl, let's close it
    (replique/maybe-close-tooling-repl host port)))

(defun replique/close-repls (host port kill-buffers)
  (let* ((repls (replique/repls-by :host host :port port))
         (not-tooling-repls (seq-filter (lambda (repl)
                                          (not (equal :tooling (replique/get repl :repl-type))))
                                        repls))
         (tooling-repls (seq-filter (lambda (repl)
                                      (equal :tooling (replique/get repl :repl-type)))
                                    repls)))
    (dolist (repl not-tooling-repls)
      (replique/close-repl repl kill-buffers))
    (dolist (tooling-repl tooling-repls)
      (replique/close-tooling-repl tooling-repl))))

(defun replique/on-repl-close (buffer process event)
  (let ((closing-repl (replique/repl-by :buffer buffer)))
    (when closing-repl
      (cond ((string= "deleted\n" event)
             (replique/close-repl closing-repl t))
            ((string= "connection broken by remote peer\n" event)
             (replique/close-repl closing-repl nil))
            (t nil)))))

(defun replique/on-tooling-repl-close (network-proc-buffer host port process event)
  (cond ((string= "deleted\n" event)
         (replique/close-repls host port t))
        ((string= "connection broken by remote peer\n" event)
         (replique/close-repls host port nil))
        (t nil))
  (replique/kill-process-buffer network-proc-buffer))

(defun replique/check-lein-script ()
  (cond ((and replique/lein-script (not (executable-find replique/lein-script)))
         (format "Error while starting the REPL. %s could not be find in exec-path. Please update replique/lein-script" replique/lein-script))
        ((and (not replique/lein-script) (not (executable-find replique/default-lein-script)))
         "Error while starting the REPL. No lein script found in exec-path")
        (t nil)))

(defun replique/skip-repl-starting-output* (proc-chan filtered-chan)
  (let ((started-regexp (format "Replique version %s listening on port \\([0-9]+\\)\n"
                                replique/version)))
    (replique-async/<!
     proc-chan (lambda (msg)
                 ;; REPL is started
                 (if (string-match started-regexp msg)
                     (thread-last (match-string 1 msg)
                       string-to-number
                       (replique-async/put! filtered-chan))                   
                   ;; REPL is still starting. Print all the init messages
                   (message "%s" msg)
                   (replique/skip-repl-starting-output* proc-chan filtered-chan))))))

(defun replique/skip-repl-starting-output (proc-chan)
  (let ((filtered-chan (replique-async/chan)))
    (replique/skip-repl-starting-output* proc-chan filtered-chan)
    filtered-chan))

(defun replique/is-main-js-file (f)
  (let* ((first-line "//main-js-file autogenerated by replique")
         (check-length (length first-line)))
    (and (file-exists-p f)
         (condition-case err
             (with-temp-buffer
               (insert-file-contents f nil 0 check-length)
               (equal (buffer-substring-no-properties 1 (+ 1 check-length)) first-line))
           (error nil)))))

(defun replique/directory-files-recursively (dir regexp exclude-dir max-depth)
  (let ((exclude-dir (expand-file-name exclude-dir dir))
        (result nil)
        (files nil))
    (unless (< max-depth 0)
        (dolist (file (file-name-all-completions "" dir))
          (unless (member file '("./" "../"))
            (if (directory-name-p file)
                (let* ((leaf (substring file 0 (1- (length file))))
                       (full-file (expand-file-name leaf dir)))
                  ;; Don't follow symlinks to other directories.
                  (unless (or (file-symlink-p full-file) (equal full-file exclude-dir))
                    (setq result
                          (nconc result (replique/directory-files-recursively
                                         full-file regexp exclude-dir (1- max-depth))))))
              (when (string-match-p regexp file)
                (push (expand-file-name file dir) files))))))
    (nconc result files)))

(defun replique/refresh-main-js-files (directory port cljs-compile-path)
  (message "Refreshing main js files ...")
  (let* ((js-files (replique/directory-files-recursively
                    directory "\\.js$" cljs-compile-path replique/main-js-files-max-depth))
         (main-js-files (seq-filter 'replique/is-main-js-file js-files)))
    (dolist (f main-js-files)
      (with-temp-file f
        (insert-file-contents f)
        (save-match-data
          (when (re-search-forward "var port = \'[0-9]+\';" nil t)
            (replace-match (format "var port = \'%s\';" port))))
        (buffer-substring-no-properties 1 (point-max))))
    (message "Refreshing main js files ... %s files refreshed" (length main-js-files))))

;; Used to regroup output from the process standard output
(defvar-local proc-out nil)

(defun replique/make-tooling-repl (host port directory)
  (let* ((out-chan (replique-async/chan))
         (default-directory directory)
         (repl-cmd (replique/lein-command host port directory))
         (proc (apply 'start-process directory nil (car repl-cmd) (cdr repl-cmd)))
         (proc-chan (replique/skip-repl-starting-output (replique/process-filter-chan proc))))
    (replique-async/<!
     proc-chan
     (lambda (port)
       ;; Print process messages
       (set-process-filter proc (lambda (proc string)
                                  ;; We avoid to split the standard process output in multiple
                                  ;; messages (because of buffering)
                                  (if (null proc-out)
                                      (thread-last string
                                        (format "Process %s: %s" (process-name proc))
                                        (concat proc-out)
                                        (setq proc-out))
                                    (setq proc-out (concat proc-out string)))
                                  (when (not (accept-process-output proc 0 0 t))
                                    (message "%s" proc-out)
                                    (setq proc-out nil))))
       (let* ((network-proc-buff (generate-new-buffer (format " *%s*" directory)))
              (network-proc (open-network-stream directory nil host port))
              (tooling-chan (replique/process-filter-chan network-proc))
              (timeout (run-at-time 2 nil (lambda ()
                                            (replique-async/put! tooling-chan :timeout)))))
         (set-process-sentinel
          network-proc
          (apply-partially
           'replique/on-tooling-repl-close network-proc-buff host port))
         ;; The REPL accept fn will read a char in order to check whether the request
         ;; is an HTTP one or not
         (process-send-string network-proc "R")
         ;; No need to wait for the return value of shared-tooling-repl
         ;; since it does not print anything
         (process-send-string
          network-proc "(replique.repl/shared-tooling-repl :elisp)\n")
         (process-send-string network-proc "replique.utils/cljs-compile-path\n")
         (replique-async/<!
          tooling-chan
          (lambda (cljs-compile-path)
            (cancel-timer timeout)
            (if (equal :timeout cljs-compile-path)
                (progn
                  (message "Error while starting the REPL. The port number may already be used by another process")
                  (when (process-live-p proc)
                    (interrupt-process proc)))
              (let* (;; cljs compile path do not come from a read chan
                     (cljs-compile-path (read cljs-compile-path))
                     (tooling-chan (thread-first tooling-chan
                                     (replique/read-chan network-proc network-proc-buff)
                                     replique/dispatch-tooling-msg))
                     (tooling-repl (replique/hash-map
                                    :directory directory
                                    :repl-type :tooling
                                    :proc proc
                                    :network-proc network-proc
                                    :host host
                                    :port port
                                    :chan tooling-chan)))
                (push tooling-repl replique/repls)
                (replique-async/put! out-chan tooling-repl)
                (when (>= replique/main-js-files-max-depth 0)
                  (replique/refresh-main-js-files directory port cljs-compile-path)))))))))
    out-chan))

(defun replique/close-process (directory)
  "Close all the REPL sessions associated with a JVM process"
  (interactive
   (let* ((tooling-repls (replique/repls-by :repl-type :tooling :error-on-nil t))
          (directories (mapcar (lambda (repl) (replique/get repl :directory)) tooling-repls)))
     (list (completing-read "Close process: " directories nil t))))
  (let* ((tooling-repl (replique/repl-by :repl-type :tooling :directory directory))
         (host (replique/get tooling-repl :host))
         (port (replique/get tooling-repl :port)))
    (replique/close-repls host port t)))

(defun replique/make-comint (proc buffer)
  (with-current-buffer buffer
    (unless (derived-mode-p 'comint-mode)
      (comint-mode))
    (set-process-filter proc 'comint-output-filter)
    (setq-local comint-ptyp process-connection-type)
    ;; Jump to the end, and set the process mark.
    (goto-char (point-max))
    (set-marker (process-mark proc) (point))
    (run-hooks 'comint-exec-hook)
    buffer))

(defun replique/make-repl (buffer-name directory host port)
  (let* ((buff (generate-new-buffer buffer-name))
         (proc (open-network-stream buffer-name buff host port))
         (chan-src (replique/process-filter-chan proc))
         (repl-cmd (format "(replique.repl/repl)\n")))
    (set-process-sentinel proc (apply-partially 'replique/on-repl-close buff))
    ;; The REPL accept fn will read a char in order to check whether the request
    ;; is an HTTP one or not
    (process-send-string proc "R")
    (let ((chan (replique/read-chan chan-src proc buff)))
      (process-send-string proc "replique.server/*session*\n")
      (replique-async/<!
       chan
       (lambda (resp)
         (let ((session (replique/get resp :client)))
           (set-process-filter proc nil)
           (replique/make-comint proc buff)
           (set-buffer buff)
           (replique/mode)
           (process-send-string proc repl-cmd)
           (let ((repl (replique/hash-map :directory directory
                                          :host host
                                          :port port
                                          :repl-type :clj
                                          :session session
                                          :ns 'user
                                          :buffer buff)))
             (push repl replique/repls)
             (display-buffer buff))))))))

(defun replique/clj-buff-name (directory)
  (generate-new-buffer-name
   (format "*replique*%s*clj*" (file-name-nondirectory (directory-file-name directory)))))

(defun replique/normalize-directory-name (directory)
  (file-name-as-directory (expand-file-name directory)))

;;;###autoload
(defun replique/repl (directory &optional port buffer-name)
  "Start a REPL session"
  (interactive
   (let ((directory (read-directory-name
                     "Project directory: " (replique/guess-project-root-dir) nil t)))
     ;; Normalizing the directory name is necessary in order to be able to find repls
     ;; by directory name
     (list (replique/normalize-directory-name directory))))
  (let* ((existing-repl (replique/repl-by :directory directory :repl-type :tooling))
         (host replique/host)
         (port (cond
                (port port)
                (existing-repl
                 (replique/get existing-repl :port))
                (t (read-number "Port number: " 0))))
         (lein-script-error (replique/check-lein-script)))
    (cond
     ((not (replique/is-valid-port-nb? port))
      (user-error "Invalid port number: %d" port))
     (lein-script-error
      (user-error lein-script-error))
     (t
      (replique-async/<!
       (if existing-repl
           (replique-async/default-chan existing-repl)
         (replique/make-tooling-repl host port directory))
       (lambda (tooling-repl)
         (let ((directory (replique/get tooling-repl :directory))
               (port (replique/get tooling-repl :port))
               (buffer-name (or buffer-name (replique/clj-buff-name directory))))
           (condition-case err
               (replique/make-repl buffer-name directory host port)
             (error
              (replique/maybe-close-tooling-repl host port)
              ;; rethrow the error
              (signal (car err) (cdr err)))))))))))

(defun replique/on-repl-type-change (repl new-repl-type)
  (let* ((directory (replique/get repl :directory))
         (repl-type (replique/get repl :repl-type))
         (repl-type-s (replique/keyword-to-string repl-type))
         (new-repl-type-s (replique/keyword-to-string new-repl-type))
         (repl-buffer (replique/get repl :buffer)))
    (when (not (equal repl-type new-repl-type))
      (when (string-match-p (format "\\*%s\\*\\(<[0-9]+>\\)?$" repl-type-s)
                            (buffer-name repl-buffer))
        (let* ((new-buffer-name (replace-regexp-in-string
                                 (format "\\*%s\\*\\(<[0-9]+>\\)?$" repl-type-s)
                                 (format "*%s*" new-repl-type-s)
                                 (buffer-name repl-buffer))))
          (with-current-buffer repl-buffer
            (rename-buffer (generate-new-buffer-name new-buffer-name)))))
      (replique/update-repl repl (replique/assoc repl :repl-type new-repl-type)))))

(defun replique/dispatch-tooling-msg* (in-chan out-chan)
  (replique-async/<!
   in-chan
   (lambda (msg)
     (condition-case err
         (cond
          ((not (hash-table-p msg))
           (message "Received invalid message while dispatching tooling messages: %s" msg))
          (;; Global error (uncaught exception)
           (and
            (replique/get msg :error)
            (replique/get msg :thread))
           (message "%s - Thread: %s - Exception: %s"
                    (propertize "Uncaught exception" 'face '(:foreground "red"))
                    (replique/get msg :thread)
                    (replique-edn/pr-str (replique/get msg :value))))
          ((equal :eval (replique/get msg :type))
           (let* ((repl (replique/repl-by
                         :session (replique/get (replique/get msg :session) :client)
                         :directory (replique/get msg :process-id)))
                  (buffer (replique/get repl :buffer)))
             (when repl
               (replique/on-repl-type-change repl (replique/get msg :repl-type))
               (replique/update-repl repl (replique/assoc repl :ns (replique/get msg :ns)))
               (replique/display-eval-result msg buffer))))
          (t (replique-async/put! out-chan msg)))
       (error (message (error-message-string err))))
     (replique/dispatch-tooling-msg* in-chan out-chan))))

(defun replique/dispatch-tooling-msg (in-chan)
  (let ((out-chan (replique-async/chan)))
    (replique/dispatch-tooling-msg* in-chan out-chan)
    out-chan))

(defvar replique/parser-state)

(defun replique/read-from-to (chan-out from to)
  (goto-char from)
  (when-let ((o (read (current-buffer))))
    (replique-async/put! chan-out o))
  (while (< (point) to)
    (when-let ((o (read (current-buffer))))
      (replique-async/put! chan-out o))))

(defun replique/read-buffer (chan-out)
  (let ((new-parser-state (parse-partial-sexp
                           (point) (point-max) 0 nil replique/parser-state)))
    (if (not (= 0 (car new-parser-state)))
        (setq replique/parser-state new-parser-state)
      (setq replique/parser-state nil)
      (condition-case err
          (let ((to (point)))
            (replique/read-from-to chan-out 1 to)
            (delete-region 1 to)
            (replique/read-buffer chan-out))
        (end-of-file (delete-region 1 (point-max)))))))

(defun replique/read-chan* (chan-in chan-out proc buffer &optional error-handler)
  (replique-async/<!
   chan-in
   (lambda (string)
     (when string
       (condition-case err
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (let ((p (point)))
                 (insert string)
                 (goto-char p))
               (replique/read-buffer chan-out))
             (replique/read-chan* chan-in chan-out proc buffer error-handler))
         (error
          (if error-handler
              (funcall error-handler string)
            (error (error-message-string err)))))))))

(defun replique/read-chan (chan-in proc buffer &optional error-handler)
  (let ((chan-out (replique-async/chan)))
    (with-current-buffer buffer
      (setq-local replique/parser-state nil))
    (buffer-disable-undo buffer)
    (replique/read-chan* chan-in chan-out proc buffer error-handler)
    chan-out))

(defun replique/kill-process-buffer (buffer)
  (if (not (equal (buffer-size buffer) 0))
      ;; There is still stuff in the buffer, let a chance to the reader to finish reading the
      ;; process output
      (run-at-time 1 nil (lambda () (kill-buffer buffer)))
    (kill-buffer buffer)))

(provide 'replique)

;; compliment keywords cljs -> missing :require ... ?
;; CSS / HTML autocompletion, with core.spec ?
;; Customizing REPL options requires starting a new REPL (leiningen options don't work in the context of replique). Find a way to automate this process (using leiningen or not ...)
;; multi-process -> print directory in messages
;; The cljs-env makes no use of :repl-require

;; compliment invalidate memoized on classpath update
;; Use a lein task to compute the new classpath and send it to the clojure process.

;; autocomplete using the spec first, compliment next if no candidates

;; defclass is deprecated

;; spec autocomplete for files -> emacs first line local variables
;; spec autocomplete for macros -> specized macros

;; printing something that cannot be printed by the elisp printer results something that cannot be read by the reader because the elisp printer will print a partial object before throwing an exception

;; Document the use of cljsjs to use js libs
;; Customization var for excluded folders when refreshing main js files
;; completion for strings that match a path and are in a (File.) / (file) form
;; add a watcher on cljs compiler to implement cljs vars watching

;; load-file (and other macros ?) are executed 2 times when called from the cljs repl
;; direct linking not supported because of alter-var-root! calls
;; Binding to the loopback address prevents connecting from the outside (mobile device ...)
;; cljs repl server hangs on serving assets on a broken connection ?
;; Print cljs exceptions like clj ones
;; autocompletion for locals when in the same binding form

;; restore print-namespaced-maps somewhere

;; min versions -> clojure 1.8.0, clojurescript 1.8.40
