# shellcheck shell=bash
# win_cmd_shim <stub>: native Windows python finds only PATHEXT files (shutil.which) and
# CreateProcess cannot run an extensionless bash script, so without <stub>.cmd a test's
# stub is invisible and some other muse on PATH answers instead. A no-op elsewhere.
win_cmd_shim() {
  command -v cygpath >/dev/null 2>&1 || return 0
  printf '@echo off\r\n"%s" "%s" %%*\r\nexit /b %%ERRORLEVEL%%\r\n' \
    "$(cygpath -m "$(command -v bash)")" "$(cygpath -m "$1")" > "$1.cmd"
}
# is_windows: Git Bash driving a native python, where POSIX signals cannot reach it.
is_windows() { command -v cygpath >/dev/null 2>&1; }
