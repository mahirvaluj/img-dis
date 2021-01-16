(defsystem "img-dis"
    :depends-on (#:ieee-floats #:trivial-utf-8 #:cl-intbytes #:ironclad #:usocket #:bordeaux-threads #:stmx #:trivial-timer)
    :author "seanptmaher@gmail.com"
    :components
    ((:module src
              :serial t
              :components
              ((:file "spack")
               (:file "leb128")
               (:file "commander")
               (:file "drone")))))
