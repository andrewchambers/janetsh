# Janetsh 

[![Gitter](https://badges.gitter.im/janetsh/community.svg)](https://gitter.im/janetsh/community?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge)

[Website](https://janet-shell.org)

[Mailing list](https://lists.sr.ht/~ach/janetsh)

[CI](https://builds.sr.ht/~ach/janetsh)


A new system shell that uses the [Janet](https://janet-lang.org/) programming language
for high level scripting while also supporting the things we love about sh.

Minimal knowledge of janet is required for basic shell usage,
but know that as you become more familiar with janet, your shell will gain the power of:

- A powerful standard library.
- Functional and imperative programming.
- Powerful lisp macros.
- Runtime loadable extension modules written in C/C++/rust/zig...
- Coroutines and exceptions.
- Much much more.

Help develop janetsh [donate via paypal](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=Y3SWVCXV3PEA6&source=url)

# Status

Janetsh development has slowed and I am not actively working on it for now.
Some of it is no longer compatible with the latest janet release.

That being said, I consider janetsh a successful proof of concept and place to draw
code and ideas from whenever the next attempt at fixing shells gets my attention.

One potential avenue for janetsh2 in the future is to integrate janet syntax
with the shell library:

https://github.com/emersion/mrsh

If we do this, we can have POSIX compatibility when we need it, as well as avoid implementing
most of the complexity in a shell, and can instead focusing on delivering on the important
ideas of janetsh.

# See it in action

[![asciicast](https://asciinema.org/a/248403.svg)](https://asciinema.org/a/248403)

[demo source code](./demos/demos.janet) [demo rc file](https://github.com/andrewchambers/janetsh/blob/master/www/gallery/simple-andrew-chambers.rc)

# Examples

## Basic shell usage

As you would expect:
```
$ ls -la | head -n 3
total 100
drwxr-xr-x 1 ac users   220 May 13 20:16 .
drwxr-xr-x 1 ac users   760 May 12 21:08 ..
0

$ echo foo > /dev/null
0

$ sleep 5 &
@{:pgid 82190 :procs @[@{:args @["sleep" "5"]
      :pid 82190
      :stopped false
      :redirs @[]}]}

$ rm ./demos/*.gif
0
```

## Functional programming

```
$ (map string/ascii-upper ["functional" "programming"])
@["FUNCTIONAL" "PROGRAMMING"]

$ (defn lines [s] (string/split "\n" s))
<function lines>

$ (lines ($$ ls | head -n 3))
@["build.sh" "demos" "janetsh" ""]

$ echo (reduce + 0 [1 2 3])
6
0
```

## Command capture

```
$ (string/ascii-upper ($$ echo command string capture))
"COMMAND STRING CAPTURE\n"

$ ($$_ echo trimmed capture)
"trimmed capture"

$ (if (= 0 ($? touch /tmp/test.txt)) "success")
"success"

$ (if ($?? touch /tmp/test.txt) "shorthand success")
"shorthand success"
```

## Exceptions/Errors

```
$ (try
    (do
      ($ rm foo.txt)
      ($ rm bar.txt)
      ($ rm baz.txt))
    ([err] (print "got an error:" err)))
```

## Mixing janet code and shell commands

```
$ (each f files (sh/$ wc -l [f]))
```

## Subshells

```
$ ls | head -n 3 | (out-lines string/ascii-upper)
BUILD.SH
DEMOS
JANETSH
0
```

# Reference Documentation

Hopefully in the future this sparse reference set will become more polished, but for now
the following snippets may help advanced users play with the shell in it's current state.

## RC files

Janetsh runs a user rc script ```~/.janetsh.rc``` at startup when in interactive mode. This
file can changed or disabled via command line flags.

Janetsh runs ```/etc/janetsh.rc``` on any run if it exists. This file can be changed or disabled via
command line flags.

## Custom prompts

Users can set a custom prompt:
```
(set *get-prompt* (fn [p] "$ "))
```
p is a janet standard library parser, which can be used to find the current repl nesting level.

## Custom line completions

Users can set a custom line completion function:
```
(set *get-completions*
  (fn [line word-start word-end]
    @["your-completion"]))
```

## History file

By default janetsh does not store any history to avoid accidental information leaks.

To enable history add the following line to your janet rc file:

```
(set *hist-file* (first (sh/expand "~/.janetsh.hist")))
```

## Job control

A list of running jobs can be found in the variable sh/jobs, each
of which is a janet table containing the current state of a user job/pipeline.

The sh package has some functions for manipulating jobs, such
as putting them in the foreground, or terminating them. This
is not a stable interface for now, so you will need to read the code yourself
for documentation.

Some examples:

```
vim
...
Ctrl+Z
$ (sh/fg-job (first sh/jobs))
...
Ctrl+Z
$ sleep 60 &
$ (sh/terminate-all-jobs)
$ (sh/disown-job (sh/$ sleep 60 &))
```

# Custom builtin shell commands

Here is an example of defining a new builtin shell command.
```
(defn- make-my-builtin
  []
  @{
    :pre-fork
      (fn pre-fork
        [self args]
        (print "hello from shell process"))
    :post-fork
      (fn post-fork
        [self args]
        (print "hello from child process"))
  })

(put sh/*builtins* "my-builtin" make-my-builtin)
```
It is important to catch any errors and only report them
from the child process. This means builtins can manipulate the
shell internal state, but still behave like regular processes
for the purpose of exit codes, pipes and job control.

# Installation

For the default build you will need pre released janet 1.0.0 built from source, readline and pkg-config installed on your system, then you can run:

```
./configure && make install
```

If you want libedit instead of readline you can build with:

```
./configure --with-pkg-config-libedit
```

If you don't want to depend on readline or libedit, you can use the bundled emulation.

```
./configure --with-readnoise
```

You can also manually specify header paths, install paths and flags.

Try ```./configure --help``` for a list of options.

# Janetsh Internals

Internally janetsh is implemented as a low level C library for the janet programming
language, a janet library and a small launcher that does some necessary setup/teardown.

The janet main implementation is a set of janet functions and macros that perform shell
job control, control user input and manage your command pipelines.

At the highest level the user is presented with an
interactive repl interface which implicitly invokes a janet macro
to give janet the familiar sh syntax. You can escape this implicit
macro by prefixing a line with '(' which reverts to regular janet mode.

Janetsh can also be used for scripting, in which case it acts a small job control runtime and
launcher for janet programs.


# Project Status and Donations

The project is at the proof of concept phase and is only
usable by people brave and willing to fix things for
themselves.

The author would love donations or help from fellow developers to keep things going forward.
Donations will go towards living expenses while developing janetsh and providing upstream support for
the janet programming language issues that affect Janetsh.


This project takes considerable time an effort, please [donate here via paypal](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=Y3SWVCXV3PEA6&source=url) to keep the project alive.

At your request with each donation leave a message and if appropriate, it will be included below.

# Sponsors

You - Your message

# Authors

This project is being built with care by Andrew Chambers.

# Thanks

Special thanks to Calvin Rose for creating the Janet programming language.

Thanks to the authors of [closh](https://github.com/dundalek/closh), [rash](https://rash-lang.org/)
and [xonsh](https://github.com/xonsh/xonsh) for providing inspiration for the project.
