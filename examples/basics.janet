# Janetsh scripts are janet programs that use the janetsh
# support functions and runtime.
#
# We can run this script with 'janetsh ./basics.janet'

# At it's core, to learn janetsh, you should learn the janet
# programming language. janetsh is strictly a library for
# the janet programming language, though as a user this is
# not necessarily something you need to care about.

# Here we import the sh functions so we can call them.
# Note that in the interactive repl, this is automatic.
(import sh)

# Here we define a janet function that uses a subprocess to say hello
# to a name specified as a function argument.
#
# sh/$ is a janet macro that parses shell syntax converts it into
# janet commands for managing external external shell command jobs.
#
# inside the sh/$ macro, things enclosed in parens escape to lisp mode.
# Here we use the identity function pass the variable name to the external program.
# It seems complicated for now, but remember, inside sh/$ is command mode.
# inside nested parens is janet mode.
(defn hello
  [name]
  (sh/$ echo hello (identity name)))

# This will call our function which will invode the external command:
# "echo hello"
#
# This example is contrived, but the easy passage of janet values
# to external commands is what gives janetsh so much power.
(hello "Andrew")

# The sh/$ macro by throws an error if the command fails.
(try
  (sh/$ false)
([e] (print "this error was on purpose.")))

# Janet supports some of the same command redirects as sh and bash.
(sh/$ echo hello > /dev/null)
# Note that this next redirect requires a colon prefix because janet symbols
# cannot begin with a number.
(sh/$ echo hello > /dev/null :2>&1)

# The sh/$$ macro captures the output of a command into a 
# janet string variable. If the command fails an exception is thrown.
(var files (sh/$$ ls /))
(print files)

# The sh/$? macro returns the external command's exit code.
# We can build complex control flow easily using this construct.
(when (not= 0 (sh/$? true))
  (error "this shouldn't happen"))

# Now let's look at background jobs.
# 
# Like regular shell, & creates a background job.
# unlike regular shell, it returns a job table.
(var sleep-job (sh/$ sleep 3 &))

# We can pretty print this job to see what it contains.
(pp sleep-job)

# With janet tables, it is simple to extract values.
# Simply call them with a key.
(print "our job has process group " (sleep-job :pgid))

# We can terminate the job if we don't want it anymore.
# using a support function from the sh library.
(sh/terminate-job sleep-job)

# Or we could have waited for it to complete normally.
# (sh/wait-for-job sleep-job)

# After the job exited, we can get the return code.
(print "out sleep job exited with exit code: " (sh/job-exit-code sleep-job))

# That's it for now.
# Remember - janetsh is normal janet, so look to https://janet-lang.org/
# for more information to become a master.
