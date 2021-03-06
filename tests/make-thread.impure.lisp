(in-package "SB-THREAD")

#+cheneygc (sb-ext:exit :code 104)

;;; Test out-of-memory (or something) that goes wrong in pthread_create
#+pauseless-threadstart ; no SB-THREAD::PTHREAD-CREATE symbol if not
(test-util:with-test (:name :failed-thread-creation)
  (let ((encapsulation
          (compile nil
                   '(lambda (realfun thread stack-base)
                     (if (string= (sb-thread:thread-name thread) "finalizer")
                         (funcall realfun thread stack-base)
                         nil))))
        (success))
    ;; This test checks that if pthread_create fails, nothing is added to *STARTING-THREADS*.
    ;; If there were an entry spuriously added, it would remain forever, as the thread we're
    ;; attempting to create would not consume and clear out its startup data.
    ;; So as a precondition to the test, *STARTING-THREADS* must be NIL. If it isn't, then
    ;; there must have been a finalizer thread started, and it would have left a 0 in the list,
    ;; which is the telltale mark of a thread that smashed its startup data.
    ;; So if the list is not NIL right now, assert that there is a finalizer thread,
    ;; and then set the list to NIL.
    ;; [The rationale for the 0 is that responsibility for deletion from the list falls to the
    ;; next MAKE-THREAD so that new threads need not synchronize with creators for exclusive
    ;; access to the list. But threads can safely RPLACA their own cell in *STARTING-THREADS*
    ;; allowing it to be GC'd even if nothing subsequently prunes out un-needed cons cells]
    (assert (or (null sb-thread::*starting-threads*)
                (equal sb-thread::*starting-threads* '(0))))

    (unwind-protect
         (progn (sb-int:encapsulate 'sb-thread::pthread-create 'test encapsulation)
                (handler-case (sb-thread:make-thread #'list :name "thisfails")
                  (error (e)
                    (setq success (string= (write-to-string e)
                                           "Could not create new OS thread.")))))
      (sb-int:unencapsulate 'sb-thread::pthread-create 'test))
    (assert (null sb-thread::*starting-threads*))
    (assert (equal (remove-if #'sb-thread:thread-ephemeral-p
                              (sb-thread::avltree-list sb-thread::*all-threads*))
                   (list sb-thread::*initial-thread*)))))

(defun actually-get-stack-roots (current-sp
                                 &key allwords (print t)
                                 &aux (current-sp (descriptor-sap current-sp))
                                      (roots))
  (declare (type (member nil t :everything) allwords))
  (without-gcing
    (binding* ((stack-low (get-lisp-obj-address sb-vm:*control-stack-start*))
               (stack-high (get-lisp-obj-address sb-vm:*control-stack-end*))
               ((nwords copy-from direction base)
                #+c-stack-is-control-stack ; growth direction is always down
                (values (ash (- stack-high (sap-int current-sp)) (- sb-vm:word-shift))
                        current-sp #\- "sp")
                #-c-stack-is-control-stack ; growth direction is always up
                (values (ash (- (sap-int current-sp) stack-low) (- sb-vm:word-shift))
                        (int-sap stack-low) #\+ "base"))
               (array (make-array nwords :element-type 'sb-ext:word)))
      (when print
        (format t "SP=~a~dw (range = ~x..~x)~%" direction nwords stack-low stack-high))
      (alien-funcall (extern-alien "memcpy" (function void system-area-pointer
                                                      system-area-pointer unsigned))
                     (vector-sap array) copy-from (* nwords sb-vm:n-word-bytes))
      (loop for i downfrom (1- nwords) to 0 by 1 do
        (let ((word (aref array i)))
          (when (or (/= word sb-vm:nil-value) allwords)
            (let ((baseptr (alien-funcall (extern-alien "search_all_gc_spaces" (function unsigned unsigned))
                                          word)))
              (cond ((/= baseptr 0) ; an object reference
                     (let ((obj (sb-vm::reconstitute-object (%make-lisp-obj baseptr))))
                       (when (code-component-p obj)
                         (cond
                          #+c-stack-is-control-stack
                          ((= (logand word sb-vm:lowtag-mask) sb-vm:fun-pointer-lowtag)
                           (dotimes (i (code-n-entries obj))
                             (when (= (get-lisp-obj-address (%code-entry-point obj i)) word)
                               (return (setq obj (%code-entry-point obj i))))))
                          #-c-stack-is-control-stack ; i.e. does this backend have LRAs
                          ((= (logand (sap-ref-word (int-sap (logandc2 word sb-vm:lowtag-mask)) 0)
                                      sb-vm:widetag-mask) sb-vm:return-pc-widetag)
                           (setq obj (%make-lisp-obj word)))))
                       ;; interior pointers to objects that contain instructions are OK,
                       ;; otherwise only correctly tagged pointers.
                       (when (or (typep obj '(or fdefn code-component funcallable-instance))
                                 (= (get-lisp-obj-address obj) word))
                         (push obj roots)
                         (when print
                           (format t "~x = ~a[~5d] = ~16x (~A) "
                                   (sap-int (sap+ copy-from (ash i sb-vm:word-shift)))
                                   base i word
                                   (or (generation-of obj) #\S)) ; S is for static
                           (let ((*print-pretty* nil))
                             (cond ((consp obj) (format t "a cons"))
                                   #+sb-fasteval
                                   ((typep obj 'sb-interpreter::sexpr) (format t "a sexpr"))
                                   ((arrayp obj) (format t "a ~s" (type-of obj)))
                                   #+c-stack-is-control-stack
                                   ((and (code-component-p obj)
                                         (>= word (sap-int (code-instructions obj))))
                                    (format t "PC in ~a" obj))
                                   (t (format t "~a" obj))))
                           (terpri)))))
                    ((and print
                          (or (eq allwords :everything) (and allwords (/= word 0))))
                     (format t "~x = ~a[~5d] = ~16x~%"
                             (sap-int (sap+ copy-from (ash i sb-vm:word-shift)))
                             base i word)))))))))
  (if print
      (format t "~D roots~%" (length roots))
      roots))
(defun get-stack-roots (&rest rest)
  (apply #'actually-get-stack-roots (%make-lisp-obj (sap-int (current-sp))) rest))

(defstruct big-structure x)
(defstruct other-big-structure x)
(defun make-a-closure (arg options)
  (lambda (&optional (z 0) y)
    (declare (ignore y))
    (test-util:opaque-identity
     (format nil "Ahoy-hoy! ~d~%" (+ (big-structure-x arg) z)))
    (apply #'get-stack-roots options)))
(defun tryit (&rest options)
  (let ((thread
          (make-thread (make-a-closure (make-big-structure :x 0) options)
                       :arguments (list 1 (make-other-big-structure)))))
    ;; Sometimes the THREAD instance shows up in the list of objects
    ;; on the stack, sometimes it doesn't. This is annoying, but work around it.
    (remove thread (join-thread thread))))

(defun make-a-closure-nontail (arg)
  (lambda (&optional (z 0) y)
    (declare (ignore y))
    (get-stack-roots)
    (test-util:opaque-identity
     (format nil "Ahoy-hoy! ~d~%" (+ (big-structure-x arg) z)))
    1))
(defun tryit-nontail ()
  (join-thread
   (make-thread (make-a-closure-nontail (make-big-structure :x 0))
                :arguments (list 1 (make-other-big-structure)))))

;;; Test that reusing memory from an exited thread does not point to junk.
;;; In fact, assert something stronger: there are no young objects
;;; between the current SP and end of stack.
(test-util:with-test (:name :expected-gc-roots
                      :skipped-on (or :interpreter (not :pauseless-threadstart)))
  (let ((list (tryit :print nil)))
    ;; should be not many things pointed to by the stack
    (assert (< (length list) #+x86    38   ; more junk, I don't know why
                             #+x86-64 30   ; less junk, I don't know why
                             #-(or x86 x86-64) 44)) ; even more junk
    ;; Either no objects are in GC generation 0, or all are, depending on
    ;; whether CORE_PAGE_GENERATION has been set to 0 for testing.
    (let ((n-objects-in-g0 (count 0 list :key #'sb-kernel:generation-of)))
      (assert (or (= n-objects-in-g0 0)
                  (= n-objects-in-g0 (length list)))))))

;; lp#1595699
(test-util:with-test (:name :start-thread-in-without-gcing
                      :skipped-on (not :pauseless-threadstart))
  (assert (eq (sb-thread:join-thread
               (sb-sys:without-gcing
                   (sb-thread:make-thread (lambda () 'hi))))
              'hi)))
