(defpackage drone
  (:use :cl-user :cl))
(in-package :drone)

(defvar *connection-threads*)
(defvar *server*)

(defun hash-to-int (hash)
  (let ((acc 0))
    (loop for i from 0 below (length hash) do
      (setf acc (logior acc (ash (aref hash i) (* i 8)))))
    acc))

(defun listener (host port)
  (let ((socket (usocket:socket-listen host port :element-type '(unsigned-byte 8))))
    (setf *server* (bt:make-thread
                    #'(lambda ()
                        (loop do
                          (let ((sock (usocket:socket-accept socket)))
                            (push (bt:make-thread
                                   #'(lambda ()
                                       (handler sock))
                                   :name "thread!")
                                  *connection-threads*))))))))

(defclass data ()
  ((data :initform (make-hash-table) :accessor data)))

(defun handler (socket)
  (let ((data (make-instance 'data))
        (sp))
    (loop do
      (usocket:wait-for-input socket :ready-only t)
      (setf sp (spack:parse (usocket:socket-stream socket)))
      (cond
        ((string= "hey" (spack:val (car (spack:elements sp))))
         (loop for i in (spack:out (spack:make-and-push ("hey" :string))) do
           (write-byte i (usocket:socket-stream socket)))
         (force-output (usocket:socket-stream socket)))
        ((string= "put" (spack:val (car (spack:elements sp))))
         (progn
           (spack:destructuring-elements (cmd hash buf) sp
             (declare (ignore cmd))
             (setf (gethash (hash-to-int hash) (data data)) buf))
           (loop for i in (spack:out (spack:make-and-push ("done" :string))) do
             (write-byte i (usocket:socket-stream socket)))
           (force-output (usocket:socket-stream socket))))
        ((string= "get" (spack:val (car (spack:elements sp))))
         (progn
           (spack:destructuring-elements (cmd hash) sp
             (declare (ignore cmd))
             (if (nth-value 1 (gethash (hash-to-int hash) (data data)))
                 (loop for i in (spack:out
                                 (spack:make-and-push ("done" :string)
                                                      ((gethash (hash-to-int hash) (data data)) :byte-array)))
                       do (write-byte i (usocket:socket-stream socket)))
                 (loop for i in (spack:out (spack:make-and-push ("fail" :string) (#(0) :byte-array)))
                       do (write-byte i (usocket:socket-stream socket)))))
           (force-output (usocket:socket-stream socket))))))))
