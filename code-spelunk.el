;;; code-spelunk --- Visualise your code exploration sessions -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'map)
(require 'eieio)
(require 'cl-lib)
(require 'subr-x)
(require 'project)

(defun spelunk-list-of-spelunk-tree-p (x)
  "Produce t if X is a list of `spelunk-tree's."
  (cl-every #'spelunk-tree-p x))

(cl-deftype spelunk-list-of-spelunk-tree ()
  "A list of `spelunk-tree's."
  '(satisfies spelunk-list-of-spelunk-tree-p))

(defclass spelunk-tree ()
  ((node-tag  :initarg :node-tag
              :type symbol)
   (sub-nodes :initarg :sub-nodes
              :type spelunk-list-of-spelunk-tree))
  "A node the tree of code navigation actions taken in a spelunking session.")

(defun spelunk-history-record-p (x)
  "Produce t if X is a cons of two `spelunk-tree's.

The first is the root of the tree and the second is the current
node."
  (and (consp x)
       (spelunk-tree-p (car x))
       (spelunk-tree-p (cdr x))))

(cl-deftype spelunk-history-record ()
  "A tuple of the root of the history tree and a pointer to the current node."
  '(satisfies spelunk-history-record-p))

(defvar spelunk--trees-per-project (make-hash-table :test #'equal)
  "A record of the navigations made per project.")

;; TODO: needs to handle the case that xref didn't find a tag
;; (maybe?).
(defun spelunk--record-navigation-event (&optional identifier)
  "Append the navigation event which just occured to the current node.

The notion of a \"current-node\" exists because we go back up the
tree when you navigate back to where you came from.  This is
similar to how `undo-tree' works and is meant to help you keep
track of where you came from when you go down a deep rabbit hole.

Navigation trees are tracked per-project, so the first step is to
fetch the navigation record for the current project.

If we were navigating to the definition (i.e. using
`xref-find-definitions') then IDENTIFIER is the name of the
symbol which we're heading to.  If we're going back (i.e. using
`xref-pop-marker-stack'), then it'll be null."
  (cl-declare (type (or 'string 'null) identifier))
  (pcase (spelunk--retrieve-navigation-tree)
    (`(,root . ,current-node)
     (spelunk--update-navigation-tree
      (if identifier
          (let ((key       (intern identifier))
                (sub-nodes (oref current-node :sub-nodes)))
            (cl-labels ((find-sub-node (sub-node) (eq (oref sub-node :node-tag) key)))
              (if (some #'find-sub-node sub-nodes)
                  (cons root (find-if #'find-sub-node sub-nodes))
                (let* ((sub-node (make-instance 'spelunk-tree
                                                :node-tag key
                                                :sub-nodes '())))
                  (push sub-node (oref current-node :sub-nodes))
                  (cons root sub-node)))))
        (cons root
              (spelunk--find-by-sub-node-identifier root
                                                    (oref current-node :node-tag))))))))

(defun spelunk-show-history ()
  "Show the history of code navigations in other window.

Window will exist for `spelunk--show-history-duration' before
dissapearing."
  (let ((history-buffer-name (spelunk--history-buffer-name)))
    (with-current-buffer (switch-to-buffer-other-window (get-buffer-create history-buffer-name))
      ;; TODO: Make read only
      (delete-region (point-min) (point-max))
      (insert (spelunk--print-tree ())))))

(defun spelunk--history-buffer-name ()
  "Create a name for the buffer to show the code navigation.

Buffer name is unique per project."
  (let* ((candidate-projects (project-roots (project-current)))
         (existing-tree-key  (thread-last candidate-projects
                               ;; TODO: what if multiple trees match?
                               ;; Do I need to store the mode as well?
                               (car))))
    (format "*spelunk:%s*" existing-tree-key)))

(defun spelunk--start-recording ()
  "Start recording code navigation events on a per-project basis.

See: `spelunk--record-navigation-event'."
  (advice-add #'xref-find-definitions :before #'spelunk--record-navigation-event)
  (advice-add #'xref-pop-marker-stack :before #'spelunk--record-navigation-event))

(defun spelunk--stop-recording ()
  "Remove advice which records code navigation events on a per-project basis."
  (advice-remove #'xref-find-definitions #'spelunk--record-navigation-event)
  (advice-remove #'xref-pop-marker-stack #'spelunk--record-navigation-event))

(cl-defmethod spelunk--find-by-sub-node-identifier ((tree spelunk-tree) identifier)
  "Find the node in TREE which is identified by IDENTIFIER."
  (cl-declare (type 'symbol identifier))
  (or (cl-loop
       for sub-node in (oref tree :sub-nodes)
       when (eq (oref sub-node :node-tag) identifier) return tree)
      (cl-loop
       for sub-node in (oref tree :sub-nodes)
       for found = (spelunk--find-by-sub-node-identifier sub-node identifier)
       when found return found)))

(defvar spelunk--empty-width 4
  "The width of an empty node.

This will disappear when we're not just printing O's.")

(defun spelunk--one-if-zero (x)
  "If X is 0 then 1 else X."
  (if (eq x 0) 1 x))

(cl-defmethod spelunk--print-tree ((tree spelunk-tree) current-node)
  "Print TREE vertically so that the start of your search is at the top.

CURRENT-NODE is printed in *bold* to indicate that it's the
current node."
  (cl-labels
      ((iter (trees)
             (progn
               (dolist (tree trees)
                 (let* ((is-number (numberp tree))
                        (width-of-children (if is-number
                                               tree
                                             (* spelunk--empty-width (spelunk--one-if-zero
                                                                      (apply #'+ (mapcar #'spelunk--max-width
                                                                                         (oref tree :sub-nodes))))))))
                   (cl-loop for i from 0 below width-of-children
                            for is-middle = (eq i (/ width-of-children 2))
                            when (and (not is-number) is-middle) do (insert "O")
                            when (eq current-node tree) do (overlay-put (make-overlay (1- (point)) (point)) 'face 'bold)
                            when (or is-number (not is-middle)) do (insert " "))))
               (insert "\n")
               (let ((next-round (thread-last (mapcar (lambda (sub-node)
                                                        (if (numberp sub-node)
                                                            (list sub-node)
                                                          (oref sub-node :sub-nodes))) trees)
                                   (mapcar (lambda (sub-node) (if (null sub-node)
                                                                  (list spelunk--empty-width)
                                                                sub-node)))
                                   (apply #'append))))
                 (when (and next-round
                            (not (cl-every #'numberp next-round)))
                   (iter next-round))))))
    (insert "\n")
    (iter (list tree))))

(cl-defmethod spelunk--max-width ((tree spelunk-tree))
  "Produce a count of all leaves in TREE.
This is used when printing a tree to determine how much space to
leave for printing children."
  (spelunk--one-if-zero
   (cl-loop
    for sub-node in (oref tree :sub-nodes)
    summing (or (and (null (oref sub-node :sub-nodes)) 1)
                (spelunk--max-width sub-node)))))

(defun spelunk--update-navigation-tree (new-tree)
  "Set the current tree for this project to NEW-TREE."
  (cl-declare (type 'spelunk-history-record new-tree))
  (let ((existing-tree-key  (thread-last (project-roots (project-current))
                              (cl-remove-if-not (apply-partially #'map-contains-key
                                                                 spelunk--trees-per-project))
                              ;; TODO: what if multiple trees match?
                              ;; Do I need to store the mode as well?
                              (car))))
    (setf (gethash existing-tree-key spelunk--trees-per-project) new-tree)))

(defun spelunk--retrieve-navigation-tree ()
  "Find the navigation tree applicable for the current `default-directory'."
  (let* ((candidate-projects (project-roots (project-current)))
         (existing-tree-key  (thread-last candidate-projects
                               (cl-remove-if-not (apply-partially #'map-contains-key
                                                                  spelunk--trees-per-project))
                               ;; TODO: what if multiple trees match?
                               ;; Do I need to store the mode as well?
                               (car))))
    (if existing-tree-key
        (gethash existing-tree-key spelunk--trees-per-project)
      ;; TODO: assuming that it's the first project here.  See
      ;; previous note.
      (setf (map-elt spelunk--trees-per-project (car candidate-projects))
            (let ((tree (make-instance 'spelunk-tree
                                       :node-tag 'root
                                       :sub-nodes '())))
              (cons tree tree))))))



;; Example tree
'(let* ((right-tree (make-instance
                     'spelunk-tree
                     :node-tag 'teehee
                     :sub-nodes (list (make-instance
                                       'spelunk-tree
                                       :node-tag 'test
                                       :sub-nodes (list (make-instance 'spelunk-tree
                                                                       :node-tag 'blerg
                                                                       :sub-nodes '()))))))
        (tree (make-instance
               'spelunk-tree
               :node-tag 'blah
               :sub-nodes (list (make-instance
                                 'spelunk-tree
                                 :node-tag 'blah
                                 :sub-nodes (list (make-instance
                                                   'spelunk-tree
                                                   :node-tag 'haha
                                                   :sub-nodes '())
                                                  (make-instance
                                                   'spelunk-tree
                                                   :node-tag 'hehe
                                                   :sub-nodes '())))
                                right-tree))))
   (spelunk--print-tree tree right-tree))

(provide 'code-spelunk)
;;; code-spelunk ends here
