; gloc - grouped lines of code.
;
; Counts non-blank, non-comment lines by file extension.
; Comment lines start with ;, //, --, or # after trimming.
;
; Usage:
;
;   eld examples/gloc.eld [path]

(import "fs")
(import "os")
(import "path")
(import "str")


; The stats map is mutated, but the binding itself is stable.
(const
  stats    {}
  args     (os/args)
  arg-root (if (> (len args) 0) (idx args 0) nil)
  root     (path/clean (?? arg-root (os/env "GLOC_PATH") ".")))

(def
  total-files 0
  total-lines 0)


(const (ignored-dir? name)
  (or (= name ".git")
      (= name "_work")
      (= name "_bench")))

(const (ignored-file? file)
  (const
    name (path/base file)
    ext  (path/ext file))

  (or (= name ".gitignore")
      (= name ".gitattributes")
      (= ext ".zip")
      (= ext ".md")
      (= ext ".exe")))

(const (comment-line? line)
  (const trimmed (str/trim line))

  (or (= trimmed "")
      (str/prefix? trimmed ";")
      (str/prefix? trimmed "//")
      (str/prefix? trimmed "--")
      (str/prefix? trimmed "#")))

(const (file-ext file)
  (const ext (path/ext file))

  (if (= ext "")
    "(none)"
    ext))

(const (count-text text)
  (const lines (str/split text "\n"))
  (def
    i     0
    count 0)

  (while (< i (len lines))
    (if (not (comment-line? (idx lines i)))
      (set count (+ count 1)))

    (set i (+ i 1)))

  count)

(const (record-file file line-count)
  (const
    ext   (file-ext file)
    entry (?? (key stats ext)
              (do
                (set (key stats ext) {:files 0 :lines 0})
                (key stats ext))))

  (set (key entry :files) (+ (key entry :files) 1))
  (set (key entry :lines) (+ (key entry :lines) line-count))

  (set total-files (+ total-files 1))
  (set total-lines (+ total-lines line-count)))

(const (count-file file)
  (cond
    (ignored-file? file)
      nil

    :else
      (do
        (const [text err] (fs/read-file file))

        (if err
          nil
          (record-file file (count-text text))))))


(const (pad-left value width)
  (def text (str value))

  (while (< (len text) width)
    (set text (str " " text)))

  text)

(const (pad-right value width)
  (def text (str value))

  (while (< (len text) width)
    (set text (str text " ")))

  text)


(const (walk dir)
  (const [names err] (fs/list-dir dir))

  (cond
    err
      (print "skip:" dir err)

    :else
      (do
        (def i 0)

        (while (< i (len names))
          (const
            name (idx names i)
            full (path/join dir name))

          (cond
            (fs/dir? full)
              (if (not (ignored-dir? name))
                (walk full))

            (fs/file? full)
              (count-file full))

          (set i (+ i 1))))))

(const (print-stats)
  (print "gloc:" root)

  (const exts (keys stats))
  (def
    files-width (len "files")
    ext-width   (len "ext")
    lines-width (len "lines"))

  (def i 0)
  (while (< i (len exts))
    (const
      ext        (idx exts i)
      entry      (key stats ext)
      files-text (str (key entry :files))
      lines-text (str (key entry :lines)))

    (if (> (len files-text) files-width)
      (set files-width (len files-text)))

    (if (> (len ext) ext-width)
      (set ext-width (len ext)))

    (if (> (len lines-text) lines-width)
      (set lines-width (len lines-text)))

    (set i (+ i 1)))

  (write
    (pad-left "files" files-width) "  "
    (pad-right "ext" ext-width) "  "
    (pad-left "lines" lines-width) "\n")

  (set i 0)

  (while (< i (len exts))
    (const
      ext   (idx exts i)
      entry (key stats ext))

    (write
      (pad-left (key entry :files) files-width) "  "
      (pad-right ext ext-width) "  "
      (pad-left (key entry :lines) lines-width) "\n")

    (set i (+ i 1)))

  (print)
  (print "total" total-files "files" total-lines "lines"))


(cond
  (fs/dir? root)
    (walk root)

  (fs/file? root)
    (count-file root)

  :else
    (do
      (print "path not found:" root)
      (os/exit 1)))

(print-stats)
