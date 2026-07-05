;;; alt.el --- Flymake support for LanguageTool  -*- lexical-binding: t; -*-

;; Copyright (C) 2021-2026  Shen, Jen-Chieh
;; Created date 2021-04-02 23:22:37

;; Authors: Jakub T. Jankiewicz <jcubic@jcubic.pl>, Shen, Jen-Chieh <jcs090218@gmail.com>, Trey Peacock <git@treypeacock.com>
;; URL: https://github.com/jcubic/alt
;; Version: 0.2.0
;; Package-Requires: ((emacs "27.1") (compat "29.1.4.4"))
;; Keywords: convenience grammar check

;; This file is NOT part of GNU Emacs.

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
;;
;; Flymake support for LanguageTool.
;;

;;; Code:

(require 'compat)
(require 'seq)
(eval-when-compile
  (require 'cl-lib))
(require 'url)
(require 'flymake)

;; `company' is an optional dependency, used only when `alt-correct-style'
;; is `company'.  It is never required at load time; install and enable it
;; yourself (`M-x package-install RET company').
(defvar company-mode)
(declare-function company-mode "company" (&optional arg))
(declare-function company-begin-backend "company" (backend &optional callback))

;; Either use the built-in JSON support or import the `json' library, defining a
;; compatibility function so we can use the best supported JSON parser.
(defalias 'alt--parse-json
  (if (and (fboundp 'json-parse-string)
           (fboundp 'json-available-p)
           (json-available-p))
      (lambda (string)
        "Parse a json STRING."
        (json-parse-string string
                           :array-type 'list
                           :object-type 'alist
                           :false-object :json-false
                           :null-object nil))
    (require 'json)
    'json-read-string))

;; Dynamically bound.
(defvar url-http-end-of-headers)

(defgroup alt nil
  "Flymake support for LanguageTool."
  :prefix "alt-"
  :group 'flymake
  :link '(url-link :tag "Github"
                   "https://github.com/jcubic/alt"))

(defcustom alt-active-modes
  '(text-mode latex-mode org-mode markdown-mode message-mode)
  "List of major mode that work with LanguageTool."
  :type '(repeat symbol)
  :group 'alt)

(defcustom alt-ignore-faces-alist
  '((org-mode . (org-code org-verbatim
                          org-block font-lock-comment-face
                          org-block-begin-line org-block-end-line
                          org-special-keyword org-table org-tag))
    (message-mode . (message-header-cc
                     message-header-to
                     message-header-other
                     message-mml
                     message-cited-text
                     message-cited-text-1
                     message-cited-text-2
                     message-cited-text-3
                     message-cited-text-4))
    (markdown-mode . (markdown-code-face
                      markdown-markup-face
                      markdown-inline-code-face markdown-pre-face
                      markdown-url-face markdown-plain-url-face
                      markdown-math-face markdown-html-tag-name-face
                      markdown-html-tag-delimiter-face
                      markdown-html-attr-name-face
                      markdown-html-attr-value-face
                      markdown-html-entity-face)))
  "Filters out errors if they are of fortified with faces in this alist.
It is an alist of (major-mode . faces-to-ignore)"
  :type '(alist :key-type symbol
                :value-type (repeat symbol))
  :group 'alt)

(defcustom alt-languagetool-url nil
  "The URL for the LanguageTool API we should connect to."
  :type '(choice (const :tag "Auto" nil)
                 (string :tag "URL"))
  :group 'alt)

(defcustom alt-languagetool-api-username nil
  "The username for accessing the Premium LanguageTool API."
  :type 'string
  :group 'alt)

(defcustom alt-languagetool-api-key nil
  "The API Key for accessing the Premium LanguageTool API."
  :type 'string
  :group 'alt)

(defcustom alt-languagetool-server-jar nil
  "The path of languagetool-server.jar.

The server will be automatically started if specified.  Set to
nil if you’re going to connect to a remote LanguageTool server,
or plan to start a local server some other way."
  :type '(choice (const :tag "Off" nil)
                 (file :tag "Filename" :must-match t))
  :link '(url-link :tag "LanguageTool embedded HTTP Server"
                   "https://dev.languagetool.org/http-server.html")
  :group 'alt)

(defcustom alt-languagetool-server-port "8081"
  "Port used to make api url requests on local server."
  :type 'string
  :link '(url-link :tag "LanguageTool embedded HTTP Server"
                   "https://dev.languagetool.org/http-server.html")
  :group 'alt)

(defcustom alt-languagetool-server-command ()
  "Custom command to start LanguageTool server.
If non-nil, this list of strings replaces the standard java cli command."
  :type '(repeat string)
  :group 'alt)

(defcustom alt-languagetool-server-args ()
  "Extra arguments to pass when starting the LanguageTool server."
  :type '(repeat string)
  :link '(url-link :tag "LanguageTool embedded HTTP Server"
                   "https://dev.languagetool.org/http-server.html")
  :group 'alt)

(defcustom alt-language "en-US"
  "The language code of the text to check."
  :type '(string :tag "Language")
  :safe #'stringp
  :group 'alt)
(make-variable-buffer-local 'alt-language)

(defcustom alt-check-spelling nil
  "If non-nil, LanguageTool will check spelling."
  :type 'boolean
  :safe #'booleanp
  :group 'alt)

(defcustom alt-check-params ()
  "Extra parameters to pass with LanguageTool check requests."
  :type '(alist :key-type string :value-type string)
  :link '(url-link :tag "LanguageTool API"
                   "https://languagetool.org/http-api/swagger-ui/#!/default/post_check")
  :group 'alt)

(defcustom alt-spelling-rules
  '("HUNSPELL_RULE"
    "HUNSPELL_RULE_AR"
    "MORFOLOGIK_RULE_AST"
    "MORFOLOGIK_RULE_BE_BY"
    "MORFOLOGIK_RULE_BR_FR"
    "MORFOLOGIK_RULE_CA_ES"
    "MORFOLOGIK_RULE_DE_DE"
    "MORFOLOGIK_RULE_EL_GR"
    "MORFOLOGIK_RULE_EN"
    "MORFOLOGIK_RULE_EN_AU"
    "MORFOLOGIK_RULE_EN_CA"
    "MORFOLOGIK_RULE_EN_GB"
    "MORFOLOGIK_RULE_EN_NZ"
    "MORFOLOGIK_RULE_EN_US"
    "MORFOLOGIK_RULE_EN_ZA"
    "MORFOLOGIK_RULE_ES"
    "MORFOLOGIK_RULE_GA_IE"
    "MORFOLOGIK_RULE_IT_IT"
    "MORFOLOGIK_RULE_LT_LT"
    "MORFOLOGIK_RULE_ML_IN"
    "MORFOLOGIK_RULE_NL_NL"
    "MORFOLOGIK_RULE_PL_PL"
    "MORFOLOGIK_RULE_RO_RO"
    "MORFOLOGIK_RULE_RU_RU"
    "MORFOLOGIK_RULE_RU_RU_YO"
    "MORFOLOGIK_RULE_SK_SK"
    "MORFOLOGIK_RULE_SL_SI"
    "MORFOLOGIK_RULE_SR_EKAVIAN"
    "MORFOLOGIK_RULE_SR_JEKAVIAN"
    "MORFOLOGIK_RULE_TL"
    "MORFOLOGIK_RULE_UK_UA"
    "SYMSPELL_RULE")
  "LanguageTool rules for checking of spelling.
These rules will be enabled if `alt-check-spelling' is non-nil."
  :type '(repeat string)
  :group 'alt)

(defcustom alt-disabled-rules '()
  "LanguageTool rules to be disabled by default."
  :type '(repeat string)
  :group 'alt)

(defcustom alt-disabled-categories '()
  "LanguageTool categories to be disabled by default."
  :type '(repeat string)
  :group 'alt)

(defcustom alt-use-categories t
  "Report errors with LanguageTool Category."
  :type 'boolean
  :safe #'booleanp
  :group 'alt)

(defcustom alt-correct-style 'minibuffer
  "How `alt' presents corrections at point.

`minibuffer' selects a correction with `completing-read'.

`company' shows an in-buffer company popup at the error.  It requires
the `company' package (an optional dependency) to be installed; when
company is unavailable `alt' warns and falls back to `minibuffer'.  With
this style the echo-area diagnostic omits the inline \"(try: ...)\"
suggestions, since corrections are offered through the popup instead."
  :type '(choice (const :tag "Minibuffer (completing-read)" minibuffer)
                 (const :tag "Company popup" company))
  :safe #'symbolp
  :group 'alt)

(defvar-local alt--proc-buf nil
  "Current process we are currently using for grammar check.")

(defvar-local alt--report-fn nil
  "The `report-fn' of the most recent `alt--checker' run.
Flymake hands the checker a fresh REPORT-FN for every run and treats a
report from an older run as obsolete.  We record the latest one here so
asynchronous callbacks can drop stale reports instead of crashing.")

(defvar alt--local nil
  "Can we reach the local LanguageTool server API?")

(defconst alt-category-map
  '(("CASING"            . :casing)
    ("COLLOQUIALISMS"    . :colloquialisms)
    ("COMPOUNDING"       . :compounding)
    ("CONFUSED_WORDS"    . :confused-words)
    ("FALSE_FRIENDS"     . :false-friends)
    ("GENDER_NEUTRALITY" . :gender-neutrality)
    ("GRAMMAR"           . :grammar)
    ("MISC"              . :misc)
    ("PLAIN_ENGLISH"     . :plain-english)
    ("PUNCTUATION"       . :punctuation)
    ("REDUNDANCY"        . :redundancy)
    ("REGIONALISMS"      . :regionalisms)
    ("REPETITIONS"       . :repetitions)
    ("REPETITIONS_STYLE" . :repetitions-style)
    ("SEMANTICS"         . :semantics)
    ("STYLE"             . :style)
    ("TYPOGRAPHY"        . :typography)
    ("TYPOS"             . :typos)
    ("WIKIPEDIA"         . :wikipedia))
  "LanguageTool category mappings.

See https://languagetool.org/development/api/org/languagetool/rules/Categories.html.")

;;
;;; Util

(defun alt--category-setup ()
  "Setup LanguageTool categories as Flymake types."
  (cl-loop for (n . key) in alt-category-map
           for name = (downcase (string-replace "_" "-" n))
           for cat = (intern (format "alt-%s" name))
           do
           (put key 'flymake-category cat)
           (put cat 'face 'flymake-warning)
           (put cat 'flymake-bitmap 'flymake-warning-bitmap)
           (put cat 'severity (warning-numeric-level :warning))
           (put cat 'mode-line-face 'compilation-warning)
           (put cat 'echo-face 'flymake-warning-echo)
           (put cat 'eol-face 'flymake-warning-echo-at-eol)
           (put cat 'flymake-type-name name)))

(when alt-use-categories
  (alt--category-setup))

;; Ignore some faces
(defun alt--ignore-at-pos-p (pos src-buf
                                                  faces-to-ignore)
  "Return non-nil if faces at POS in SRC-BUF intersect FACES-TO-IGNORE."
  (let ((x (get-text-property pos 'face src-buf)))
    (cl-loop
     for face in (ensure-list x)
     when (memq face faces-to-ignore)
     return t)))

(defun alt--ignored-faces ()
  "Return the faces that should be ignored in the current buffer."
  (cl-loop
   for (mode . faces) in alt-ignore-faces-alist
   when (derived-mode-p mode)
   append (ensure-list faces)))

(defun alt--pos-to-point (buf offset pos)
  "Search forward in BUF for the specified text position POS from OFFSET.
This function correctly handles emoji which count as two characters."
  (let (case-fold-search)
    (with-current-buffer buf
      (save-excursion
        (setq pos (+ offset pos))
        (goto-char offset)
        ;; code points in the "supplementary place" use two code units
        (while (and (< (point) pos)
                    (re-search-forward (rx (any (#x010000 .  #x10ffff))) pos t))
          (setq pos (1- pos)))
        pos))))

(defun alt--check-all (errors source-buffer)
  "Check grammar ERRORS for SOURCE-BUFFER document."
  (let ((faces (with-current-buffer source-buffer
                 (alt--ignored-faces)))
        check-list)
    (dolist (error errors)
      (let-alist error
        (let* ((beg (alt--pos-to-point source-buffer (point-min) .offset))
               (end (alt--pos-to-point source-buffer beg .length)))
          ;; LanguageTool (notably the premium API) sometimes returns a
          ;; match span that runs past the flagged text into the trailing
          ;; newline(s).  Trim those so the overlay covers only the error
          ;; and corrections neither jump to nor merge with the next line.
          (with-current-buffer source-buffer
            (while (and (> end beg) (memq (char-before end) '(?\n ?\r)))
              (setq end (1- end))))
          (unless (and faces (alt--ignore-at-pos-p beg source-buffer faces))
            (push (flymake-make-diagnostic
                   source-buffer
                   beg end
                   (if alt-use-categories
                       (map-elt alt-category-map
                                .rule.category.id)
                     :warning)
                   (let ((sugs (seq-map (lambda (rep)
                                         (car (map-values rep)))
                                       .replacements)))
                     (if (and sugs (not (eq alt-correct-style 'company)))
                         (format "%s (try: %s) [LanguageTool]"
                                 .message
                                 (string-join (seq-take sugs 3) ", "))
                       (concat .message " [LanguageTool]")))
                   `((message . ,(concat .message " [LanguageTool]"))
                     (suggestions . (,@(seq-map (lambda (rep)
                                                  (car (map-values rep)))
                                                .replacements)))
                     (rule-id . ,.rule.id)
                     (rule-desc . ,.rule.description)
                     (type . ,.rule.issueType)
                     (category . ,.rule.category.id)))
                  check-list)))))
    check-list))

(defun alt--output-to-errors (output source-buffer)
  "Parse the JSON data from OUTPUT of LanguageTool analysis of SOURCE-BUFFER."
  (let* ((full-results (alt--parse-json output))
         (errors (cdr (assoc 'matches full-results))))
    (alt--check-all errors source-buffer)))

(defun alt--handle-finished (status source-buffer report-fn)
  "Callback function for LanguageTool process for SOURCE-BUFFER.
STATUS provided from `url-retrieve'."
  (let* ((err (plist-get status :error))
         (c-buf (current-buffer))
         ;; REPORT-FN is unique to the Flymake run that spawned this
         ;; request.  If the source buffer has since started a newer run
         ;; the stored `alt--report-fn' no longer matches
         ;; and calling REPORT-FN would signal an "Obsolete report" error.
         (current (eq report-fn
                      (buffer-local-value 'alt--report-fn
                                          source-buffer))))
    (cond
     ((not current)
      (with-current-buffer source-buffer
        (flymake-log :warning "Skipping an obsolete check")))
     (err
      ;; Ignore errors about deleted processes since they are obsolete
      ;; calls deleted by `alt--check'
      (unless (and (stringp (nth 2 err))
                    (equal "deleted" (string-trim (nth 2 err))))
        (with-current-buffer source-buffer
          ;; for some reason the 2nd element in error list is a
          ;; symbol. This needs to be changed to string to reflect in
          ;; `error-message-string'
          (setf (nth 1 err) (symbol-name (nth 1 err)))
          (funcall report-fn :panic :explanation
                   (format "%s: %s" c-buf (error-message-string err))))))
     (url-http-end-of-headers
      (let ((output (save-restriction
                      (set-buffer-multibyte t)
                      (goto-char url-http-end-of-headers)
                      (buffer-substring (point) (point-max)))))
        (with-current-buffer source-buffer
          (funcall report-fn
                   (alt--output-to-errors output source-buffer)
                   :region (cons (point-min) (point-max)))))))
    (kill-buffer c-buf)))

(defun alt--check (report-fn text)
  "Run LanguageTool on TEXT from current buffer's contento.
The callback function will reply with REPORT-FN."
  (when-let* ((buf alt--proc-buf))
    ;; need to check if buffer has ongoing process or else we may
    ;; potentially delete the wrong one.
    (when-let* ((process (get-buffer-process buf)))
      (delete-process process))
    (setf alt--proc-buf nil))
  ;; Correctly %-encode query parameters.
  ;; See https://github.com/emacs-languagetool/flymake-languagetool/pull/34
  ;; and https://debbugs.gnu.org/cgi/bugreport.cgi?bug=78984
  ;;
  ;; Fixed in Emacs 31.
  (when (< emacs-major-version 31)
    (setq text (url-hexify-string text)))
  (let* ((url-request-method "POST")
         (url-request-extra-headers
          '(("Content-Type" . "application/x-www-form-urlencoded")))
         (source-buffer (current-buffer))
         (disabled-cats
          (string-join alt-disabled-categories ","))
         (disabled-rules
          (string-join (append alt-disabled-rules
                               (unless alt-check-spelling
                                 alt-spelling-rules))
                       ","))
         (params (list (list "text" text)
                       (list "language" alt-language)
                       (unless (string-empty-p disabled-rules)
                         (list "disabledRules" disabled-rules))
                       (unless (string-empty-p disabled-cats)
                         (list "disabledCategories" disabled-cats))
                       (when alt-languagetool-api-username
                         (list "username" alt-languagetool-api-username))
                       (when alt-languagetool-api-key
                         (list "apiKey" alt-languagetool-api-key))))
         (url-request-data (url-build-query-string params nil t)))
    (if (alt--reachable-p)
        (setq alt--proc-buf
              (url-retrieve
               (concat (or alt-languagetool-url
                           (format "http://localhost:%s"
                                   alt-languagetool-server-port))
                       "/v2/check")
               #'alt--handle-finished
               (list source-buffer report-fn) t))
      ;; can't reach LanguageTool API, try again. TODO:
      (funcall report-fn :panic :explanation
               (format "Cannot reach LanguageTool URL: %s"
                       alt-languagetool-url)))))

(defun alt--reachable-p ()
  "TODO: Document this."
  (let ((res (or alt--local
                 (condition-case nil
                     (url-retrieve-synchronously
                      (concat (or alt-languagetool-url
                                  (format "http://localhost:%s"
                                          alt-languagetool-server-port))
                              "/v2/languages")
                      t)
                   (file-error nil)))))
    (when (buffer-live-p res)
      (kill-buffer res)
      (setq res t))
    res))

(defun alt--start-server (report-fn)
  "Start the LanguageTool server if we didn’t already.
Once started call `alt' checker with REPORT-FN."
  (let* ((source (current-buffer))
         (cmd (or alt-languagetool-server-command
                  (list "java" "-cp" alt-languagetool-server-jar
                        "org.languagetool.server.HTTPServer"
                        "--port" alt-languagetool-server-port))))
    (make-process
     :name "languagetool-server" :noquery t :connection-type 'pipe
     :buffer " *LanguageTool server*"
     :command (append cmd alt-languagetool-server-args)
     :filter
     (lambda (proc string)
       (funcall #'internal-default-process-filter proc string)
       (when (string-match ".*Server started\n$" string)
         (with-current-buffer source
           (setq alt--local t)
           ;; Only resume the run that requested the server; if the buffer
           ;; has moved on to a newer check, REPORT-FN is already obsolete.
           (when (eq report-fn alt--report-fn)
             (alt--checker report-fn)))
         (set-process-filter proc nil)))
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (setq alt--local nil)
         (delete-process proc)
         (kill-buffer (process-buffer proc)))))))

(defun alt--checker (report-fn &rest _args)
  "Diagnostic checker function with REPORT-FN."
  ;; Remember the report function for this run so asynchronous callbacks
  ;; can tell whether they are still current (see
  ;; `alt--handle-finished').
  (setq alt--report-fn report-fn)
  (let ((text (buffer-substring-no-properties
               (point-min) (point-max))))
    (cond
     ((alt--reachable-p)
      (alt--check report-fn text))
     ((or alt-languagetool-server-command alt-languagetool-server-jar)
      (alt--start-server report-fn))
     (t (funcall report-fn :panic :explanation
                 (format "Cannot reach LanguageTool URL: %s"
                         alt-languagetool-url))))))

(defun alt--overlay-p (overlay)
  "Return t if OVERLAY is a `alt' diagnostic overlay."
  (when-let* ((diag (overlay-get overlay 'flymake-diagnostic))
              (backend (flymake-diagnostic-backend diag)))
    (eq backend 'alt--checker)))

(defun alt--ovs (&optional format)
  "List of all `alt' diagnostic overlays.
Optionally provide pretty FORMAT for each overlay."
  (let* ((lt-ovs (seq-filter #'alt--overlay-p
                             (overlays-in (point-min) (point-max))))
         (ovs (seq-sort-by #'overlay-start #'< lt-ovs)))
    (if format
        (seq-map
         (lambda (ov) (cons (format "%s: %s"
                                    (line-number-at-pos (overlay-start ov))
                                    (flymake-diagnostic-text
                                     (overlay-get ov 'flymake-diagnostic)))
                            ov))
         ovs)
      ovs)))

(defvar-local alt-current-cand nil
  "Current overlay candidate.")

(defun alt--ov-at-point ()
  "Return `alt' overlay at point."
  (setq alt-current-cand
        (car (seq-filter #'alt--overlay-p
                         (overlays-at (point))))))

(defun alt--suggestions ()
  "Show corrections suggested from LanguageTool."
  (overlay-put alt-current-cand 'face 'isearch)
  (let ((sugs (map-elt (flymake-diagnostic-data
                        (overlay-get alt-current-cand
                                     'flymake-diagnostic))
                       'suggestions)))
    (seq-remove #'null `(,@sugs "Ignore Rule" "Ignore Category"))))

(defun alt--clean-overlay ()
  "Remove highlighting of current candidate."
  (ignore-errors
    (overlay-put alt-current-cand 'face 'flymake-warning))
  (setq alt-current-cand nil))

(defun alt--check-buffer ()
  "TODO: Document this."
  (when (bound-and-true-p flymake-mode)
    (flymake-start)))

(defun alt--ignore (ov id type)
  "Ignore LanguageTool ID at OV.
Depending on TYPE, either ignore Rule ID or Category ID."
  (let ((desc (map-elt (flymake-diagnostic-data
                        (overlay-get ov 'flymake-diagnostic))
                       'rule-desc)))
    (when (eq type 'Rule)
      (make-local-variable 'alt-disabled-rules)
      (add-to-list 'alt-disabled-rules id))
    (when (eq type 'Category)
      (make-local-variable 'alt-disabled-categories)
      (add-to-list 'alt-disabled-categories id))
    (alt--check-buffer)
    (message "%s %s: (%s) has been disabled" type id desc)
    (alt--clean-overlay)))

(defun alt--correct (ov choice)
  "Replace text in error at OV with CHOICE."
  (let ((start (overlay-start ov))
        (end (overlay-end ov)))
    (undo-boundary)
    (delete-overlay ov)
    (delete-region start end)
    (goto-char start)
    (insert choice)))

;; Lifted from jinx.el but will ensure users have a somewhat consistent
;; experience
(defun alt--correct-setup ()
  "Ensure that the minibuffer is setup for corrections."
  (let ((message-log-max nil)
        (inhibit-message t))
    (when (and (eq completing-read-function #'completing-read-default)
               (not (bound-and-true-p vertico-mode))
               (not (bound-and-true-p icomplete-mode)))
      (minibuffer-completion-help))))

;;
;;; Corrections

;;;###autoload
(defun alt-next (&optional n)
  "Go to Nth next flymake languagetool error."
  (interactive (list (or current-prefix-arg 1)))
  (let* ((ovs (if (> n 0)
                  (alt--ovs)
                (nreverse (alt--ovs))))
         (tail (seq-drop-while (lambda (ov) (if (> n 0)
                                                (<= (overlay-start ov) (point))
                                              (>= (overlay-start ov) (point))))
                               ovs))
         (chain (if flymake-wrap-around
                    (seq-concatenate 'list tail ovs)
                  tail))
         (target (nth (1- (abs n)) chain)))
    (goto-char (overlay-start target))))

;;;###autoload
(defun alt-previous (&optional n)
  "Go to Nth previous flymake languagetool error."
  (interactive (list (or current-prefix-arg 1)))
  (alt-next (- n)))

(defun alt--effective-correct-style ()
  "Return the correction style to actually use.
Honor `alt-correct-style', but fall back to `minibuffer' with a warning
when `company' is requested yet unavailable."
  (if (eq alt-correct-style 'company)
      (if (require 'company nil t)
          'company
        (lwarn 'alt :warning
               "`alt-correct-style' is `company' but the company package \
is not available; falling back to the minibuffer")
        'minibuffer)
    alt-correct-style))

(defun alt--correct-company (ov)
  "Correct the `alt' diagnostic at overlay OV with a company popup.
Suggestions are shown as bare words; the `Ignore Rule' and `Ignore
Category' actions are appended as extra entries."
  (unless (bound-and-true-p company-mode)
    (company-mode 1))
  (let* ((diag (overlay-get ov 'flymake-diagnostic))
         (data (flymake-diagnostic-data diag))
         (sugs (seq-remove #'null (map-elt data 'suggestions)))
         (id (map-elt data 'rule-id))
         (beg (overlay-start ov))
         (end (overlay-end ov))
         (word (buffer-substring-no-properties beg end))
         (cands (append sugs '("Ignore Rule" "Ignore Category"))))
    ;; company deletes the prefix before point and inserts the choice, so put
    ;; point at the end of the error span and hand it the whole error word.
    (goto-char end)
    (company-begin-backend
     (lambda (command &optional arg &rest _)
       (pcase command
         ('prefix (cons word (length word)))
         ('candidates cands)
         ('sorted t)
         ('no-cache t)
         ('post-completion
          (pcase arg
            ((or "Ignore Rule" "Ignore Category")
             ;; company inserted the action text; restore the original word
             ;; and run the real ignore handler instead.
             (delete-region beg (point))
             (goto-char beg)
             (insert word)
             (alt--ignore ov id (if (equal arg "Ignore Rule")
                                    'Rule 'Category))))))))))

(defun alt--correct-minibuffer (ov)
  "Correct the `alt' diagnostic at overlay OV with `completing-read'."
  (condition-case nil
      (when-let*
          ((type (map-elt (flymake-diagnostic-data
                           (overlay-get ov 'flymake-diagnostic))
                          'type))
           (sugs (alt--suggestions))
           (prompt (or (map-elt (flymake-diagnostic-data
                                 (overlay-get ov 'flymake-diagnostic))
                                'message)
                      (flymake-diagnostic-text
                       (overlay-get ov 'flymake-diagnostic))))
           (id (map-elt (flymake-diagnostic-data
                         (overlay-get ov 'flymake-diagnostic))
                        'rule-id))
           (choice (minibuffer-with-setup-hook
                       #'alt--correct-setup
                     (completing-read
                      (format "Correction (%s): " prompt) sugs nil t nil nil
                      (car sugs)))))
        (pcase choice
          ("Ignore Rule" (alt--ignore ov id 'Rule))
          ("Ignore Category"
           (alt--ignore ov id 'Category))
          (_ (alt--correct ov choice))))
    (t (alt--clean-overlay))))

;;;###autoload
(defun alt-correct-at-point (&optional ol)
  "Correct `alt' diagnostic at point.
Use OL as diagnostic if non-nil.  The correction interface is selected by
`alt-correct-style'."
  (interactive)
  (if-let* ((alt-current-cand
             (or ol (alt--ov-at-point))))
      (if (eq (alt--effective-correct-style) 'company)
          (alt--correct-company alt-current-cand)
        (alt--correct-minibuffer alt-current-cand))
    (user-error "No correction at point")))

;;;###autoload
(defun alt-correct ()
  "Use `completing-read' to select and correct diagnostic."
  (interactive)
  (let* ((cands (alt--ovs 'format))
         (cand (if cands
                   (minibuffer-with-setup-hook
                       #'alt--correct-setup
                     (completing-read "Error: " cands nil t))
                 (user-error "No candidates")))
         (ov (map-elt cands cand)))
    (save-excursion
      (goto-char (overlay-start ov))
      (condition-case nil
          (funcall #'alt-correct-at-point ov)
        (quit (alt--clean-overlay))
        (t (alt--clean-overlay))))))

;;;###autoload
(defun alt-correct-dwim ()
  "DWIM function for correcting `alt' diagnostics."
  (interactive)
  (if-let* ((ov (alt--ov-at-point)))
      (funcall #'alt-correct-at-point ov)
    (funcall-interactively #'alt-correct)))

;;;###autoload
(defun alt-correct-auto ()
  "Replace the `alt' error at point with its first suggestion, no prompt.
Unlike `alt-correct-at-point' this never opens a popup or the minibuffer,
so it pairs well with `alt-next' for quick passes.  Signal a `user-error'
when there is no error at point, or when the error has no suggestion.

Because it applies LanguageTool's top suggestion blindly, review the
result \(the change is a single `undo' away)."
  (interactive)
  (if-let* ((ov (alt--ov-at-point)))
      (if-let* ((sugs (seq-remove
                       #'null
                       (map-elt (flymake-diagnostic-data
                                 (overlay-get ov 'flymake-diagnostic))
                                'suggestions))))
          (alt--correct ov (car sugs))
        (alt--clean-overlay)
        (user-error "No suggestion for error at point"))
    (user-error "No correction at point")))

;;
;;; Entry

(defvar-local alt--flymake-managed nil
  "Non-nil when `alt-mode' turned on `flymake-mode' in this buffer.
Used to decide whether disabling `alt-mode' should also turn
`flymake-mode' back off.")

(defun alt--other-backends-p ()
  "Return non-nil if a Flymake backend other than alt is active here.
Considers the buffer-local diagnostic functions and, when the local
hook opts into them (via the t element), the global ones too."
  (let* ((local flymake-diagnostic-functions)
         (fns (append (remq t local)
                      (when (memq t local)
                        (default-value 'flymake-diagnostic-functions)))))
    (seq-some (lambda (fn) (not (eq fn #'alt--checker))) fns)))

;;;###autoload
(define-minor-mode alt-mode
  "Toggle LanguageTool grammar checking with Flymake in this buffer.
Enabling registers the LanguageTool checker and turns on `flymake-mode'
if it is not already active.  Disabling unregisters the checker and, when
`alt-mode' was what enabled `flymake-mode' and no other Flymake backend
remains, also turns `flymake-mode' back off.  A `flymake-mode' that was
already on, or one shared with other backends, is left untouched."
  :lighter " ALT"
  (cond
   (alt-mode
    (add-hook 'flymake-diagnostic-functions #'alt--checker nil t)
    (unless (bound-and-true-p flymake-mode)
      (setq alt--flymake-managed t)
      (flymake-mode 1)))
   (t
    (remove-hook 'flymake-diagnostic-functions #'alt--checker t)
    (when (and alt--flymake-managed
               (bound-and-true-p flymake-mode)
               (not (alt--other-backends-p)))
      (flymake-mode -1))
    (setq alt--flymake-managed nil))))

;;;###autoload
(defun alt-load ()
  "Convenience function to setup alt.
This adds the language-tool checker to the list of flymake diagnostic
functions.  Use this when you manage `flymake-mode' yourself or combine
alt with other Flymake backends; otherwise `alt-mode' is simpler."
  (add-hook 'flymake-diagnostic-functions #'alt--checker nil t))

;;;###autoload
(defun alt-maybe-load ()
  "Load backend if major-mode in `alt-active-modes'."
  (interactive)
  (when (memq major-mode alt-active-modes)
    (alt-load)))

(provide 'alt)
;;; alt.el ends here
