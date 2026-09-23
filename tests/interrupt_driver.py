"""Drive a product script under a fault injection for the interrupt tests.

Usage: interrupt_driver.py <mode> <fired-file> <script.py> [args...]

Loads <script.py> under a non-"__main__" name (so its __main__ guard does not
run), patches its module-level `core` (both muse_task.py and muse_fleet.py have
one) according to <mode>, then runs mod.main(). main() installs the real signal
handlers, so signal.raise_signal(signal.SIGTERM) below reaches the product's
handler on Linux, macOS AND Windows -- tests/sig_driver.py relies on the same.

Every injection touches <fired-file> at the moment it fires, so the shell test
can prove the injection -- not just the wrapper -- ran.

Modes:
  window    call the real core.run_muse, then return a dict that raises SIGTERM
            on the first access of any kind. This lands the signal after
            run_muse has returned and before do_round records anything.
  harvest   raise SIGTERM from core.harvest before delegating.
  spawnerr  pass the real core.run_muse an on_spawn that calls the original,
            then raises OSError (a post-spawn ordinary error).
  lsfiles   make subprocess.run raise TimeoutExpired for the `git ls-files
            --cached --others` listing only. A real 30s delay is too slow for
            CI, and a stub `git` is not found by native Windows CreateProcess.
"""
import importlib.util
import signal
import subprocess
import sys


def touch(path):
    import os
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8"):
        pass


def main():
    mode, fired, script = sys.argv[1], sys.argv[2], sys.argv[3]
    rest = sys.argv[4:]

    spec = importlib.util.spec_from_file_location("interrupt_target", script)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    core = mod.core

    if mode == "window":
        real = core.run_muse

        class Boom(dict):
            """The real result, except the first touch delivers SIGTERM."""

            def _fire(self):
                if getattr(self, "_armed", True):
                    self._armed = False
                    touch(fired)
                    signal.raise_signal(signal.SIGTERM)

            def __getitem__(self, key):
                self._fire()
                return super().__getitem__(key)

            def get(self, *args, **kwargs):
                self._fire()
                return super().get(*args, **kwargs)

            def __contains__(self, key):
                self._fire()
                return super().__contains__(key)

            def __iter__(self):
                self._fire()
                return super().__iter__()

            def keys(self):
                self._fire()
                return super().keys()

            def items(self):
                self._fire()
                return super().items()

            def values(self):
                self._fire()
                return super().values()

            def copy(self):
                self._fire()
                return Boom(super().copy())

        def fake_run_muse(*args, **kwargs):
            return Boom(real(*args, **kwargs))

        core.run_muse = fake_run_muse
    elif mode == "harvest":
        real = core.harvest

        def fake_harvest(*args, **kwargs):
            touch(fired)
            signal.raise_signal(signal.SIGTERM)
            return real(*args, **kwargs)

        core.harvest = fake_harvest
    elif mode == "spawnerr":
        real = core.run_muse

        def fake_run_muse(*args, **kwargs):
            if "on_spawn" in kwargs:
                original = kwargs["on_spawn"]

                def boom_on_spawn(p):
                    if original is not None:
                        original(p)
                    touch(fired)
                    raise OSError("injected after spawn")

                kwargs["on_spawn"] = boom_on_spawn
            else:
                args = list(args)
                while len(args) < 7:
                    args.append(None)
                original = args[6]

                def boom_on_spawn(p):
                    if original is not None:
                        original(p)
                    touch(fired)
                    raise OSError("injected after spawn")

                args[6] = boom_on_spawn
            return real(*args, **kwargs)

        core.run_muse = fake_run_muse
    elif mode == "lsfiles":
        real = subprocess.run

        def fake_run(argv, *args, **kwargs):
            if (isinstance(argv, list) and "ls-files" in argv
                    and "--cached" in argv and "--others" in argv):
                touch(fired)
                raise subprocess.TimeoutExpired(argv, kwargs.get("timeout"))
            return real(argv, *args, **kwargs)

        # Patched on the subprocess module itself, which is what core sees.
        subprocess.run = fake_run
    else:
        sys.stderr.write("unknown mode: %s\n" % mode)
        return 2

    sys.argv = [script] + rest
    sys.exit(mod.main())


if __name__ == "__main__":
    main()
