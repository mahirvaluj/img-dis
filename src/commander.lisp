(defpackage commander
  (:use :cl :cl-user))
(in-package :commander)

(defvar *num-hash-slots* 6961) ;; large-ish-prime, I don't think
                               ;; you'll end up having more than 6961
                               ;; drones in the cluster
(defvar *connection-threads* nil)
(defvar *server*)
(defvar *state*)
(defvar *q*)

;; (defclass queue ()
;;   ((ql :initform nil :accessor ql)
;;    (tail :initform nil :accessor tail)))

;; (defmethod enqueue (obj (q queue))
;;   (if (null (tail q))
;;       (setf (ql q) (list obj)
;;             (tail q) (ql q))
;;       (setf (cdr (tail q)) (cons obj nil)
;;             (tail q) (cdr (tail q)))))

;; (defmethod dequeue ((q queue))
;;   (if (null (tail q))
;;       nil
;;       (let ((ret (pop (ql q))))
;;         (when (null (ql q))
;;           (setf (tail q) nil))
;;         ret)))

(stmx:transactional
    (defclass drone ()
      ((active :initarg :active :accessor active)
       (assignments :initarg :assignments :accessor assignments)
       (socket :initarg :socket :accessor socket))))

(stmx:transactional
    (defclass state ()
      ((drones :initform (make-array 8 :fill-pointer 0 :adjustable t) :accessor peers)
       (assignments :initform (make-hash-table) :accessor assignments))))

(defun connect-drone (host port)
  (let ((drone (make-instance 'drone
                              :active t
                              :assignments nil
                              :socket (usocket:socket-connect host port :element-type '(unsigned-byte 8)))))
    (loop for i across (spack:out (spack:make-and-push ("hey" :string)))
          do (write-byte i (usocket:socket-stream (socket drone))))
    (if (usocket:wait-for-input (usocket:socket-stream (socket drone)) :ready-only t)
        (string= "hey" (spack:val (car (spack:elements (spack:parse (usocket:socket-stream (socket drone)))))))
        nil)))

;; returns the drone that the assignment was added to
(defun add-assignment (state slot)
  (let ((min nil))
    (stmx:atomic
     (loop for i across (drones state) do
       (when (or (null min)
                 (> (length (assignments min)) (length (assignments i))))
         (setf min i)))
     (push slot (assignments min))
     (setf (gethash slot (assignments state)) min))))

(defun hash-to-int (hash)
  (let ((acc 0))
    (loop for i from 0 below (length hash) do
      (setf acc (logior acc (ash (aref hash i) (* i 8)))))
    acc))

;; returns hash of data to get it back
(defun put (buf &optional (state *state*))
  (let* ((hash (ironclad:digest-sequence :sha256 buf))
         (slot (mod (hash-to-int hash) *num-hash-slots*))
         (drone (gethash slot (assignments state))))
    (unless (nth-value 1 (gethash slot (assignments state)))
      (setf drone (add-assignment state slot)))
    ;; after assigning the slot to a drone
    (loop for i across (spack:out (spack:make-and-push ("put" :string)
                                                       (hash :byte-array)
                                                       (buf :byte-array)))
          do (write-byte i (usocket:socket-stream (socket drone))))
    (force-output (usocket:socket-stream (socket drone)))
    (if (usocket:wait-for-input (usocket:socket-stream (socket drone)) :ready-only t)
        (spack:destructuring-elements (status) (spack:parse (usocket:socket-stream (socket drone)))
          (string= status "done"))
        nil)))

;; returns a stream of the data or nil on failure
(defun take (hash &optional (state *state*))
  (let* ((slot (mod (hash-to-int hash) *num-hash-slots*))
         (drone (gethash slot (assignments state))))
    (unless (nth-value 1 (gethash slot (assignments state)))
      (return-from take nil))
    (loop for i across (spack:out (spack:make-and-push ("get" :string)
                                                       (hash :byte-array)))
          do (write-byte i (usocket:socket-stream (socket drone))))
    (force-output (usocket:socket-stream (socket drone)))
    (if (usocket:wait-for-input (usocket:socket-stream (socket drone)) :ready-only t)
        (spack:destructuring-elements (status buf) (spack:parse (usocket:socket-stream (socket drone)))
          (if (string= status "done")
              buf
              nil))
        nil)))
