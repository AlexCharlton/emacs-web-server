;;; emacs-web-server-test.el --- Test the Emacs Web Server

;; Copyright (C) 2013 Eric Schulte <schulte.eric@gmail.com>

;; Author: Eric Schulte <schulte.eric@gmail.com>
;; License: GPLV3 (see the COPYING file in this directory)

;;; Code:
(require 'emacs-web-server)
(require 'cl-lib)
(eval-when-compile (require 'cl))
(require 'ert)

(defvar ews-test-port 8999)

(defun ews-test-curl-to-string (url &optional get-params post-params)
  "Curl URL with optional parameters."
  (async-shell-command
   (format "curl -m 4 %s %s localhost:%s/%s"
           (if get-params
               (mapconcat (lambda (p) (format "-d '%s=%s'" (car p) (cdr p)))
                          get-params " ")
             "")
           (if post-params
               (mapconcat (lambda (p) (format "-s -F '%s=%s'" (car p) (cdr p)))
                          post-params " ")
             "")
           ews-test-port url))
  (unwind-protect
      (with-current-buffer "*Async Shell Command*"
        (while (get-buffer-process (current-buffer)) (sit-for 0.1))
        (goto-char (point-min))
        (buffer-string))
    (kill-buffer "*Async Shell Command*")))

(defmacro ews-test-with (handler &rest body)
  (declare (indent 1))
  (let ((srv (cl-gensym)))
    `(let* ((,srv (ews-start ,handler ews-test-port)))
       (unwind-protect (progn ,@body) (ews-stop ,srv)))))
(def-edebug-spec ews-test-with (form body))

(ert-deftest ews/keyword-style-handler ()
  "Ensure that a simple keyword-style handler matches correctly."
  (ews-test-with (mapcar (lambda (letter)
                           `((:GET . ,letter) .
                             (lambda (request)
                               (ews-response-header (process request) 200
                                 '("Content-type" . "text/plain"))
                               (process-send-string (process request)
                                 (concat "returned:" ,letter)))))
                         '("a" "b"))
    (should (string= "returned:a" (ews-test-curl-to-string "a")))
    (should (string= "returned:b" (ews-test-curl-to-string "b")))))

(ert-deftest ews/function-style-handler ()
  "Test that a simple hello-world server responds."
  (ews-test-with
      '(((lambda (_) t) .
         (lambda (request)
           (ews-response-header (process request) 200
             '("Content-type" . "text/plain"))
           (process-send-string (process request) "hello world"))))
    (should (string= (ews-test-curl-to-string "") "hello world"))))

(ert-deftest ews/removed-from-ews-servers-after-stop ()
  (let ((start-length (length ews-servers)))
    (let ((server (ews-start nil ews-test-port)))
      (should (= (length ews-servers) (+ 1 start-length)))
      (ews-stop server)
      (should (= (length ews-servers) start-length)))))

(ert-deftest ews/parse-many-headers ()
  "Test that a number of headers parse successfully."
  (let ((server (ews-start nil ews-test-port))
        (request (make-instance 'ews-request))
        (header-string "GET / HTTP/1.1
Host: localhost:7777
User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:26.0) Gecko/20100101 Firefox/26.0
Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8
Accept-Language: en-US,en;q=0.5
Accept-Encoding: gzip, deflate
DNT: 1
Cookie: __utma=111872281.1462392269.1345929539.1345929539.1345929539.1
Connection: keep-alive

"))
    (unwind-protect
        (progn
          (ews-parse-request request header-string)
          (let ((headers (cdr (headers request))))
            (should (string= (cdr (assoc :ACCEPT-ENCODING headers))
                             "gzip, deflate"))
            (should (string= (cdr (assoc :GET headers)) "/"))
            (should (string= (cdr (assoc :CONNECTION headers)) "keep-alive"))))
      (ews-stop server))))

(ert-deftest ews/parse-post-data ()
  (let ((server (ews-start nil ews-test-port))
        (request (make-instance 'ews-request))
        (header-string "POST / HTTP/1.1
User-Agent: curl/7.33.0
Host: localhost:8080
Accept: */*
Content-Length: 273
Expect: 100-continue
Content-Type: multipart/form-data; boundary=----------------f1270d0deb77af03

------------------f1270d0deb77af03
Content-Disposition: form-data; name=\"date\"

Wed Dec 18 00:55:39 MST 2013

------------------f1270d0deb77af03
Content-Disposition: form-data; name=\"name\"

\"schulte\"
------------------f1270d0deb77af03--
"))
    (unwind-protect
        (progn
          (ews-parse-request request header-string)
          (let ((headers (cdr (headers request))))
            (should (string= (cdr (assoc "name" headers))
                             "\"schulte\""))
            (should (string= (cdr (assoc "date" headers))
                             "Wed Dec 18 00:55:39 MST 2013"))))
      (ews-stop server))))

(ert-deftest ews/parse-another-post-data ()
  "This one from an AJAX request."
  (let ((server (ews-start nil ews-test-port))
        (request (make-instance 'ews-request))
        (header-string "POST /complex.org HTTP/1.1
Host: localhost:4444
User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:26.0) Gecko/20100101 Firefox/26.0
Accept: */*
Accept-Language: en-US,en;q=0.5
Accept-Encoding: gzip, deflate
DNT: 1
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
X-Requested-With: XMLHttpRequest
Referer: http://localhost:4444/complex.org
Content-Length: 78
Cookie: __utma=111872281.1462392269.1345929539.1345929539.1345929539.1
Connection: keep-alive
Pragma: no-cache
Cache-Control: no-cache

org=-+one%0A-+two%0A-+three%0A-+four%0A%0A&beg=646&end=667&path=%2Fcomplex.org"))
    (unwind-protect
        (progn
          (ews-parse-request request header-string)
          (let ((headers (cdr (headers request))))
            (message "headers:%S" headers)
            (should (string= (cdr (assoc "path" headers)) "/complex.org"))
            (should (string= (cdr (assoc "beg" headers)) "646"))
            (should (string= (cdr (assoc "end" headers)) "667"))
            (should (string= (cdr (assoc "org" headers))
                             "- one
- two
- three
- four

"))))
      (ews-stop server))))

(ert-deftest ews/simple-post ()
  "Test a simple POST server."
  (ews-test-with
      '(((:POST . ".*") .
         (lambda (request)
           (with-slots (process headers) request
             (let ((message (cdr (assoc "message" headers))))
               (ews-response-header process 200
                 '("Content-type" . "text/plain"))
               (process-send-string process
                 (format "you said %S\n" message)))))))
    (should (string= (ews-test-curl-to-string "" nil '(("message" . "foo")))
                     "you said \"foo\"\n"))))

(ert-deftest ews/in-directory-p ()
  (should-not (ews-in-directory-p "/tmp/" "foo/bar/../../../"))
  (should     (ews-in-directory-p "/tmp/" "foo/bar/../../../tmp/baz"))
  (should     (ews-in-directory-p "/tmp/" "./"))
  (should-not (ews-in-directory-p "/tmp/" "/~/pics"))
  (should-not (ews-in-directory-p "/tmp/" "~/pics"))
  (should-not (ews-in-directory-p "/tmp/" "/pics"))
  (should-not (ews-in-directory-p "/tmp/" "../pics"))
  (should     (ews-in-directory-p "/tmp/" "pics"))
  (should-not (ews-in-directory-p "/tmp/" "..")))

(provide 'emacs-web-server-test)
