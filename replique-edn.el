;; replique-edn.el ---   -*- lexical-binding: t; -*-

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

;; Commentary:

;; Code:

(require 'eieio)
(require 'subr-x)

(defmacro comment (&rest body)
  "Comment out one or more s-expressions."
  nil)

(defun replique-edn/write-string* (str)
  (let ((idx 0)
        (chars nil))
    (while (< idx (length str))
      (let ((ch (elt str idx)))
        (cond ((or (equal ?\\ ch)
                   (equal ?\" ch))
               (push ?\\ chars)
               (push ch chars))
              (t (push ch chars))))
      (setq idx (1+ idx)))
    (format "\"%s\""
            (apply 'string (reverse chars)))))

(defclass replique-edn/printable ()
  ()
  :abstract t)

(defmethod replique-edn/print-method ((o replique-edn/printable))
  (let ((slots (mapcar (lambda (s)
                         (intern (concat ":" (symbol-name s))))
                       (object-slots o)))
        (l nil)
        (m (make-hash-table :test 'equal)))
    (dolist (s slots)
      (push (slot-value o s) l)
      (push s l))
    (let ((data-rest l))
      (while data-rest
        (puthash (car data-rest) (cadr data-rest) m)
        (setq data-rest (cddr data-rest))))
    (format "#%s %s"
            (object-class o)
            (replique-edn/pr-str m))))

(defclass replique-edn/with-face (replique-edn/printable)
  ((object :initarg :object)
   (face :initarg :face
         :type symbol)))

(defmethod replique-edn/print-method ((o replique-edn/with-face))
  (propertize (replique-edn/pr-str (oref o object))
              'face (oref o face)))

(defvar replique-edn/print-readably t)

(defun replique-edn/pr-str (data)
  (cond ((null data) "nil")
        ((equal t data) "true")
        ((replique-edn/printable-child-p data)
         (replique-edn/print-method data))
        ((numberp data) (format "%s" data))
        ((stringp data) (if replique-edn/print-readably
                            (replique-edn/write-string* data)
                          data))
        ((symbolp data) (format "%s" data))
        ((vectorp data)
         (format
          "[%s]"
          (string-join (mapcar 'replique-edn/pr-str data) " ")))
        ((hash-table-p data)
         (let ((l nil))
           (maphash
            (lambda (x y)
              (push x l)
              (push y l))
            data)
           (format
            "{%s}"
            (string-join (mapcar 'replique-edn/pr-str (reverse l)) " "))))
        ((listp data)
         (format
          "(%s)"
          (string-join (mapcar 'replique-edn/pr-str data) " ")))
        (t (error "%s cannot be printed to EDN." data))))

(defun replique-edn/print-str (data)
  (let ((replique-edn/print-readably nil))
    (replique-edn/pr-str data)))

(provide 'replique-edn)

;;; replique-edn.el ends here
