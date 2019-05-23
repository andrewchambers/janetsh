(import sh)

(def- env-grammar  
  (quote 
    {
      :varstart (choice (range "az") (range "AZ") "_")
      :vartail (any (choice :varstart (range "09")))
      :varname (sequence :varstart :vartail)
      :value (some (sequence (not "\n") 1))
      :assignment
        (sequence 
          (capture :varname) "=" (capture :value))
      :junk (some (sequence (not "\n") 1))
      :line (sequence (choice :assignment :junk) (? "\n"))
      :main (some :line)
    }))

(def- env-parser
  (peg/compile env-grammar))

(defn parse-env
  [s]
  (peg/match env-parser s))

(defn- needs-escape?
  [b]
  # This needs improvement.
  (= b 34))

(defn- escape
  [path]
  (def buf @"")
  (each b path
    (when (needs-escape? b)
      (buffer/push-byte buf 92))
    (buffer/push-byte buf b))
  (string buf))

(defn load-env
  [path]
  (def envstr
    (sh/$$ "/bin/sh" "--norc" "-c" 
      (string ". \"" (escape path) "\" && env") :2> /dev/null ))
  (partition 2 (parse-env envstr)))

(defn source-env
  [path &opt whitelist blacklist]
  (var envvars (load-env path))
  (each [k v] envvars
      (when (and
              (or (not whitelist) (whitelist k))
              (or (not blacklist) (not (blacklist k))))
      (os/setenv k v))))

