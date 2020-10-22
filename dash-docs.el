;;; dash-docs.el --- Offline documentation browser using Dash docsets.  -*- lexical-binding: t; -*-
;; Copyright (C) 2013-2014  Raimon Grau
;; Copyright (C) 2013-2014  Toni Reina
;; Copyright (C) 2020       esac

;; Author: Raimon Grau <raimonster@gmail.com>
;;         Toni Reina  <areina0@gmail.com>
;;         Bryan Gilbert <bryan@bryan.sh>
;;         esac <esac-io@tutanota.com>
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;;
;;; Commentary:
;;
;; A library that exposes functionality to work with and search dash
;; docsets, will be transform also in a minor-mode (work in progress).
;;
;;; Code:

(require 'url)
(require 'xml)
(require 'json)
(require 'cl-lib)
(require 'thingatpt)
(require 'format-spec)

(eval-when-compile
  (require 'cl-macs))

(defgroup dash-docs nil
  "Search Dash docsets."
  :prefix "dash-docs-"
  :group 'applications)

(defcustom dash-docs-docsets-path
  (expand-file-name "docsets" user-emacs-directory)
  "Default path for docsets.
If you're setting this option manually, set it to an absolute
path. You can use `expand-file-name' function for that."
  :set (lambda (opt val)
         (set opt (expand-file-name val)))
  :type 'string
  :group 'dash-docs)

(defcustom dash-docs-docsets-feed-url
  "https://raw.github.com/Kapeli/feeds/master"
  "Feeds URL for dash docsets."
  :type 'string
  :group 'dash-docs)

(defcustom dash-docs-docsets-url
  "https://api.github.com/repos/Kapeli/feeds/contents"
  "Official docsets URL."
  :type 'string
  :group 'dash-docs)

(defcustom dash-docs-unofficial-url
  "https://dashes-to-dashes.herokuapp.com/docsets/contrib"
  "Unofficial (user) docsets URL."
  :type 'string
  :group 'dash-docs)

(defcustom dash-docs-min-length 3
  "Minimum length to start searching in docsets.
0 facilitates discoverability, but may be a bit heavy when lots
of docsets are active.  Between 0 and 3 is sane."
  :type 'integer
  :group 'dash-docs)

(defcustom dash-docs-retrieve-url-timeout 5
  "It should be a number that says (in seconds)
how long to wait for a response before giving up."
  :type 'integer
  :group 'dash-docs)

(defcustom dash-docs-candidate-format "%d %n (%t)"
  "Format of the displayed candidates.
Available formats are
   %d - docset name
   %n - name of the token
   %t - type of the token
   %f - file name"
  :type 'string
  :group 'dash-docs)

(defcustom dash-docs-sql-debug-flag nil
  "Non-nil display sql query stderr in a buffer.
Setting this to nil may speed up sql query operations."
  :type 'boolean
  :group 'dash-docs)

(defcustom dash-docs-browser-func 'browse-url
  "Default function to browse Dash's docsets.
Suggested values are:
 * `browse-url'
 * `eww'"
  :type 'function
  :group 'dash-docs)

(defcustom dash-docs-ignored-docsets '("Man_Pages")
  "Return a list of ignored docsets.
These docsets are not available to install."
  :type 'list
  :group 'dash-docs)

(defvar dash-docs-common-docsets '()
  "List of Docsets to search active by default.")

(defvar dash-docs--sql-queries
  '((DASH . (lambda (pattern)
              (let ((like (dash-docs-sql-compose-like "t.name" pattern))
                    (query "SELECT t.type, t.name, t.path FROM searchIndex t WHERE %s ORDER BY LENGTH(t.name), LOWER(t.name) LIMIT 1000"))
                (format query like))))
    (ZDASH . (lambda (pattern)
               (let ((like (dash-docs-sql-compose-like "t.ZTOKENNAME" pattern))
                     (query "SELECT ty.ZTYPENAME, t.ZTOKENNAME, f.ZPATH, m.ZANCHOR FROM ZTOKEN t, ZTOKENTYPE ty, ZFILEPATH f, ZTOKENMETAINFORMATION m WHERE ty.Z_PK = t.ZTOKENTYPE AND f.Z_PK = m.ZFILE AND m.ZTOKEN = t.Z_PK AND %s ORDER BY LENGTH(t.ZTOKENNAME), LOWER(t.ZTOKENNAME) LIMIT 1000"))
                 (format query like))))))

(defvar dash-docs--connections nil
  "List of conses like (\"Go\" . connection).")

(defvar dash-docs-message-prefix "[dash-docs]: "
  "Internal dash-docs message prefix.")

(defmacro dash-docs--message (fmt &rest args)
  "Just an internal `message' helper."
  `(message (concat dash-docs-message-prefix ,fmt) ,@args))

(defun dash-docs--created-docsets-path (docset-path)
  "Check if DOCSET-PATH directory exists."
  (or (file-directory-p docset-path)
      (and (y-or-n-p
            (format "Directory %s does not exist. Want to create it? "
                    docset-path))
           (mkdir docset-path t))))

(defun dash-docs-docsets-path ()
  "Return the path where Dash's docsets are stored."
  (expand-file-name dash-docs-docsets-path))

(defun dash-docs-docset-path (docset)
  "Return DOCSET directory path (full)."
  (let* ((base (dash-docs-docsets-path))
         (docdir (expand-file-name docset base)))
    (cl-loop for dir in (list (format "%s/%s.docset" base docset)
                              (format "%s/%s.docset" docdir docset)
                              (when (file-directory-p docdir)
                                (cl-first (directory-files
                                           docdir t "\\.docset\\'"))))
             when (and dir (file-directory-p dir))
             return dir)))

(defun dash-docs-docset-db-path (docset)
  "Return database DOCSET path."
  (let ((path (dash-docs-docset-path docset)))
    ;; if not found, error
    (unless path
      (error "Cannot find docset '%s'" docset))
    ;; else return expanded path
    (expand-file-name "Contents/Resources/docSet.dsidx" path)))

(defun dash-docs-exec-query (db-path query)
  "Execute QUERY in the db located at DB-PATH and parse the results.
If there are errors, print them in `dash-docs--debug-buffer'."
  (dash-docs-parse-sql-results
   (with-output-to-string
     (let ((error-file (when dash-docs-sql-debug-flag
                         (make-temp-file "dash-docs-errors-file"))))
       (call-process "sqlite3" nil (list standard-output error-file) nil
                     ;; args for sqlite3:
                     "-list" "-init" "''" db-path query)
       ;; display errors, stolen from emacs' `shell-command` function
       (when (and error-file (file-exists-p error-file))
         (if (< 0 (nth 7 (file-attributes error-file)))
             (with-current-buffer (dash-docs--debug-buffer)
               (let ((pos-from-end (- (point-max) (point))))
                 (or (bobp)
                     (insert "\f\n"))
                 ;; Do no formatting while reading error file,
                 ;; because that can run a shell command, and we
                 ;; don't want that to cause an infinite recursion.
                 (format-insert-file error-file nil)
                 ;; Put point after the inserted errors.
                 (goto-char (- (point-max) pos-from-end)))
               (display-buffer (current-buffer))))
         (delete-file error-file))))))

(defun dash-docs-docset-type (db-path)
  "Return the type of the docset based in db schema.
Possible values are \"DASH\" and \"ZDASH\".
The Argument DB-PATH should be a string with the sqlite db path."
  (let ((query "SELECT name FROM sqlite_master WHERE type = 'table' LIMIT 1"))
    (if (member "searchIndex"
                (car (dash-docs-exec-query db-path query)))
        "DASH"
      "ZDASH")))

(defun dash-docs-sql-compose-like (column pattern)
  "Return a query fragment for a sql where clause.
Search in column COLUMN by multiple terms splitting the PATTERN
by whitespace and using like sql operator."
  (let ((conditions (mapcar (lambda (word) (format "%s like '%%%s%%'" column word))
                            (split-string pattern " "))))
    (format "%s" (mapconcat 'identity conditions " AND "))))

(defun dash-docs-compose-sql-query (docset-type pattern)
  "Return a SQL query to search documentation in dash docsets.
A different query is returned depending on DOCSET-TYPE.
PATTERN is used to compose the SQL WHERE clause."
  (let ((compose-select-query-func
         (cdr (assoc (intern docset-type) dash-docs--sql-queries))))
    (when compose-select-query-func
      (funcall compose-select-query-func pattern))))

(defun dash-docs-parse-sql-results (sql-result-string)
  "Parse SQL-RESULT-STRING splitting it by newline and '|' chars."
  (mapcar (lambda (x) (split-string x "|" t))
          (split-string sql-result-string "\n" t)))

(defun dash-docs-buffer-local-docsets ()
  "Get the docsets configured for the current buffer."
  (or (and (boundp 'dash-docs-docsets) dash-docs-docsets)
      '()))

(defun dash-docs-available-connections ()
  "Return available connections."
  (let ((docsets (dash-docs-buffer-local-docsets)))
    ;; append local docsets with common ones
    (setq docsets (append docsets dash-docs-common-docsets))
    ;; get connections associated with the docsets
    (delq nil
          (mapcar (lambda (x)
                    (assoc x dash-docs--connections))
                  docsets))))

(defun dash-docs-create-common-connections ()
  "Create connections to sqlite docsets for common docsets."
  (when (not dash-docs--connections)
    (setq dash-docs--connections
          (mapcar (lambda (x)
                    (let ((db-path (dash-docs-docset-db-path x)))
                      (list x db-path (dash-docs-docset-type db-path))))
                  dash-docs-common-docsets))))

(defun dash-docs-create-buffer-connections ()
  "Create connections to sqlite docsets for buffer-local docsets."
  (mapc (lambda (x) (when (not (assoc x dash-docs--connections))
                      (let ((connection (dash-docs-docset-db-path x)))
                        (setq dash-docs--connections
                              (cons (list x connection
                                          (dash-docs-docset-type connection))
                                    dash-docs--connections)))))
        (dash-docs-buffer-local-docsets)))

(defun dash-docs-maybe-narrow-docsets (pattern)
  "Return a list of dash-docs-connections.
If PATTERN starts with the name of a docset followed by a space, narrow the
used connections to just that one.  We're looping on all connections, but it
shouldn't be a problem as there won't be many."
  (let ((conns (dash-docs-available-connections)))
    (or (cl-loop for x in conns
                 if (string-prefix-p
                     (concat (downcase (car x)) " ")
                     (downcase pattern))
                 return (list x))
        conns)))

(defun dash-docs-write-json-file (json-contents)
  "Write JSON-CONTENTS in the `dash-docs-kapeli-cache-file'."
  ;; set file path
  (let ((file-path (expand-file-name "cache/kapeli.json"
                                     user-emacs-directory)))
    ;; write buffer to file
    (with-temp-file file-path
      ;; insert json contents in the current buffer
      (prin1 json-contents (current-buffer)))))

(defun dash-docs-read-json-from-url (url)
  "Read and return a JSON object from URL."
  (let ((buffer (url-retrieve-synchronously
                 url t t
                 dash-docs-retrieve-url-timeout))
        (json-content nil))
    (cond
     ;; verify if buffer was properly created
     ((not buffer)
      (error "Was not possible to retrieve url."))
     ;; verify buffer size content
     ;; default: read json
     (t
      ;; set json content
      (setq json-content
            (with-current-buffer buffer
              (json-read)))))
    ;; return json content
    json-content))

(defun dash-docs-unofficial-docsets ()
  "Return a list of lists with docsets contributed by users.
The first element is the docset's name second the docset's archive url."
  (let ((docsets (dash-docs-read-json-from-url dash-docs-unofficial-url)))
    (mapcar
     (lambda (docset)
       (list (assoc-default 'name docset)
             (assoc-default 'archive docset)))
     docsets)))

(defun dash-docs-official-docsets ()
  "Return a list of official docsets (http://kapeli.com/docset_links)."
  (let ((docsets (dash-docs-read-json-from-url dash-docs-docsets-url)))
    (delq nil (mapcar
               (lambda (docset)
                 (let ((name (assoc-default 'name docset)))
                   (if (and (equal (file-name-extension name) "xml")
                            (not (member (file-name-sans-extension name)
                                         dash-docs-ignored-docsets)))
                       (file-name-sans-extension name))))
               docsets))))

(defun dash-docs--install-docset (url docset-name)
  "Download a docset from URL and install with name DOCSET-NAME."
  ;; set docset temporary path
  (let ((docset-tmp-path
         (format "%s%s-docset.tgz"
                 temporary-file-directory
                 docset-name)))
    ;; copy file to the right location
    (url-copy-file url docset-tmp-path t)
    ;; install docset from file
    (dash-docs-install-docset-from-file docset-tmp-path)))

(defun dash-docs-installed-docsets ()
  "Return a list of installed docsets."
  (let ((docset-path (dash-docs-docsets-path)))
    (cl-loop for dir in (directory-files docset-path nil "^[^.]")
             for full-path = (expand-file-name dir docset-path)
             for subdir = (and (file-directory-p full-path)
                               (cl-first (directory-files full-path
                                                          t "\\.docset\\'")))
             when (or (string-match-p "\\.docset\\'" dir)
                      (file-directory-p (expand-file-name
                                         (format "%s.docset" dir) full-path))
                      (and subdir (file-directory-p subdir)))
             collecting (replace-regexp-in-string "\\.docset\\'" "" dir))))

(defun dash-docs-extract-and-get-folder (docset-temp-path)
  "Extract DOCSET-TEMP-PATH to DASH-DOCS-DOCSETS-PATH,
and return the folder that was newly extracted."
  (with-temp-buffer
    (let* ((call-process-args (list "tar" nil t nil))
           (process-args (list
                          "xfv" docset-temp-path
                          "-C" (dash-docs-docsets-path)))
           (result (apply #'call-process
                          (append call-process-args process-args nil))))
      (goto-char (point-max))
      (cond
       ((and (not (equal result 0))
             ;; TODO: Adjust to proper text. Also requires correct locale.
             (search-backward "too long" nil t))
        (error "Failed extract %s to %s."
               docset-temp-path (dash-docs-docsets-path)))
       ((not (equal result 0))
        (error "Failed to extract %s to %s. Error: %s"
               docset-temp-path (dash-docs-docsets-path) result)))
      (goto-char (point-max))
      (replace-regexp-in-string "^x " "" (car (split-string (thing-at-point 'line) "\\." t))))))

(defun dash-docs-docset-installed-p (docset)
  "Return non-nil if DOCSET is installed."
  (member (replace-regexp-in-string "_" " " docset)
          (dash-docs-installed-docsets)))

(defun dash-docs-ensure-docset-installed (docset)
  "Install DOCSET if it is not currently installed."
  (unless (dash-docs-docset-installed-p docset)
    (dash-docs-install-docset docset)))

(defun dash-docs-get-docset-url (feed-path)
  "Parse a xml feed with docset urls and return the first url.
The Argument FEED-PATH should be a string with the path of the xml file."
  (let* ((xml (xml-parse-file feed-path))
         (urls (car xml))
         (url (xml-get-children urls 'url)))
    (cl-caddr (cl-first url))))

(defun dash-docs-sub-docset-name-in-pattern (pattern docset-name)
  "Remove from PATTERN the DOCSET-NAME if this includes it.
If the search starts with the name of the docset, ignore it.
Ex: This avoids searching for redis in redis unless you type 'redis redis'"
  (replace-regexp-in-string (format "^%s "
                                    (regexp-quote (downcase docset-name)))
                            ""
                            pattern))

(defun dash-docs-sql-search (docset pattern)
  "Execute an DOCSET sql query looking for PATTERN.

Return a list of db results. Ex:

'((\"func\" \"BLPOP\" \"commands/blpop.html\")
 (\"func\" \"PUBLISH\" \"commands/publish.html\")
 (\"func\" \"problems\" \"topics/problems.html\"))"

  (let* ((docset-type (cl-caddr docset))
         ;; set docset database path
         (db-path (cadr docset))
         ;; set the sql query to be executed
         (query (dash-docs-compose-sql-query docset-type pattern)))
    ;; execute the query
    (dash-docs-exec-query db-path query)))

(defun dash-docs--candidate (docset row)
  "Return list extracting info from DOCSET and ROW to build a result candidate.
First element is the display message of the candidate, rest is used to build
candidate opts."
  (cons (format-spec dash-docs-candidate-format
                     (list (cons ?d (cl-first docset))
                           (cons ?n (cl-second row))
                           (cons ?t (cl-first row))
                           (cons ?f (replace-regexp-in-string
                                     "^.*/\\([^/]*\\)\\.html?#?.*"
                                     "\\1"
                                     (cl-third row)))))
        (list (car docset) row)))

(defun dash-docs-result-url (docset-name filename &optional anchor)
  "Return the full, absolute URL to documentation.

Either a file:/// URL joining DOCSET-NAME, FILENAME & ANCHOR or a http(s):// URL
formed as-is if FILENAME is a full HTTP(S) URL."

  (let* ((clean-filename (replace-regexp-in-string
                          "<dash_entry_.*>" "" filename))
         (path (format "%s%s"
                       clean-filename
                       (if anchor (format "#%s" anchor) ""))))
    (if (string-match-p "^https?://" path)
        path
      (replace-regexp-in-string
       " "
       "%20"
       (concat "file:///"
               (expand-file-name "Contents/Resources/Documents/"
                                 (dash-docs-docset-path docset-name))
               path)))))

(defun dash-docs-browse-url (search-result)
  "Call to `browse-url' with the result returned by `dash-docs-result-url'.
Get required params to call `dash-docs-result-url' from SEARCH-RESULT."
  (let ((docset-name (car search-result))
        (filename (nth 2 (cadr search-result)))
        (anchor (nth 3 (cadr search-result))))
    (funcall dash-docs-browser-func
             (dash-docs-result-url docset-name filename anchor))))

(defun dash-docs--debug-buffer ()
  "Return the dash-docs debugging buffer."
  (get-buffer-create "*dash-docs-errors*"))

(defun dash-docs-create-debug-buffer ()
  "Open debugging buffer and insert a header message."
  (with-current-buffer (dash-docs--debug-buffer)
    (erase-buffer)
    (insert ";; Dash-docs sqlite3 error logging.\n")))

(defun dash-docs-search-docset (docset pattern)
  "Given a string PATTERN, query DOCSET and retrieve result."
  (cl-loop for row in
           (dash-docs-sql-search docset pattern)
           collect (dash-docs--candidate docset row)))

(defun dash-docs-search (pattern)
  "Given a string PATTERN, query docsets and retrieve result."
  (when (>= (length pattern) dash-docs-min-length)
    (cl-loop for docset in (dash-docs-maybe-narrow-docsets pattern)
             appending (dash-docs-search-docset docset pattern))))

(defun dash-docs-candidates ()
  "Provide dash-doc candidates."
  ;; create connections to sqlite docsets for common docsets
  (dash-docs-create-common-connections)
  (let ((candidates
         (cl-loop for docset in (dash-docs-maybe-narrow-docsets "")
                  appending (dash-docs-search-docset docset ""))))
    candidates))

;; parse function (search)
(defun dash-docs-search-result (wanted candidates)
  "Get the WANTED search result from docs CANDIDATES."
  (let* ((i 0)
         (n (catch 'nth-elt
              (dolist (candidate candidates)
                (when (equal wanted (car candidate))
                  (throw 'nth-elt i))
                (setq i (+ 1 i)))))
         ;; attributes from candidates -> (())
         (search-result (nth n candidates)))
    ;; remove first element from search results
    (pop search-result)
    ;; return search result
    search-result))

(defun dash-docs-read-docset (prompt choices)
  "Read from the `minibuffer' using PROMPT and CHOICES as candidates.
Report an error unless a valid docset is selected."
  (let ((completion-ignore-case t))
    (completing-read (format "%s (%s): " prompt (car choices))
                     choices nil t nil nil choices)))

;;;###autoload
(defun dash-docs-clean-connections ()
  "Clean (set) `dash-docs--connections'."
  (interactive)
  ;; set internal var to nil
  (setq dash-docs--connections nil))

;;;###autoload
(defun dash-docs-activate-docset (docset)
  "Activate a DOCSET, i.e, make a connection to its database.
If called interactively prompts for the docset name."
  ;; map docset function param
  (interactive
   (list (dash-docs-read-docset "Activate docset"
                                (dash-docs-installed-docsets))))
  ;; add docset to docsets list
  (push docset dash-docs-common-docsets)
  ;; reset connections
  (dash-docs-clean-connections))

;;;###autoload
(defun dash-docs-deactivate-docset (docset)
  "Deactivate DOCSET, i.e, update common docsets.
If called interactively prompts for the docset name."
  ;; read docset param
  (interactive
   (list (dash-docs-read-docset "Deactivate docset"
                                dash-docs-common-docsets)))
  ;; delete docset from common docsets
  (setq dash-docs-common-docsets
        (delete docset dash-docs-common-docsets)))

;;;###autoload
(defun dash-docs-install-user-docset (docset-name)
  "Download an unofficial docset with specified DOCSET-NAME."
  (interactive
   (list (dash-docs-read-docset "Install docset"
                                (mapcar 'car
                                        (dash-docs-unofficial-docsets)))))
  ;; create docsets path
  (when (dash-docs--created-docsets-path
         (dash-docs-docsets-path)))
  ;; install docset
  (let ((url (car (assoc-default docset-name
                                 (dash-docs-unofficial-docsets)))))
    (dash-docs--install-docset url docset-name)))

;;;###autoload
(defun dash-docs-install-docset-from-file (docset-tmp-path)
  "Extract the content of DOCSET-TMP-PATH.
Move it to `dash-docs-docsets-path' and activate the docset."
  (interactive
   (list (car (find-file-read-args "Docset Tarball: " t))))
  (let ((docset-folder (dash-docs-extract-and-get-folder docset-tmp-path)))
    (dash-docs-activate-docset docset-folder)
    (message "Docset installed. Add \"%s\" to dash-docs-common-docsets."
             docset-folder)))

;;;###autoload
(defun dash-docs-install-docset (docset-name)
  "Download an official docset with specified DOCSET-NAME.
Move its stuff to docsets-path."
  (interactive
   (list (dash-docs-read-docset
          "Install docset"
          (dash-docs-official-docsets))))
  ;; create docsets if necessary
  (when (dash-docs--created-docsets-path (dash-docs-docsets-path)))
  ;; format url, download docset file (url-copy-file)
  ;; and move it to the right location (docset paths)
  (let ((feed-url (format "%s/%s.xml"
                          dash-docs-docsets-feed-url
                          docset-name))
        (feed-tmp-path (format "%s%s-feed.xml"
                               temporary-file-directory
                               docset-name))
        (url nil))
    ;; copy url file
    (url-copy-file feed-url feed-tmp-path t)
    ;; update url
    (setq url (dash-docs-get-docset-url feed-tmp-path))
    ;; install docset
    (dash-docs--install-docset url docset-name)))

;;;###autoload
(defun dash-docs-async-install-docset-from-file (docset-tmp-path)
  "Asynchronously extract the content of DOCSET-TMP-PATH.
Move it to `dash-docs-docsets-path` and activate the docset."
  (interactive
   (list (car (find-file-read-args "Docset Tarball: " t))))
  ;; extract the archive contents
  (let ((docset-folder (dash-docs-extract-and-get-folder docset-tmp-path)))
    (dash-docs-activate-docset docset-folder)
    (message (format
              "Docset installed. Add \"%s\" to dash-docs-common-docsets."
              docset-folder))))

;;;###autoload
(defun dash-docs-find-docs ()
  "Find documentation using `dash-docs' capabilities."
  (interactive)
  (let* ((candidates (dash-docs-candidates))
         (candidate (completing-read "Docs: " candidates nil t)))
    (cond ((eq candidate "")
           (message "Please provide a search string"))
          ;; default
          (t (dash-docs-browse-url
              (dash-docs-search-result candidate candidates))))))

;;;###autoload
(defalias 'find-dash-docs 'dash-docs-find-docs)

(provide 'dash-docs)

;;; dash-docs.el ends here
