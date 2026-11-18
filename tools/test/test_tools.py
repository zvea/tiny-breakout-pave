"""Tests for tools/generate.sh (the renamed files made from Tiny Breakout) and tools/sync.sh (moving
the tiny-breakout submodule to another commit).

Run from the repository root: python3 -m pytest tools/test
With TB_REPO set to a Tiny Breakout clone (and TB_REF, default sky26e), the last test also
generates every part from the real design.
"""

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parents[1]
OLD, NEW = "tt_um_tiny_breakout", "tt_um_tiny_breakout_pave"
OLD_ALONE = re.compile(OLD + r"(?!_pave)")

INFO_YAML = f"""\
# Tiny Tapeout project information
project:
  title:        "Tiny Breakout"      # Project title
  top_module:  "{OLD}"

  # List your project's source files here.
  # Source files must be in ./src and you must list each source file separately, one per line.
  # test/Makefile, CI's lint step, sim/play, tools/ and the FPGA builds
  # (fpga/icebreaker) read this list, as do Tiny Tapeout's own flows.
  source_files:
    - "lfsr.sv"
    - "{OLD}.sv"
"""

UPSTREAM_FILES = {
    "LICENSE": "Apache License\n",
    "info.yaml": INFO_YAML,
    "docs/info.md": "## How it works\n\nA brick-breaker game.\n\n## How to test\n\nPlay.\n",
    "docs/img/gameplay.png": b"\x89PNG\r\n\x1a\n\x00\xff",
    "src/lfsr.sv": "module lfsr; endmodule\n",
    f"src/{OLD}.sv": f"// {OLD}: the top\nmodule {OLD} (input clk);\nendmodule\n",
    "src/config.json": '{"CLOCK_PERIOD": 39.7}\n',
    "test/tb.v": f"module tb; {OLD} user_project (); endmodule\n",
    "test/Makefile": f"# e.g. runs/x/final/pnl/{OLD}.pnl.v\n",
    "sim/play/sim.h": f'#include "V{OLD}.h"\n#include "V{OLD}___024root.h"\n',
    "sim/play/serve.cpp": f"x = g.top.rootp->{OLD}__DOT__autoplay & 1;\n",
    "tools/lec.sh": f'NL="$RUN/final/nl/{OLD}.nl.v"\n',
    "tools/common.sh": "ROOT=.\n",
    "tools/flow.sh": "not generated\n",
    "fpga/README.md": f"{OLD} on an FPGA: not generated\n",
}


def git(cwd, *args):
    return subprocess.run(["git", "-C", str(cwd), "-c", "protocol.file.allow=always", *args],
                          check=True, capture_output=True, text=True).stdout.strip()


def commit_all(repo, message):
    git(repo, "add", "-A")
    git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message)
    return git(repo, "rev-parse", "HEAD")


def write(root, files):
    for rel, text in files.items():
        p = Path(root) / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(text) if isinstance(text, bytes) else p.write_text(text)


def run(script, *args, cwd=None, check=True):
    r = subprocess.run(["bash", str(script), *map(str, args)], capture_output=True, text=True,
                       cwd=cwd)
    if check and r.returncode != 0:
        raise AssertionError(f"{script.name} failed ({r.returncode}):\n{r.stdout}\n{r.stderr}")
    return r


def tree(root):
    """Every file under root (but .git) with its bytes."""
    root = Path(root)
    return {str(p.relative_to(root)): p.read_bytes() for p in sorted(root.rglob("*"))
            if p.is_file() and ".git" not in p.relative_to(root).parts}


@pytest.fixture
def upstream(tmp_path):
    """A small stand-in for Tiny Breakout: a repository with the paths generate.sh reads."""
    repo = tmp_path / "upstream"
    repo.mkdir()
    git(repo, "init", "-q")
    write(repo, UPSTREAM_FILES)
    sha = commit_all(repo, "first")
    git(repo, "branch", "-M", "main")
    git(repo, "tag", "-a", "sky26e", "-m", "sky26e")
    return repo, sha


def generate(src, out, *parts, check=True):
    return run(TOOLS / "generate.sh", "--from", src, out, *parts, check=check)


# generate.sh


def test_renames_the_top_module_everywhere(upstream, tmp_path):
    repo, _ = upstream
    out = tmp_path / "out"
    generate(repo, out, "all")
    assert not (out / f"src/{OLD}.sv").exists()
    assert f"module {NEW} (input clk);" in (out / f"src/{NEW}.sv").read_text()
    assert f'#include "V{NEW}___024root.h"' in (out / "sim/play/sim.h").read_text()
    assert f"rootp->{NEW}__DOT__autoplay" in (out / "sim/play/serve.cpp").read_text()
    assert f'NL="$RUN/final/nl/{NEW}.nl.v"' in (out / "tools/lec.sh").read_text()
    assert f"{NEW} user_project" in (out / "test/tb.v").read_text()
    assert f'    - "{NEW}.sv"' in (out / "info.yaml").read_text()


def test_the_old_name_remains_nowhere(upstream, tmp_path):
    repo, _ = upstream
    out = tmp_path / "out"
    generate(repo, out, "all")
    left = [(rel, line) for rel, data in tree(out).items() if not rel.endswith(".png")
            for line in data.decode().splitlines() if OLD_ALONE.search(line)]
    assert not left, left


def test_changes_the_title_and_top_module(upstream, tmp_path):
    repo, _ = upstream
    out = tmp_path / "out"
    generate(repo, out, "info.yaml")
    info = (out / "info.yaml").read_text()
    assert '  title:        "Tiny Breakout (Paved)"      # Project title\n' in info
    assert f'  top_module:  "{NEW}"\n' in info
    assert sorted(tree(out)) == ["info.yaml"]


def test_drops_tiny_breakouts_own_comment_on_the_source_list(upstream, tmp_path):
    repo, _ = upstream
    out = tmp_path / "out"
    generate(repo, out, "info.yaml")
    info = (out / "info.yaml").read_text()
    assert ("  # List your project's source files here.\n"
            "  # Source files must be in ./src and you must list each source file separately,"
            " one per line.\n  source_files:\n") in info
    assert "fpga" not in info and "sim/play" not in info and "tools/" not in info


def test_adds_the_note_naming_the_source_commit(upstream, tmp_path):
    repo, sha = upstream
    out = tmp_path / "out"
    generate(repo, out, "docs")
    text = (out / "docs/info.md").read_text()
    assert text.startswith(f"## How it works\n\nThis tile is Tiny Breakout (")
    assert f"commit {sha[:7]}" in text
    assert text.count("This tile is Tiny Breakout") == 1
    assert text.endswith("A brick-breaker game.\n\n## How to test\n\nPlay.\n")


def test_generates_only_the_parts_named(upstream, tmp_path):
    repo, _ = upstream
    out = tmp_path / "out"
    generate(repo, out, "test", "LICENSE")
    assert sorted(tree(out)) == ["LICENSE", "test/Makefile", "test/tb.v"]
    generate(repo, out, "all")
    files = set(tree(out))
    assert "tools/flow.sh" not in files and not any(f.startswith("fpga/") for f in files)
    assert (out / "docs/img/gameplay.png").read_bytes() == UPSTREAM_FILES["docs/img/gameplay.png"]
    assert (out / "src/config.json").read_text() == '{"CLOCK_PERIOD": 39.7}\n'


def test_regenerating_replaces_a_part_and_leaves_the_rest(upstream, tmp_path):
    repo, _ = upstream
    out = tmp_path / "out"
    write(out, {"README.md": "mine\n", "tools/sync.sh": "mine\n"})
    generate(repo, out, "all")
    first = tree(out)
    write(out, {"test/stale.py": "left over\n"})
    generate(repo, out, "all")
    assert tree(out) == first
    assert (out / "README.md").read_text() == "mine\n"
    assert (out / "tools/sync.sh").read_text() == "mine\n"


def test_reads_the_commit_not_the_working_files(upstream, tmp_path):
    repo, _ = upstream
    write(repo, {"test/untracked.py": "not committed\n", "test/tb.v": "edited\n"})
    out = tmp_path / "out"
    generate(repo, out, "test")
    assert sorted(tree(out)) == ["test/Makefile", "test/tb.v"]
    assert f"{NEW} user_project" in (out / "test/tb.v").read_text()


@pytest.mark.parametrize("path,text,message", [
    ("info.yaml", INFO_YAML.replace("  title:", "  name:"), "title"),
    ("docs/info.md", "# Overview\n\nA game.\n", "How it works"),
    ("info.yaml", INFO_YAML.replace(f'"{OLD}"', '"tt_um_other"'), "top_module"),
    ("test/tb.v", f"module tb; {NEW} p (); endmodule\n", NEW),
    ("test/tb.v", "module tb; // caf\u00e9\nendmodule\n", "ASCII"),
])
def test_fails_when_the_source_does_not_fit(upstream, tmp_path, path, text, message):
    repo, _ = upstream
    write(repo, {path: text})
    commit_all(repo, "changed")
    r = generate(repo, tmp_path / "out", "all", check=False)
    assert r.returncode != 0 and message in r.stderr, r.stderr


def test_fails_when_a_path_is_missing(upstream, tmp_path):
    repo, _ = upstream
    shutil.rmtree(repo / "sim")
    commit_all(repo, "no sim")
    r = generate(repo, tmp_path / "out", "all", check=False)
    assert r.returncode != 0 and "sim" in r.stderr


def test_refuses_an_unknown_part(upstream, tmp_path):
    repo, _ = upstream
    r = generate(repo, tmp_path / "out", "fpga", check=False)
    assert r.returncode != 0 and "fpga" in r.stderr


# sync.sh


@pytest.fixture
def thin(upstream, tmp_path):
    """A repository like this one: the tools, and the upstream as the tiny-breakout submodule at its
    first commit, with info.yaml generated and a hardened layout in layout/."""
    repo, sha = upstream
    thin = tmp_path / "thin"
    (thin / "tools").mkdir(parents=True)
    for name in ("generate.sh", "sync.sh"):
        shutil.copy(TOOLS / name, thin / "tools" / name)
    git(thin, "init", "-q")
    git(thin, "submodule", "add", "-q", str(repo), "tiny-breakout")
    generate(thin / "tiny-breakout", thin, "info.yaml", "LICENSE")
    write(thin, {f"layout/{NEW}.gds": b"layout", f"layout/{NEW}.lef": "lef",
                 f"layout/{NEW}.pnl.v": "netlist", "layout/README.txt": "provenance\n"})
    commit_all(thin, "first")
    return thin, repo, sha


def sync(thin, ref, check=True):
    return run(thin / "tools/sync.sh", ref, cwd=thin, check=check)


def pinned(thin):
    return git(thin, "ls-files", "-s", "tiny-breakout").split()[1]


def test_sync_moves_the_submodule_and_regenerates_info_yaml_and_licence(thin):
    thin, repo, _ = thin
    write(repo, {"info.yaml": INFO_YAML.replace('"lfsr.sv"', '"score.sv"'),
                 "LICENSE": "Apache License, 2\n"})
    sha2 = commit_all(repo, "second")
    git(repo, "tag", "-a", "v2", "-m", "v2")
    sync(thin, "v2")
    assert pinned(thin) == sha2
    info = (thin / "info.yaml").read_text()
    assert '"score.sv"' in info and f'"{NEW}.sv"' in info and "(Paved)" in info
    staged = git(thin, "diff", "--cached", "--name-only").split()
    assert {"LICENSE", "info.yaml", "tiny-breakout"} <= set(staged)
    assert (thin / "LICENSE").read_text() == "Apache License, 2\n"
    assert git(thin, "diff", "--name-only") == ""  # everything it changed is staged


def test_sync_to_a_new_commit_drops_the_stale_layout(thin):
    thin, repo, _ = thin
    write(repo, {"src/lfsr.sv": "module lfsr2; endmodule\n"})
    commit_all(repo, "second")
    sync(thin, "main")  # the upstream's branch
    assert not list((thin / "layout").glob(f"{NEW}.*"))
    assert not (thin / "layout/README.txt").exists()
    assert git(thin, "diff", "--name-only") == ""  # the removals are staged too


def test_sync_to_the_pinned_commit_changes_nothing(thin):
    thin, _, sha = thin
    before = tree(thin)
    sync(thin, "sky26e")
    assert pinned(thin) == sha
    assert tree(thin) == before
    assert git(thin, "status", "--porcelain") == ""


def test_sync_refuses_a_dirty_tree(thin):
    thin, _, sha = thin
    write(thin, {"layout/README.txt": "edited\n"})
    r = sync(thin, "main", check=False)
    assert r.returncode != 0 and "uncommitted" in r.stderr
    assert pinned(thin) == sha and (thin / f"layout/{NEW}.gds").exists()


def test_sync_refuses_an_unknown_ref(thin):
    thin, _, sha = thin
    r = sync(thin, "no-such-ref", check=False)
    assert r.returncode != 0 and "no-such-ref" in r.stderr
    assert pinned(thin) == sha


@pytest.mark.skipif("TB_REPO" not in os.environ, reason="set TB_REPO to a Tiny Breakout clone")
def test_the_real_design(tmp_path):
    src = tmp_path / "tb"
    subprocess.run(["git", "clone", "-q", "--no-checkout", os.environ["TB_REPO"], str(src)],
                   check=True)
    git(src, "checkout", "-q", "--detach", os.environ.get("TB_REF", "sky26e"))
    out = tmp_path / "out"
    generate(src, out, "all")
    files = tree(out)
    for rel, data in files.items():
        if rel.endswith(".png"):
            continue
        for line in data.decode("ascii").splitlines():
            assert not OLD_ALONE.search(line), (rel, line)
    assert f"module {NEW} (" in files[f"src/{NEW}.sv"].decode()
    assert '"Tiny Breakout (Paved)"' in files["info.yaml"].decode()
