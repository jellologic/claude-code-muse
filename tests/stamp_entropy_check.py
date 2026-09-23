#!/usr/bin/env python3
"""Both drivers must put entropy in the stamp expression itself.

String matching on ``ast.dump`` passes on a docstring -- a ``new_stamp`` body
of ``\"\"\"Entropy comes from secrets.token_hex(4).\"\"\"`` followed by a bare
timestamp return would satisfy it while computing collideable stamps. So this
looks for a real ``secrets.token_hex`` CALL inside the expression assigned to
``stamp`` (following one ``new_stamp()`` indirection), never for the name in
text. Takes the plugin root as argv[1]. Python 3.9, stdlib only.
"""

import ast
import os
import sys


def is_entropy_call(n, mod_aliases=None, func_aliases=None):
    """A real secrets.token_hex(...) call, not a string that names one.

    The secrets module may be imported under an alias (``import secrets as
    sx``) and token_hex may be imported into local scope (``from secrets
    import token_hex``); both spellings still call the same function. A bare
    ``token_hex(...)`` with no matching ``from secrets import`` -- e.g. a
    module-level ``def token_hex`` -- is refused, because nothing ties that
    name to the secrets module.
    """
    if mod_aliases is None:
        mod_aliases = frozenset({"secrets"})
    if func_aliases is None:
        func_aliases = frozenset()
    if not isinstance(n, ast.Call):
        return False
    func = n.func
    if (
        isinstance(func, ast.Attribute)
        and func.attr == "token_hex"
        and isinstance(func.value, ast.Name)
        and func.value.id in mod_aliases
    ):
        return True
    return isinstance(func, ast.Name) and func.id in func_aliases


def module_aliases(tree):
    """Names bound to the secrets module: `secrets` plus any `as` alias."""
    found = {"secrets"}
    for n in ast.walk(tree):
        if isinstance(n, ast.Import):
            for a in n.names:
                if a.name == "secrets":
                    found.add(a.asname or "secrets")
    return found


def function_aliases(tree):
    """Local names bound to secrets.token_hex by `from secrets import`."""
    found = set()
    for n in ast.walk(tree):
        if (
            isinstance(n, ast.ImportFrom)
            and n.module == "secrets"
        ):
            for a in n.names:
                if a.name == "token_hex":
                    found.add(a.asname or "token_hex")
    return found


def file_ok(path):
    src = open(path, encoding="utf-8").read()
    tree = ast.parse(src)
    mods = module_aliases(tree)
    funcs = function_aliases(tree)

    def entropy(n):
        return is_entropy_call(n, mods, funcs)

    stamp_values = [
        n.value
        for n in ast.walk(tree)
        if isinstance(n, ast.Assign)
        and any(isinstance(t, ast.Name) and t.id == "stamp" for t in n.targets)
    ]
    if not stamp_values:
        return False
    if any(any(entropy(n) for n in ast.walk(v)) for v in stamp_values):
        return True
    helpers = [
        n
        for n in ast.walk(tree)
        if isinstance(n, ast.FunctionDef) and n.name == "new_stamp"
    ]
    if not helpers:
        return False
    if not any(
        any(isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
            and n.func.id == "new_stamp" for n in ast.walk(v))
        for v in stamp_values
    ):
        return False
    # A docstring is an ast.Constant, never a Call, so walking the body for a
    # call cannot be fooled by prose that names the function.
    return any(any(entropy(n) for n in ast.walk(h)) for h in helpers)


def main(argv):
    root = argv[1]
    problems = []
    for name in ("muse_task.py", "muse_fleet.py"):
        if not file_ok(os.path.join(root, "scripts", name)):
            problems.append(
                "%s: the stamp expression has no entropy, so two runs in the "
                "same second compute the same worktree path" % name
            )
    if problems:
        for p in problems:
            print("        " + p)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
