(defpackage drone
  (:use :cl-user :cl))

(in-package :drone)

(defun listener (host port connection-handler)
  (let ((socket (usocket:socket-listen host port :element-type '(unsigned-byte 8))))
    (setf *server* (bt:make-thread
                   #'(lambda ()
                       (loop do
                            (let ((sock (usocket:socket-accept socket)))
                              (push (bt:make-thread
                                     #'(lambda ()
                                         (format *debug-io* "~A~%" sock)
                                         (let ((connection (server-handshake sock identity)))
                                           (funcall connection-handler connection)))
                                     :name "thread!")
                                    *connection-threads*))))))))
