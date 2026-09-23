"""Run a script as __main__ and deliver SIGTERM to it once a trigger file appears.

Windows has no way to signal a native console-less process from outside: Git Bash's
`kill -TERM` is TerminateProcess, which runs no handler (measured on the CI runner), and
CTRL_BREAK_EVENT needs a console the runner does not have. raise_signal is the one
delivery that reaches the handler the product installs, so the Windows leg still tests
the handler and its taskkill /T branch instead of skipping them.

usage: sig_driver.py <trigger-file> <script.py> [args...]
"""
import os
import runpy
import signal
import sys
import threading
import time

trigger, script = sys.argv[1], sys.argv[2]


def fire():
    while not os.path.exists(trigger):
        time.sleep(0.05)
    signal.raise_signal(signal.SIGTERM)


threading.Thread(target=fire, daemon=True).start()
sys.argv = sys.argv[2:]
runpy.run_path(script, run_name="__main__")
