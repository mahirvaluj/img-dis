(defsystem "img-dis"
    :depends-on (#:ieee-floats #:trivial-utf-8 #:cl-intbytes #:ironclad #:usocket #:bordeaux-threads)
    :author "seanptmaher@gmail.com"
    :components
    ((:module src
              :serial t
              :components
              ((:file "leb128")
               (:file "spack")
               (:file "commander")
               (:file "drone")))))
