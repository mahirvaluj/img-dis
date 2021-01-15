(defpackage :consensus
  (:use :cl :cl-user))
(in-package :consensus)

(defvar *max-len* 65507)
(defvar *state*)

(stmx:transactional
    (defclass state ()
      ((curr-term :initarg :curr-term :accessor curr-term)
       (voted-for :initarg :voted-for :accessor voted-for)
       (event-log :initarg :event-log :accessor event-log)
       (commit-index :initarg :commit-index :accessor commit-index)
       (last-applied :initarg :last-applied :accessor last-applied)
       (inner-state :initarg :inner-state :accessor inner-state)
       (next-index :initarg :next-index :accessor next-index)
       (match-index :initarg :match-index :accessor match-index)
       (nodes :initarg :nodes :accessor nodes)
       (node-state :initarg :node-state :accessor node-state)
       )))

(stmx:transactional
    (defclass request-votes ()
      ((term :initarg :term :accessor term)
       (candidate-id :initarg :candidate-id :accessor candidate-id)
       (last-log-index :initarg :last-log-index :accessor last-log-index)
       (last-log-term :initarg :last-log-term :accessor last-log-term)
       (reply-closure :initarg :reply-closure :accessor reply-closure)
       )))

(stmx:transactional
    (defclass append-events ()
      ((term :initarg :term :accessor term)
       (leader-id :initarg :leader-id :accessor leader-id)
       (prev-log-index :initarg :prev-log-index :accessor prev-log-index)
       (prev-log-term :initarg :prev-log-term :accessor prev-log-term)
       (events :initarg :events :accessor events)
       (leader-commit :initarg :leader-commit :accessor leader-commit)
       (reply-closure :initarg :reply-closure :accessor reply-closure)
       )))

(stmx:transactional
    (defclass event ()
      ((term :initarg :term :accessor term)
       (data :initarg :data :accessor data))))

(stmx:transactional
    (defclass inner-state ()
      ()
      ))

(defmethod apply-consensus-event ((rv request-votes) (state state))
  (when (> (term rv) (curr-term state))
    (setf (curr-term state) (term rv))
    (setf (node-state state) :follower))
  (cond
    ((< (term rv) (curr-term state))
     (funcall (reply-closure rv) (curr-term state) nil))
    ((and (or (null (voted-for state))
              (equal (voted-for state)
                     (candidate-id rv)))
          (<= (last-applied state) (last-log-index rv)))
     (funcall (reply-closure rv) (curr-term state) t))
    (t
     (funcall (reply-closure rv) (curr-term state) nil))))

(defmethod apply-consensus-event ((ae append-events) (state state))
  (cond
    ((< (term ae) (curr-term state))
     (funcall (reply-closure ae) (curr-term state) nil)
     (return-from apply-consensus-event))
    ((< (- (length (event-log state)) 1) (prev-log-index ae))
     (funcall (reply-closure ae) (curr-term state) nil)
     (return-from apply-consensus-event))
    ((not (= (term (aref (event-log state) (prev-log-index ae)))
             (prev-log-term ae)))
     (funcall (reply-closure ae) (curr-term state) nil)
     (setf (fill-pointer (event-log state)) (prev-log-index ae))))
  (let ((last-event-index (append-events (events ae) state)))
    (when (> (leader-commit ae) (commit-index state))
      (setf (commit-index state) (min (leader-commit ae) last-event-index)))))

(defun append-events (events state)
  (let ((ret))
    (loop for e in events do
      (setf ret (vector-push-extend e (event-log state))))
    ret))

(defmethod serialize (e event)
  (error "Must specialize serialize for an event"))

(defmethod apply-next-event ((state state))
  (unless (apply-event (aref (event-log state) (+ 1 (last-applied state)))
                       (inner-state state))
    (error "Failed to apply event, hard crash"))
  (incf (last-applied state)))

(defmethod apply-event ((e event) (is inner-state))
  (error "Must specialize apply-event for a particular inner-state"))

(defun default-handler (buffer size client receive-port)
  (let ((sp (spack:parse buffer)))
    (cond
      ((string= (spack:val (first (spack:elements sp)))
                "rv")
       (spack:destructuring-elements (type term candidate-id last-log-index last-log-term) sp
         (stmx:atomic
          (apply-consensus-event (make-instance 'request-votes
                                                :term term
                                                :candidate-id candidate-id
                                                :last-log-index last-log-index
                                                :last-log-term last-log-term)
                                 *state*))))
      ((string= (spack:val (first (spack:elements sp)))
                "ae")
       (spack:destructuring-elements (type term leader-id prev-log-index prev-log-term events leader-commit) sp
         (stmx:atomic
          (apply-consensus-event (make-instance 'append-entries
                                                :term term
                                                :leader-id leader-id
                                                :prev-log-index prev-log-index
                                                :prev-log-term prev-log-term
                                                :events events
                                                :leader-commit leader-commit)
                                 *state*)))))))

(defun join-cluster (nodes port &key (handler #'default-handler))
  (let ((socket (usocket:socket-connect nil nil
					:protocol :datagram
					:element-type '(unsigned-byte 8)
					:local-host "0.0.0.0"
					:local-port port))
        (buffer (make-array *max-len* :element-type '(unsigned-byte 8))))
    (init-system socket handler buffer
                 (make-instance 'state
                                :curr-term 0
                                :voted-for nil
                                :event-log (make-array 8 :fill-pointer 0 :adjustable t)
                                :commit-index -1
                                :last-applied -1
                                :next-index nil ;; re-initialized on leader election
                                :match-index nil ;; same
                                :node-state :follower))))

(defun init-system (socket handler buffer state)
  (setf *state* state)
  (let ((watchdog (bt:make-thread #'(lambda () (watchdog *state*))))
        (event-handler (bt:make-thread
                        #'(lambda ()
                            (loop do
                              (usocket:wait-for-input socket :ready-only t)
	                      (multiple-value-bind (buffer size client receive-port)
                                  (usocket:socket-receive socket buffer *max-len*)
                                (funcall handler buffer size client receive-port))))))
        (worker (bt:make-thread #'(lambda () (worker *state*)))))
    (unwind-protect
         (progn
           (bt:join-thread worker)
           (bt:join-thread watchdog)
           (bt:join-thread event-handler))
      (progn
        (usocket:socket-close socket)
        (bt:destroy-thread worker)
        (bt:destroy-thread watchdog)
        (bt:destroy-thread event-handler)))))

(defun worker (state)
  (loop do
    (stmx:atomic
     (when (> (commit-index state) (last-applied state))
       (apply-next-event state)))))

(defun watchdog (state)
  )

(defun cause-election (state)
  )


