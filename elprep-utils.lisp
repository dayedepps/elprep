(in-package :elprep)

(defun explain-flag (flag)
  (let ((result '()))
    (macrolet ((test (&rest bits)
                 `(progn ,@(loop for bit in bits
                                 for bitn = (symbol-name bit)
                                 for bitk = (intern (subseq bitn 1 (1- (length bitn))) :keyword)
                                 collect `(when (/= (logand flag ,bit) 0)
                                            (push ,bitk result))))))
      (test +supplementary+
            +duplicate+
            +qc-failed+
            +secondary+
            +last+
            +first+
            +next-reversed+
            +reversed+
            +next-unmapped+
            +unmapped+
            +proper+
            +multiple+))
    result))
 
(defun sam-alignment-differ (aln1 aln2)
  (declare (sam-alignment aln1 aln2) #.*optimization*)
  ; check that all mandatory fields are =
  (or (when (string/= (the simple-base-string (sam-alignment-qname aln1)) (the simple-base-string (sam-alignment-qname aln2))) 'qname)
      (when (/= (the fixnum (sam-alignment-flag aln1)) (the fixnum (sam-alignment-flag aln2))) 'flag)
      (when (string/= (the simple-base-string (sam-alignment-rname aln1)) (the simple-base-string (sam-alignment-rname aln2))) 'rname)
      (when (/= (the int32 (sam-alignment-pos aln1)) (the int32 (sam-alignment-pos aln2))) 'pos)
      (when (/= (sam-alignment-mapq aln1) (sam-alignment-mapq aln2)) 'mapq)
      (when (string/= (the simple-base-string (sam-alignment-cigar aln1)) (the simple-base-string (sam-alignment-cigar aln2))) 'cigar)
      (when (string/= (the simple-base-string (sam-alignment-rnext aln1)) (the simple-base-string (sam-alignment-rnext aln2))) 'rnext)
      (when (string/= (the simple-base-string (sam-alignment-qual aln1)) (the simple-base-string (sam-alignment-qual aln2))) 'qual)))

(defun sam-alignment-same (aln1 aln2)
  (declare (sam-alignment aln1 aln2) #.*optimization*)
  (and (string= (the simple-base-string (sam-alignment-qname aln1)) (the simple-base-string (sam-alignment-qname aln2)))
       (= (the fixnum (sam-alignment-flag aln1)) (the fixnum (sam-alignment-flag aln2)))
       (string= (the simple-base-string (sam-alignment-rname aln1)) (the simple-base-string (sam-alignment-rname aln2)))
       (= (the int32 (sam-alignment-pos aln1)) (the int32 (sam-alignment-pos aln2)))
       (= (sam-alignment-mapq aln1) (sam-alignment-mapq aln2))
       (string= (the simple-base-string (sam-alignment-cigar aln1)) (the simple-base-string (sam-alignment-cigar aln2)))
       (string= (the simple-base-string (sam-alignment-rnext aln1)) (the simple-base-string (sam-alignment-rnext aln2)))
       (string= (the simple-base-string (sam-alignment-qual aln1)) (the simple-base-string (sam-alignment-qual aln2)))))

(defun real-diffs (alns1 alns2)
  (loop for aln1 in alns1
        unless (find aln1 alns2 :test #'sam-alignment-same)
        collect aln1))

(defun compare-sams (sam1-file sam2-file)
  ; parse both sams to memory, then do a 1 by 1 comparison on the alignments for all obligatory fields
  (let ((sam1 (make-sam))
        (sam2 (make-sam))
        (working-directory (get-working-directory)))
    (run-pipeline (merge-pathnames sam1-file working-directory) sam1)
    (run-pipeline (merge-pathnames sam2-file working-directory) sam2)
    ; sort the sams by qname
    (setf (sam-alignments sam1) (stable-sort (sam-alignments sam1) #'string< :key #'sam-alignment-qname))
    (setf (sam-alignments sam2) (stable-sort (sam-alignments sam2) #'string< :key #'sam-alignment-qname))
    (format t "sam1:~s alns sam2:~s alns ~%" (length (sam-alignments sam1)) (length (sam-alignments sam2)))
    (let ((differences1 nil)
          (differences2 nil))
      (loop for aln1 in (sam-alignments sam1) ; filter diffs
            for aln2 in (sam-alignments sam2)
            do (let ((d (sam-alignment-differ aln1 aln2))) 
                 (when d 
                   (push aln1 differences1) 
                   (push aln2 differences2))))
      (real-diffs differences1 differences2)))) ; sort slightly different order in elprep so get out real diffs

(defun verify-order-kept (sam-file)
  ; assume the input is coordinate sorted; verify if this is still the case
  (format t "verifying order kept ~%")
  (let ((sam (make-sam))
        (working-directory (get-working-directory)))
    (run-pipeline (merge-pathnames sam-file working-directory) sam)
    (let ((pos (sam-alignment-pos (first (sam-alignments sam))))
          (rname (sam-alignment-rname (first (sam-alignments sam))))
          (ctr 1))
      (loop for aln in (rest (sam-alignments sam))
            do (let ((new-pos (sam-alignment-pos aln))
                     (new-rname (sam-alignment-rname aln)))
                 (cond ((and (< new-pos pos) (string= rname new-rname ))
                        (format t "Not sorted: previous pos: ~s,~s current pos: ~s,~s. ~s reads were in the right order. ~%" rname pos new-rname new-pos ctr) 
                        (return nil))
                       (t 
                        (incf ctr)
                        (setf rname new-rname)
                        (setf pos new-pos))))
            finally (return t)))))

(defun count-duplicates (sam-file)
  (let ((sam (make-sam)))  
    (run-pipeline (merge-pathnames sam-file (get-working-directory)) sam)
    (loop for aln in (sam-alignments sam)
          count (sam-alignment-duplicate-p aln))))

; code for splitting up sam files into chromosomes

(defun scan-refids (aln-string)
  ; a function to extract rname and rnext, the aln's chrom and the mate's chrom, from the aln-string
  (with-input-from-string (aln-stream aln-string)
    (let ((entry-nr 0)
          (refid (make-string-output-stream :element-type 'base-char))
          (mate-refid (make-string-output-stream :element-type 'base-char)))
      (do ((c (read-char aln-stream) (read-char aln-stream nil)))
          ((or (not (characterp c)) (> entry-nr 6))
           (multiple-value-prog1
               (values (get-output-stream-string refid)
                       (get-output-stream-string mate-refid))
             (close refid)
             (close mate-refid)))
        (cond ((char= c #\Tab) (incf entry-nr))
              ((= entry-nr 2) (write-char c refid))
              ((= entry-nr 6) (write-char c mate-refid)))))))

(defun split-file-per-chromosome (input &aux (input-prefix (subseq input 0 (- (length input) 4))))
  (with-open-sam (in input :direction :input)
    (let ((header (parse-sam-header in))
          (reference-sequence-table (make-single-thread-hash-table :test #'equal))
          (chroms-encountered (make-single-thread-hash-table :test #'equal))
          (ctr -1))
      ; fill in a file for unmapped reads
      (setf (gethash "*" chroms-encountered)
            (let ((file (open-sam (format nil "~a-unmapped.sam" input-prefix) :direction :output)))
              (format-sam-header (sam-stream file) header) ; fill in the header
              file))
      (loop for sn-form in (sam-header-sq header)
            do (setf (gethash (getf sn-form :SN) reference-sequence-table) (incf ctr)))
      (loop while (ascii-stream-listen in) do
            (let ((aln-string (ascii-stream-read-line in)))
              (multiple-value-bind (rname rnext)
                  (scan-refids aln-string)
                (let* ((refid (gethash rname reference-sequence-table -1))
                       (mate-refid (gethash rnext reference-sequence-table -1))
                       (max-chrom (if (and (> mate-refid -1) (> mate-refid refid)) rnext rname))
                       (file (or (gethash max-chrom chroms-encountered)
                                 (setf (gethash max-chrom chroms-encountered)
                                       (let ((file (open-sam (format nil "~a-~a.sam" input-prefix max-chrom) :direction :output)))
                                         (format-sam-header (sam-stream file) header)
                                         file)))))
                  (write-line aln-string (sam-stream file))))))
      (loop for file being each hash-value of chroms-encountered do (close-sam file)))))
