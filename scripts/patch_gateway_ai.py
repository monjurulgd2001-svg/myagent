#!/usr/bin/env python3
"""patch_gateway_ai.py - make the /ai slash command work in Telegram.

The Hermes chat gateway intercepts every message starting with "/" and
replies "Unknown command" for anything not in its own registry, so /ai
never reaches the agent. This patcher runs at deploy time, AFTER the
hermes-agent install and BEFORE the gateway starts:

  1. finds the gateway source file that contains the unknown-command
     reply ("Unknown command" string),
  2. locates where the incoming message text is read in that file,
  3. injects a tiny rewrite right after it:
         "/ai ..."  ->  "ai ..."
     so the gateway treats it as a REGULAR message and hands it to the
     agent, whose AGENTS.md hard rule then runs the `ai` CLI.

Safe by design: idempotent (marker guard), compile-checks the patched
file and restores the backup on any error, and if no known pattern
matches it changes NOTHING and exits 0 (the no-slash `ai` command keeps
working either way).
"""
import os
import re
import sys
import py_compile

MARK = "# hermes-ai-slash-patch"
HOME = os.path.expanduser("~")
ROOTS = [
    os.path.join(HOME, ".hermes", "hermes-agent"),
]

# the rewrite injected after the "text = ..." assignment. {i} = indent,
# {v} = the text variable name found in the gateway source.
SNIPPET = (
    "{i}{mark}: '/ai ...' -> 'ai ...' so it reaches the agent as a\n"
    "{i}# regular message instead of dying as an unknown slash command\n"
    "{i}if isinstance({v}, str) and ({v} == '/ai' or {v}.startswith('/ai ') or {v}.startswith('/ai@')):\n"
    "{i}    {v} = {v}.split(' ', 1)[0].split('@', 1)[0][1:] + ({v}.partition(' ')[1] + {v}.partition(' ')[2])\n"
)

TEXT_ASSIGN = re.compile(
    r"^(?P<indent>[ \t]+)(?P<var>[A-Za-z_]\w*)\s*=\s*"
    r"(?P<rhs>.*(?:\.get\(\s*[\"']text[\"']|\[[\"']text[\"']\]|\.text\b).*)$"
)


def find_gateway_files():
    hits = []
    for root in ROOTS:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames
                           if d not in (".git", "node_modules", "__pycache__")]
            for fn in filenames:
                if not fn.endswith(".py"):
                    continue
                p = os.path.join(dirpath, fn)
                try:
                    src = open(p, encoding="utf-8", errors="ignore").read()
                except Exception:
                    continue
                if "unknown command" in src.lower() and "/" in src:
                    hits.append((p, src))
    return hits


def patch(path, src):
    if MARK in src:
        print("already patched: " + path)
        return True
    lines = src.splitlines(True)
    for idx, line in enumerate(lines):
        m = TEXT_ASSIGN.match(line.rstrip("\n"))
        if not m:
            continue
        indent, var = m.group("indent"), m.group("var")
        inj = SNIPPET.format(i=indent, v=var, mark=MARK)
        new_src = "".join(lines[: idx + 1]) + inj + "".join(lines[idx + 1:])
        bak = path + ".ai-patch.bak"
        open(bak, "w", encoding="utf-8").write(src)
        open(path, "w", encoding="utf-8").write(new_src)
        try:
            py_compile.compile(path, doraise=True)
        except Exception as e:
            open(path, "w", encoding="utf-8").write(src)  # restore
            print("patch reverted (compile failed): %s: %s" % (path, e))
            return False
        print("patched /ai passthrough: %s (var '%s', line %d)"
              % (path, var, idx + 1))
        return True
    print("no text-assignment pattern in " + path + " - left untouched")
    return False


def main():
    files = find_gateway_files()
    if not files:
        print("gateway unknown-command handler not found - nothing patched "
              "(no-slash `ai` command still works)")
        return 0
    ok = any(patch(p, s) for p, s in files)
    if not ok:
        print("WARNING: could not enable /ai passthrough - use `ai` "
              "without the slash (works the same)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
