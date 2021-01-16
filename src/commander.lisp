(defpackage commander
  (:use :cl :cl-user))
(in-package :commander)

(defvar *num-hash-slots* 6961) ;; large-ish-prime, I don't think
                               ;; you'll end up having more than 6961
                               ;; drones in the cluster
(defvar *state*)


(defvar *testing*)

(defclass drone ()
  ((active :initarg :active :accessor active)
   (assignments :initarg :assignments :accessor assignments)
   (sock :initarg :sock :accessor sock)))

(defclass state ()
  ((drones :initform (make-array 8 :fill-pointer 0 :adjustable t) :accessor drones)
   (assignments :initform (make-hash-table) :accessor assignments)))

(defun init ()
  (setf *state* (make-instance 'state)))

(defun connect-drone (host port)
  (let ((drone (make-instance 'drone
                              :active t
                              :assignments nil
                              :sock (usocket:socket-connect host port :element-type '(unsigned-byte 8)))))
    (loop for i across (spack:out (spack:make-and-push ("hey" :string)))
          do (write-byte i (usocket:socket-stream (sock drone))))
    (force-output (usocket:socket-stream (sock drone)))
    (if (usocket:wait-for-input (sock drone) :ready-only t)
        (if (string= "hey" (spack:val (aref (spack:elements (spack:parse (usocket:socket-stream (sock drone)))) 0)))
            (vector-push-extend drone (drones *state*)))
        nil)))

;; returns the drone that the assignment was added to
(defun add-assignment (state slot)
  (let ((min nil))
    (loop for i across (drones state) do
      (when (or (null min)
                (> (length (assignments min)) (length (assignments i))))
        (setf min i)))
    (push slot (assignments min))
    (setf (gethash slot (assignments state)) min)))

(defun hash-to-int (hash)
  (let ((acc 0))
    (loop for i from 0 below (length hash) do
      (setf acc (logior acc (ash (aref hash i) (* i 8)))))
    acc))


(defun put-img (filespec)
  (with-open-file (s filespec :element-type '(unsigned-byte 8))
    (let ((buf (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (loop for i from 0 below (length buf) do
        (setf (aref buf i) (read-byte s)))
      (put buf))))

;; returns hash of data to get it back
(defun put (buf &optional (state *state*))
  (let* ((hash (ironclad:digest-sequence :sha256 buf))
         (slot (mod (hash-to-int hash) *num-hash-slots*))
         (drone (gethash slot (assignments state))))
    (unless (nth-value 1 (gethash slot (assignments state)))
      (setf drone (add-assignment state slot)))
    ;; after assigning the slot to a drone
    (let ((o (spack:out (spack:make-and-push ("put" :string)
                                             (hash :byte-array)
                                             (buf :byte-array)))))
      (format *debug-io* "len: ~A~%" (length o))
      (setf *testing* o)
      (loop for i across o
            do (write-byte i (usocket:socket-stream (sock drone)))))
    (force-output (usocket:socket-stream (sock drone)))
    (if (usocket:wait-for-input (sock drone) :ready-only t)
        (spack:destructuring-elements (status) (spack:parse (usocket:socket-stream (sock drone)))
          (if (string= status "done-put")
              hash
              nil))
        nil)))

;; returns a stream of the data or nil on failure
(defun take (hash &optional (state *state*))
  (let* ((slot (mod (hash-to-int hash) *num-hash-slots*))
         (drone (gethash slot (assignments state))))
    (unless (nth-value 1 (gethash slot (assignments state)))
      (return-from take nil))
    (loop for i across (spack:out (spack:make-and-push ("get" :string)
                                                       (hash :byte-array)))
          do (write-byte i (usocket:socket-stream (sock drone))))
    (force-output (usocket:socket-stream (sock drone)))
    (if (usocket:wait-for-input (sock drone) :ready-only t)
        (spack:destructuring-elements (status buf) (spack:parse (usocket:socket-stream (sock drone)))
          (if (string= status "done-get")
              buf
              nil))
        nil)))
