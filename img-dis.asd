(defsystem "img-dis"
    :depends-on (#:spack #:usocket #:bordeaux-threads #:stmx #:trivial-timer)
    :author "seanptmaher@gmail.com"
    :components
    ((:module src
              :serial t
              :components
              ((:file "drone")
               (:file "commander")))))
