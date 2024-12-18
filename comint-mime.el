;;; comint-mime.el --- Display content of various MIME types in comint buffers  -*- lexical-binding: t; -*-

;; Copyright (C) 2021, 2023  Free Software Foundation, Inc.

;; Author: Augusto Stoffel <arstoffel@gmail.com>
;; Homepage: https://github.com/astoff/comint-mime
;; Keywords: processes, multimedia
;; Package-Requires: ((emacs "28.1") (compat "29.1") (mathjax "0.1"))
;; Version: 0.7

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides a mechanism to display graphics and other
;; kinds of "MIME attachments" in comint buffers.  The applications
;; depend on the type of comint.
;;
;; In the regular shell, a command `mimecat' becomes available.  It
;; displays the contents of any file (or standard input) of a
;; supported format.
;;
;; In the Python shell, it is possible to display inline plots, images
;; and, more generally, alternative representations of any object that
;; implements IPython's rich display interface.
;;
;; To enable comint-mime, simply call `M-x comint-mime-setup' in the
;; desired comint buffer.  To enable it permanently, add that same
;; function to an appropriate hook, e.g.
;;
;;     (add-hook 'shell-mode-hook 'comint-mime-setup)
;;     (add-hook 'inferior-python-mode-hook 'comint-mime-setup)

;;; News:

;; Version 0.7:
;; - Use vtable to display HTML tables.
;; - Use mathjax to display LaTeX fragments.

;;; Code:

(require 'comint)
(require 'json)
(require 'mathjax)
(require 'shr)
(require 'svg)
(require 'text-property-search)
(require 'url-parse)
(require 'vtable nil t)                 ;New in Emacs 29
(eval-when-compile (require 'subr-x))

(defvar comint-mime-enabled-types 'all
  "MIME types which the inferior process may send to Emacs.
This is either a list of strings or the symbol `all'.

Note that this merely expresses a preference and its
interpretation is up to the backend.  The shell, for instance,
only sends MIME content to Emacs via the mimecat command, so it
ignores this option altogether.")

(defvar comint-mime-use-vtable (featurep 'vtable)
  "Whether to use `vtable' when displaying HTML tables.")

(defvar comint-mime-use-mathjax (mathjax-available-p)
  "Whether to use MathJax to display mathematical formulas.

Note that you need the Node JavaScript runtime installed on your machine
for this to work.")

(defvar comint-mime-latex-render-method nil
  "Method used to render LaTeX fragments as an image.

The following options are available:

- nil (default): Just display the LaTeX source.

- mathjax (recommended): Use the MathJax library.  For installation
  instructions, see https://www.npmjs.com/package/mathjax-node.

- org: Use Org mode's LaTeX rendering functions, which in turn depend on
  a functioning TeX in installation.  If using this, make sure you
  either trust the input TeX code or have TeX configured to handle
  unsafe input, e.g. by disabling the shell escape feature.")
(make-obsolete-variable 'comint-mime-latex-render-method
                        'comint-mime-use-mathjax
                        "0.7")

(defvar comint-mime-renderer-alist
  '(("\\`image/svg+xml\\>" . comint-mime-render-svg)
    ("\\`image\\>" . comint-mime-render-image)
    ("\\`text/html\\>" . comint-mime-render-html)
    ("\\`text/latex\\>" . comint-mime-render-latex)
    ("\\`text\\>" . comint-mime-render-plain-text)
    ("." . comint-mime-render-literally))
  "Alist associating MIME types to rendering functions.

The keys are interpreted as regexps; the first matching entry is
chosen.

The values should be functions, to called with a header alist
and (undecoded) data as arguments and with point at the location
where the content is to be inserted.")

(defvar comint-mime-image-props nil
  "Property list of image parameters for display.
See Info node `(elisp)Image Descriptors'.")

(defvar comint-mime-prefer-svg nil
  "Whether to prefer SVG images over raster images.
This increases the figure quality at the cost of larger file sizes.
Currently, this only has an effect in IPython, where it changes the
generated Matplotlib figures.

Using a theme with dark background can render some SVGs unreadable.
If you experience this, try setting `comint-mime-image-props' to
(:foreground \"black\" :background \"white\").  Alternatively, configure
the SVG creator to produce images that play well with your theme.")

(defvar comint-mime-setup-function-alist nil
  "Alist of setup functions for comint-mime.
The keys should be major modes derived from `comint-mode'.  The
values should be functions, called by `comint-mime-setup' to
perform the mode-specific part of the setup.")

(defvar comint-mime-setup-script-dir (if-let ((file (macroexp-file-name)))
                                         (file-name-directory file)
                                       default-directory)
  "Directory to look for setup scripts.")

(defun comint-mime-osc-handler (_ text)
  "Interpret TEXT as an OSC 5151 control sequence.
This function is intended to be used as an entry of
`comint-osc-handlers'."
  (string-match "[^\n]*\n?" text)
  (let* ((payload (substring text (match-end 0)))
         (header (json-read-from-string (match-string 0 text)))
         (data (if (string-match "\\(tmp\\)?file:" payload)
                   (let* ((tmp (match-beginning 1))
                          (url (url-generic-parse-url payload))
                          (remote (file-remote-p default-directory))
                          (file (cond (remote (concat remote (url-filename url)))
                                      ((eq system-type 'windows-nt)
                                       (string-remove-prefix "/" (url-filename url)))
                                      (t (url-filename url)))))
                     (with-temp-buffer
                       (set-buffer-multibyte nil)
                       (insert-file-contents-literally file)
                       (when tmp (delete-file file))
                       (buffer-substring-no-properties (point-min) (point-max))))
                 (base64-decode-string payload))))
    (when-let ((fun (cdr (assoc (alist-get 'type header)
                                comint-mime-renderer-alist
                                'string-match))))
      (funcall fun header data))))

;;;###autoload
(defun comint-mime-setup ()
  "Enable rendering of MIME types in this comint buffer.

This function can be called in the hook of major modes deriving
from `comint-mode', or interactively after starting the comint."
  (interactive)
  (unless (derived-mode-p 'comint-mode)
    (user-error "`comint-mime' only makes sense in comint buffers"))
  (if-let ((fun (cdr (assoc major-mode comint-mime-setup-function-alist
                            'provided-mode-derived-p))))
      (progn
        (add-to-list 'comint-osc-handlers '("5151" . comint-mime-osc-handler))
        (add-hook 'comint-output-filter-functions 'comint-osc-process-output nil t)
        (funcall fun))
    (user-error "`comint-mime' is not available for this kind of inferior process")))

;;; Renderes

;;;; Images
(defun comint-mime-render-svg (header data)
  "Render SVG from HEADER and DATA provided by `comint-mime-osc-handler'."
  (let ((start (point)))
    (insert-image (apply #'svg-image data comint-mime-image-props))
    (put-text-property start (point) 'comint-mime header)))

(defun comint-mime-render-image (header data)
  "Render image from HEADER and DATA provided by `comint-mime-osc-handler'."
  (let ((start (point)))
    (insert-image (apply #'create-image data nil t comint-mime-image-props))
    (put-text-property start (point) 'comint-mime header)))

;;;; HTML
(defun comint-mime--vtable-from-dom (dom)
  "Insert a vtable created from a DOM element."
  (let* ((trp (lambda (dom) (eq (dom-tag dom) 'tr)))
         (tdp (lambda (dom) (memq (dom-tag dom) '(th td))))
         (data (mapcar
                (lambda (dom)
                  (mapcar #'dom-texts (dom-search dom tdp)))
                (dom-search dom trp))))
    (make-vtable
     :use-header-line nil
     :columns (mapcar
               (lambda (name)
                 (list :name name
                       :min-width (length name)
                       :align 'right))
               (car data))
     :objects (or (cdr data) '(())))))

(defun comint-mime--vtable-revert (&rest args)
  "Preserve text properties when reverting a vtable created by `comint-mime'."
  (let ((prop (get-text-property (point) 'comint-mime)))
    (prog1 (apply args)
      (when prop
        (save-excursion
          (with-restriction
              (vtable-beginning-of-table)
              (save-excursion (vtable-end-of-table))
            (put-text-property (point-min) (point-max) 'comint-mime prop)
            (while-let ((match (text-property-search-forward 'face)))
              (put-text-property (prop-match-beginning match) (prop-match-end match)
                                 'font-lock-face (prop-match-value match)))))))))
(advice-add #'vtable-revert :around #'comint-mime--vtable-revert)

(defun comint-mime-render-html (header data)
  "Render HTML from HEADER and DATA provided by `comint-mime-osc-handler'."
  (insert
   ;; FIXME: This `save-excursion' is needed since the patch fixing
   ;; bug#51009.  Is this reliable or are there better solutions?
   (save-excursion
     (with-temp-buffer
       (insert data)
       (decode-coding-region (point-min) (point-max) 'utf-8)
       (let ((shr-external-rendering-functions
              (append (when comint-mime-use-vtable
                        '((table . comint-mime--vtable-from-dom)))
                      (when comint-mime-use-mathjax
                        '((math . mathjax-shr-tag-math)))
                      shr-external-rendering-functions)))
           (shr-render-region (point-min) (point-max)))
       ;; Don't let font-lock override those faces
       (goto-char (point-min))
       (while-let ((match (text-property-search-forward 'face)))
         (put-text-property (prop-match-beginning match) (prop-match-end match)
                            'font-lock-face (prop-match-value match)))
       (put-text-property (point-min) (point-max) 'comint-mime header)
       (buffer-string)))))

;;;; LaTeX
(autoload 'org-format-latex "org")
(defvar org-preview-latex-default-process)

(defun comint-mime-render-latex (header data)
  "Render LaTeX from HEADER and DATA provided by `comint-mime-osc-handler'."
  (if (not (or comint-mime-use-mathjax
               (eq 'mathjax comint-mime-latex-render-method)))
      (comint-mime-render-plain-text header data)
    (let ((start (point)))
      (insert data)
      (mathjax-typeset-region start (point))
      (put-text-property start (point) 'comint-mime header))))

;;;; Plain text
(defun comint-mime-render-plain-text (header data)
  "Render plain text from HEADER and DATA provided by `comint-mime-osc-handler'."
  (let ((start (point)))
    (insert data)
    (decode-coding-region start (point) 'utf-8)
    (put-text-property start (point) 'comint-mime header)))

;;;; Dump without rendering or decoding (for debugging)
(defun comint-mime-render-literally (header data)
  "Print HEADER and DATA without special rendering."
  (print header (current-buffer))
  (insert data))

;;; Mode-specific setup

;;;; Python

(defvar python-shell--first-prompt-received)
(declare-function python-shell-send-string-no-output "python.el")

(defun comint-mime-setup-python ()
  "Setup code specific to `inferior-python-mode'."
  (if (not python-shell--first-prompt-received)
      (add-hook 'python-shell-first-prompt-hook #'comint-mime-setup-python nil t)
    (python-shell-send-string-no-output
     (format "%s\n__COMINT_MIME_setup('''%s''', prefer_svg=%s)"
             (with-temp-buffer
               (insert-file-contents
                (expand-file-name "comint-mime.py"
                                  comint-mime-setup-script-dir))
               (buffer-string))
             (if (listp comint-mime-enabled-types)
                 (string-join comint-mime-enabled-types ";")
               comint-mime-enabled-types)
             (if comint-mime-prefer-svg "True" "False")))))

(push '(inferior-python-mode . comint-mime-setup-python)
      comint-mime-setup-function-alist)

;;;; Shell

(defun comint-mime-setup-shell (&rest _)
  "Setup code specific to `shell-mode'."
  (if (save-excursion
        (goto-char (field-beginning (point-max) t))
        (not (re-search-forward comint-prompt-regexp nil t)))
      (add-hook 'comint-output-filter-functions 'comint-mime-setup-shell nil t)
    (remove-hook 'comint-output-filter-functions 'comint-mime-setup-shell t)
    (comint-redirect-send-command
     (format " '.' %s\n"
             (shell-quote-argument
              (expand-file-name "comint-mime.sh"
                                comint-mime-setup-script-dir)))
     nil nil t)))

(push '(shell-mode . comint-mime-setup-shell)
      comint-mime-setup-function-alist)

(provide 'comint-mime)
;;; comint-mime.el ends here
