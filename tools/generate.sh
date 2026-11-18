#!/bin/bash
# Usage: tools/generate.sh [--from TB_DIR] OUT_DIR PART...
# Writes into OUT_DIR the named parts of Tiny Breakout, as committed at TB_DIR's HEAD (default:
# the tiny-breakout submodule), with its top module renamed tt_um_tiny_breakout_pave:
#   info.yaml  the project's information, titled "... (Paved)", without Tiny Breakout's own
#              comment on the source list (it names Tiny Breakout's tests, tools, FPGA builds)
#   LICENSE    the licence
#   docs       docs/, with a note at the top of info.md saying what this tile is
#   src        the RTL and its LibreLane configuration
#   test       the tests
#   sim        the interactive player, which the system tests build
#   lec        tools/lec.sh and tools/common.sh, the equivalence check
#   all        all of these
# Each part replaces what OUT_DIR held at its paths; nothing else in OUT_DIR changes. It fails,
# writing nothing, if Tiny Breakout no longer fits the transform: a path missing, no title line,
# a top module of another name, a file that is not ASCII or already names the new top module.
# Runs locally (tools/sync.sh, tools/harden.sh) and in CI, before Tiny Tapeout's actions.
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TB=$ROOT/tiny-breakout
if [ "${1:-}" = --from ]; then TB=${2:?usage: generate.sh [--from TB_DIR] OUT_DIR PART...}; shift 2; fi
[ $# -ge 2 ] || { sed -n '2,17p' "$0" >&2; exit 2; }
exec python3 -I - "$TB" "$@" <<'PY'
import io, os, re, shutil, subprocess, sys, tarfile

tb, out, parts = sys.argv[1], sys.argv[2], sys.argv[3:]
OLD, NEW = "tt_um_tiny_breakout", "tt_um_tiny_breakout_pave"
PARTS = {"info.yaml": ["info.yaml"], "LICENSE": ["LICENSE"], "docs": ["docs"], "src": ["src"],
         "test": ["test"], "sim": ["sim"], "lec": ["tools/lec.sh", "tools/common.sh"]}
NOTE = """\
This tile is Tiny Breakout (https://github.com/zvea/tiny-breakout, commit {commit}), laid out
with an experimental place-and-route engine.

"""
HEADING = "## How it works\n\n"
# The comments on source_files in Tiny Tapeout's template
TEMPLATE_COMMENTS = {
    "# List your project's source files here.",
    "# Source files must be in ./src and you must list each source file separately, one per line.",
}


def drop_own_comments(text):
    """info.yaml with the comment lines just above source_files dropped, but for Tiny Tapeout's
    template's own: Tiny Breakout's describe its repository (its tests, tools, FPGA builds)."""
    lines = text.split("\n")
    i = next((n for n, l in enumerate(lines) if re.match(r"\s*source_files:", l)), None)
    if i is None:
        fail("info.yaml has no source_files")
    j = i
    while j > 0 and lines[j - 1].lstrip().startswith("#"):
        j -= 1
    kept = [l for l in lines[j:i] if l.strip() in TEMPLATE_COMMENTS]
    return "\n".join(lines[:j] + kept + lines[i:])


def fail(message):
    sys.exit(f"generate.sh: {message}")


def git(*args, **kw):
    return subprocess.run(["git", "-C", tb, *args], capture_output=True, **kw)


names = []
for part in parts:
    if part == "all":
        names += PARTS
    elif part in PARTS:
        names.append(part)
    else:
        fail(f"unknown part {part!r}; the parts are {', '.join(PARTS)} and all")
paths = list(dict.fromkeys(p for n in names for p in PARTS[n]))

r = git("rev-parse", "--verify", "HEAD^{commit}", text=True)
if r.returncode:
    fail(f"{tb} is not a git checkout: {r.stderr.strip()}")
commit = r.stdout.strip()
for p in paths:
    if git("cat-file", "-e", f"HEAD:{p}").returncode:
        fail(f"Tiny Breakout {commit[:7]} has no {p}")

r = git("archive", "--format=tar", "HEAD", "--", *paths)
if r.returncode:
    fail(f"git archive failed: {r.stderr.decode().strip()}")

files = {}  # path in OUT_DIR -> (bytes, mode)
with tarfile.open(fileobj=io.BytesIO(r.stdout)) as tar:
    for m in tar.getmembers():
        if not m.isfile():
            continue
        data = tar.extractfile(m).read()
        path = m.name.replace(OLD, NEW)
        if b"\0" not in data:  # text
            try:
                text = data.decode("ascii")
            except UnicodeDecodeError:
                fail(f"{m.name} is not ASCII")
            if NEW in text:
                fail(f"{m.name} already names {NEW}")
            text = text.replace(OLD, NEW)
            if m.name == "info.yaml":
                text, n = re.subn(r'^(\s*title:\s*"[^"\n]*)(")', r"\1 (Paved)\2", text, flags=re.M)
                if n != 1:
                    fail(f"info.yaml has {n} title lines, not 1")
                if not re.search(rf'^\s*top_module:\s*"{NEW}"', text, flags=re.M):
                    fail(f"info.yaml's top_module is not {OLD}")
                text = drop_own_comments(text)
            if m.name == "docs/info.md":
                if not text.startswith(HEADING):
                    fail("docs/info.md does not start with '## How it works'")
                text = HEADING + NOTE.format(commit=commit[:7], old=OLD) + text[len(HEADING):]
            data = text.encode("ascii")
        files[path] = (data, m.mode)

for p in paths:  # each part replaces what was there
    target = os.path.join(out, p.replace(OLD, NEW))
    if os.path.isdir(target) and not os.path.islink(target):
        shutil.rmtree(target)
    elif os.path.lexists(target):
        os.remove(target)
for path, (data, mode) in sorted(files.items()):
    target = os.path.join(out, path)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "wb") as f:
        f.write(data)
    os.chmod(target, mode & 0o777)
print(f"generate.sh: {', '.join(dict.fromkeys(names))} from Tiny Breakout {commit[:7]} into {out}")
PY
