#!/bin/bash
# Usage: tools/harden.sh ENGINE_REPO ENGINE_REV OUT_DIR
# Hardens Tiny Breakout, as the tiny-breakout submodule pins it, with the engine (ENGINE_REPO at ENGINE_REV)
# and checks the result as Tiny Tapeout will, stopping at the first failure:
#    1. the renamed tree (tools/generate.sh) in OUT_DIR/tree, and Tiny Tapeout's LibreLane
#       configuration for it (tt_tool.py --create-user-config, as Tiny Tapeout's GDS action);
#    2. LibreLane's synthesis alone (--to Yosys.Synthesis), into OUT_DIR/ll;
#    3. Pave at PAVE_REV in its own worktree (PAVE_WT, default OUT_DIR/pave), built if needed;
#    4. its rule files and pave harden, into OUT_DIR/harden;
#    5. Pave's full sign-off (signoff/signoff.py, with the equivalence check and the gate-level
#       test, then signoff/drc.py), into OUT_DIR/signoff and OUT_DIR/drc;
#    6. the GDS, LEF and powered netlist copied into layout/;
#    7. Tiny Tapeout's custom_gds action, reproduced into OUT_DIR/artifact, its precheck and its
#       gate-level test on that, and the docs check;
#    8. layout/README.txt, the provenance, every result and the run times (pave harden and the
#       sign-off harness are timed with /usr/bin/time -v, into OUT_DIR/harden.time and
#       OUT_DIR/signoff.time).
# Logs go to OUT_DIR/logs, the commands to OUT_DIR/commands.txt; OUT_DIR must not exist.
# Needs: this repository's .venv (Tiny Breakout's test packages, librelane==3.0.14, yowasp-yosys
# and tt-support-tools' requirements) and .tools/env (Icarus), as tiny-breakout/test/README.md
# sets them up; Docker; the PDK under ~/.ciel; Rust; nix-shell and Python 3.11 (or micromamba)
# for the precheck. Tiny Tapeout's support tools are cloned into tt/ (main) unless there. Heavy
# steps wait for MIN_MEM_GB (default 6) of available memory; everything runs at nice NICE
# (default 10).
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ $# -eq 3 ] || { sed -n '2,25p' "$0" >&2; exit 2; }
PAVE_REPO=$(cd "$1" && pwd); PAVE_REV=$2
case $3 in /*) OUT=$3 ;; *) OUT=$PWD/$3 ;; esac
PAVE_WT=${PAVE_WT:-$OUT/pave}
NICE=${NICE:-10}; MIN_MEM_GB=${MIN_MEM_GB:-6}; JOBS=${JOBS:-4}
TOP=tt_um_tiny_breakout_pave
PDK=sky130A
# The PDK version Tiny Tapeout's precheck action (precheck@ttsky26e) installs
PRECHECK_PDK_VERSION=0536d02d875c8f67dd7cca3902ac457e62f20005
TT_TOOLS_URL=https://github.com/TinyTapeout/tt-support-tools.git
PY=$ROOT/.venv/bin/python

die() { echo "harden.sh: $*" >&2; exit 1; }

# Preconditions: the submodule as pinned, info.yaml generated from it, the environments there
TB_PIN=$(git -C "$ROOT" ls-files -s tiny-breakout | awk '{print $2}')
[ -n "$TB_PIN" ] || die "no tiny-breakout submodule"
[ "$(git -C "$ROOT/tiny-breakout" rev-parse HEAD)" = "$TB_PIN" ] ||
  die "tiny-breakout is not at the commit it is pinned to ($TB_PIN): git submodule update"
[ -z "$(git -C "$ROOT/tiny-breakout" status --porcelain)" ] || die "tiny-breakout has changes"
[ -x "$PY" ] && [ -x "$ROOT/.tools/env/bin/iverilog" ] || die "no .venv or .tools/env (see the README)"
[ ! -e "$OUT" ] || die "$OUT exists"
mkdir -p "$OUT/logs"
"$ROOT/tools/generate.sh" "$OUT/check" info.yaml LICENSE > /dev/null
for f in info.yaml LICENSE; do
  cmp -s "$OUT/check/$f" "$ROOT/$f" || die "$f is not generated from tiny-breakout: run tools/generate.sh . info.yaml LICENSE"
done
rm -r "$OUT/check"

N=0
# step NAME CMD...: runs CMD at nice NICE, its output in logs/NN-NAME.log, and stops on failure
step() {
  local name=$1; shift
  N=$((N + 1)); local log; log=$OUT/logs/$(printf %02d $N)-$name.log
  { printf '# %s %s\n' "$(date -Is)" "$name"; printf '%q ' "$@"; echo; } >> "$OUT/commands.txt"
  echo "$(date -Is) $name: $(printf '%q ' "$@")" > "$log"
  local rc=0
  nice -n "$NICE" "$@" <&0 >> "$log" 2>&1 & local pid=$!  # <&0: a here-document reaches it
  watch_docker $pid &
  local watcher=$!
  wait $pid || rc=$?
  kill $watcher 2>/dev/null || true; wait $watcher 2>/dev/null || true
  echo "$(date -Is) exit=$rc" >> "$log"
  [ $rc -eq 0 ] || die "step $name failed (exit $rc); see $log"
  echo "harden.sh: $name done ($(date +%T))"
}

# watch_docker PID: while PID runs, renices the processes of the Docker containers its process
# tree starts (children of containerd, not of PID) to NICE, so that LibreLane yields too
watch_docker() {
  local root=$1
  while kill -0 "$root" 2>/dev/null; do
    for p in $(ps -eo pid=,ppid= | awk -v r="$root" '{pp[$1]=$2} END {for (x in pp) {y=x; while (y in pp && y!=r && y>1) y=pp[y]; if (y==r) print x}}'); do
      local name
      name=$(tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null | grep -A1 -x -- --name | tail -n +2) || true
      [ -n "$name" ] || continue
      for c in $(docker top "$name" -eo pid,ni 2>/dev/null | awk -v n="$NICE" 'NR>1 && $2<n {print $1}'); do
        renice -n "$NICE" -p "$c" > /dev/null 2>&1 || true
      done
    done
    sleep 5
  done
}

# need_mem: waits (up to an hour) until MIN_MEM_GB of memory is available
need_mem() {
  local i
  for i in $(seq 60); do
    [ "$(awk '/^MemAvailable:/ {print int($2 / 1048576)}' /proc/meminfo)" -ge "$MIN_MEM_GB" ] && return 0
    [ "$i" -eq 1 ] && echo "harden.sh: waiting for ${MIN_MEM_GB} GB of available memory"
    sleep 60
  done
  die "less than ${MIN_MEM_GB} GB of memory available for an hour"
}

# 1. The renamed tree and Tiny Tapeout's configuration
[ -d "$ROOT/tt/.git" ] || step clone-tt-support-tools git clone -q --depth 1 "$TT_TOOLS_URL" "$ROOT/tt"
T=$OUT/tree
step generate "$ROOT/tools/generate.sh" "$T" all
ln -s "$(readlink -f "$ROOT/.venv")" "$T/.venv"
ln -s "$(readlink -f "$ROOT/.tools")" "$T/.tools"
step copy-tt-support-tools git clone -q "$ROOT/tt" "$T/tt"
cd "$T"
step tt-config "$PY" tt/tt_tool.py --create-user-config

# 2. Synthesis
need_mem
mkdir "$OUT/ll"  # LibreLane's --force-run-dir wants it there
step synthesis "$PY" -m librelane --docker-no-tty --docker-mount "$OUT" --dockerized \
  --hide-progress-bar --force-run-dir "$OUT/ll" --to Yosys.Synthesis src/config_merged.json
RUN=$OUT/ll
NETLIST=$(ls "$RUN"/*-yosys-synthesis/"$TOP".nl.v.json)

# 3. Pave
WANT=$(git -C "$PAVE_REPO" rev-parse --verify "$PAVE_REV^{commit}")
[ -e "$PAVE_WT" ] || step pave-worktree git -C "$PAVE_REPO" worktree add --detach "$PAVE_WT" "$WANT"
[ "$(git -C "$PAVE_WT" rev-parse HEAD)" = "$WANT" ] || die "$PAVE_WT is not at $WANT"
[ -z "$(git -C "$PAVE_WT" status --porcelain --untracked-files=no)" ] || die "$PAVE_WT has changes"
# The foundry's tables: the worktree's submodule, or PAVE_REPO's if it is at the commit Pave pins
TABLES=$PAVE_WT/third_party/skywater-pdk/docs/rules
if [ ! -d "$TABLES" ]; then
  [ "$(git -C "$PAVE_REPO/third_party/skywater-pdk" rev-parse HEAD 2>/dev/null)" = \
    "$(git -C "$PAVE_WT" rev-parse HEAD:third_party/skywater-pdk)" ] ||
    die "fetch Pave's third_party/skywater-pdk (in $PAVE_WT or, at the commit it pins, in $PAVE_REPO)"
  TABLES=$PAVE_REPO/third_party/skywater-pdk/docs/rules
fi
PPY=$PAVE_WT/.venv/bin/python
if [ ! -x "$PPY" ]; then
  step pave-venv python3 -m venv "$PAVE_WT/.venv"
  step pave-requirements "$PPY" -m pip install -q -r "$PAVE_WT/signoff/requirements.txt"
fi
need_mem
step pave-build env -C "$PAVE_WT" cargo build --release -j "$JOBS"  # in it: rust-toolchain.toml
BIN=$PAVE_WT/target/release/pave

# 4. Rule files and pave harden
A=$OUT/rules; mkdir -p "$A"
TECH_LEF=$("$PPY" -I -c '
import fnmatch, json, sys
r = json.load(open(sys.argv[1]))
print(next(v for k, v in r["TECH_LEFS"].items() if fnmatch.fnmatchcase(r["DEFAULT_CORNER"], k)))' "$RUN/resolved.json")
DECK=$(jq -r .KLAYOUT_DRC_RUNSET "$RUN/resolved.json")
step antenna-rules "$PPY" "$PAVE_WT/tools/antenna_rules.py" \
  "$TABLES/antenna/table-Ig-antenna-rules-s8p12.csv" "$TECH_LEF" "$A/antenna_rules.txt"
step antenna-cells "$PPY" "$PAVE_WT/tools/antenna_cells.py" "$RUN" "$TABLES/gds_layers.csv" \
  "$A/antenna_cells.txt"
step drc-rules "$PPY" "$PAVE_WT/tools/drc_rules.py" "$TABLES/periphery" "$DECK" \
  "$A/antenna_rules.txt" "$A/drc_rules.txt"
need_mem
step pave-harden /usr/bin/time -v -o "$OUT/harden.time" "$BIN" harden "$RUN" "$NETLIST" "$A/antenna_rules.txt" "$A/antenna_cells.txt" \
  "$A/drc_rules.txt" "$OUT/harden"
[ "$(jq -r .succeeded "$OUT/harden/status.json")" = true ] || die "pave harden: status.json says it did not succeed"

# 5. Sign-off, from the renamed tree, as Pave's README gives it for Tiny Breakout
need_mem
step signoff /usr/bin/time -v -o "$OUT/signoff.time" env PATH="$T/.venv/bin:$T/.tools/env/bin:$PATH" "$PPY" "$PAVE_WT/signoff/signoff.py" \
  "$OUT/harden" "$OUT/signoff" --top "$(jq -r .DESIGN_NAME src/user_config.json)" \
  --config src/config.json --config src/user_config.json \
  --lec 'tools/lec.sh "$SIGNOFF_RUN_DIR"' \
  --gl 'cp "$SIGNOFF_PNL" test/gate_level_netlist.v && cd test && make -B GATES=yes' \
  --gl-results test/results.xml
cp test/results.xml "$OUT/signoff/gl_results.xml"
need_mem
step drc "$PPY" "$PAVE_WT/signoff/drc.py" "$OUT/harden/final/def/$TOP.def" \
  "$OUT/harden/known_bad.json" "$OUT/drc"
# Every check passed (signoff.py's exit status); hold slack also meets the configured margin
step judge "$PPY" -I - "$OUT" "$RUN/resolved.json" <<'PY'
import json, sys
out, resolved = sys.argv[1:]
s = json.load(open(f"{out}/signoff/summary.json"))
assert all(s["results"].values()) and all(s["librelane_parts"].values()), s["results"]
assert json.load(open(f"{out}/drc/summary.json"))["passed"]
margin = json.load(open(resolved))["PL_RESIZER_HOLD_SLACK_MARGIN"]
m = s["metrics"]
hold = {k: v for k, v in m.items() if k.startswith("timing__hold__ws__corner:")}
setup = {k: v for k, v in m.items() if k.startswith("timing__setup__ws__corner:")}
assert len(hold) == len(setup) == 9, (hold, setup)
assert min(setup.values()) >= 0, setup
assert min(hold.values()) >= margin, (margin, hold)
print(f"every check passed; worst setup slack {min(setup.values()):.3f} ns, worst hold slack "
      f"{min(hold.values()):.3f} ns (margin {margin} ns)")
PY

# 6. The layout into layout/
mkdir -p "$ROOT/layout"
F=$OUT/signoff/librelane/final
step copy-layout cp "$F/gds/$TOP.gds" "$F/lef/$TOP.lef" "$OUT/harden/final/pnl/$TOP.pnl.v" "$ROOT/layout/"

# 7. Tiny Tapeout's actions, as .github/workflows/gds.yaml runs them, reproduced
#    gds job: checkout, tools/generate.sh . docs, custom_gds@ttsky26e, then the PDK version
#    added to pdk.json
W=$OUT/workspace-gds; mkdir -p "$W/tt_submission"
cp -r "$ROOT/info.yaml" "$ROOT/LICENSE" "$ROOT/layout" "$W/"
step generate-gds-job "$ROOT/tools/generate.sh" "$W" docs
COMMIT=$(git -C "$ROOT" rev-parse -q --verify HEAD || echo uncommitted)
jq -n --arg app "custom_gds action" --arg repo "local" --arg commit "$COMMIT" \
  --arg workflow_url "local: tools/harden.sh" \
  '{app: $app, repo: $repo, commit: $commit, workflow_url: $workflow_url}' > "$W/tt_submission/commit_id.json"
jq -n --arg pdk "$PDK" '{PDK: $pdk}' > "$W/tt_submission/pdk.json"
LL_PDK=$(sed -n 's/^sky130: *//p' "$(readlink -f "$ROOT/.venv")"/lib/python*/site-packages/librelane/pdk_hashes.yaml)
WF_PDK=$(sed -n 's/.*PDK_VERSION: "\([0-9a-f]*\)".*/\1/p' "$ROOT/.github/workflows/gds.yaml")
[ "$WF_PDK" = "$LL_PDK" ] || die "gds.yaml adds PDK_VERSION $WF_PDK to pdk.json, but LibreLane pins $LL_PDK"
jq --arg v "$WF_PDK" '. + {PDK_SOURCE: "open_pdks", PDK_VERSION: $v}' "$W/tt_submission/pdk.json" > "$W/pdk.json"
mv "$W/pdk.json" "$W/tt_submission/pdk.json"
cp "$W/layout/$TOP.gds" "$W/tt_submission/$TOP.gds"
# strm2oas from the KLayout the precheck's nix-shell has (the action installs KLayout 0.29.12)
STRM2OAS=$(cd "$T/tt/precheck" && nix-shell --run 'readlink -f "$(command -v klayout)"' 2>/dev/null | tail -1)
STRM2OAS=$(dirname "$(dirname "$STRM2OAS")")/lib/strm2oas
[ -x "$STRM2OAS" ] || die "no strm2oas at $STRM2OAS"
step strm2oas "$STRM2OAS" "$W/layout/$TOP.gds" "$W/tt_submission/$TOP.oas"
cp "$W/layout/$TOP.lef" "$W/tt_submission/$TOP.lef"
cp "$W/layout/$TOP.pnl.v" "$W/tt_submission/$TOP.v"
#    The artifact it uploads: info.yaml, LICENSE, docs/*, tt_submission/*
ART=$OUT/artifact; mkdir -p "$ART"
cp -r "$W/info.yaml" "$W/LICENSE" "$W/docs" "$W/tt_submission" "$ART/"

#    precheck job: precheck@ttsky26e on the artifact, with its Python packages in a venv of its
#    own on Python 3.11, as the action has (gdstk's pinned version has no wheel for newer ones):
#    python3.11 if there is one, else one micromamba installs from conda-forge
if command -v python3.11 > /dev/null; then
  PY311=python3.11
else
  MAMBA=$(command -v micromamba || echo "$ROOT/.tools/bin/micromamba")
  [ -x "$MAMBA" ] || die "the precheck needs Python 3.11: no python3.11 and no micromamba"
  step precheck-python env MAMBA_ROOT_PREFIX="$OUT/mamba" "$MAMBA" create -q -y \
    -p "$OUT/precheck-python" -c conda-forge python=3.11
  PY311=$OUT/precheck-python/bin/python3.11
fi
step precheck-venv "$PY311" -m venv "$OUT/precheck-venv"
step precheck-requirements "$OUT/precheck-venv/bin/pip" install -q -r "$T/tt/precheck/requirements.txt"
need_mem
cd "$T/tt/precheck"
step precheck env PATH="$OUT/precheck-venv/bin:$PATH" PDK=$PDK \
  PDK_ROOT="$HOME/.ciel/ciel/sky130/versions/$PRECHECK_PDK_VERSION" \
  nix-shell --run "python precheck.py --gds $ART/tt_submission/$TOP.gds --tech $PDK"
cp -r reports "$OUT/precheck-reports"
! grep -qE '<(failure|error)' reports/results.xml || die "precheck: reports/results.xml records a failure"

#    gl_test job: checkout, tools/generate.sh . test, then gl_test@ttsky26e on the artifact,
#    with the PDK version its pdk.json gives
W=$OUT/workspace-gl; mkdir -p "$W"
cp "$ROOT/info.yaml" "$W/"
step generate-gl-job "$ROOT/tools/generate.sh" "$W" test
cp -r "$ART"/. "$W/"
cp "$W"/tt_submission/*.v "$W/test/gate_level_netlist.v"
GL_PDK=$(jq -r .PDK_VERSION "$W/tt_submission/pdk.json")
cd "$W/test"
rm -f tb.vcd tb.fst results.xml
need_mem
step gl-test env PATH="$ROOT/.venv/bin:$ROOT/.tools/env/bin:$PATH" \
  PDK_ROOT="$HOME/.ciel/ciel/sky130/versions/$GL_PDK" bash -c 'make clean && GATES=yes make'
test -f results.xml || die "gl_test: no results.xml"
! grep -qE '<(failure|error)' results.xml || die "gl_test: results.xml records a failure"

#    docs job: tools/generate.sh . docs src, then the docs action's check (its PDF needs Pandoc
#    and Typst, left out here)
W=$OUT/workspace-docs; mkdir -p "$W"
cp "$ROOT/info.yaml" "$W/"
ln -s "$T/tt" "$W/tt"
step generate-docs-job "$ROOT/tools/generate.sh" "$W" docs src
cd "$W"
step check-docs "$PY" tt/tt_tool.py --check-docs

# 8. The provenance
cd "$ROOT"
step provenance "$PY" -I - "$ROOT" "$OUT" "$PAVE_WT" "$TOP" "$LL_PDK" "$PRECHECK_PDK_VERSION" <<'PY'
import csv, glob, hashlib, json, re, subprocess, sys, xml.etree.ElementTree as ET
root, out, pave, top, ll_pdk, pre_pdk = sys.argv[1:]

def git(d, *a):
    return subprocess.run(["git", "-C", d, *a], capture_output=True, text=True).stdout.strip()

def sha256(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()

tb = f"{root}/tiny-breakout"
tb_sha = git(tb, "rev-parse", "HEAD")
tags = git(tb, "tag", "--points-at", tb_sha).split() or ["(none)"]
s = json.load(open(f"{out}/signoff/summary.json"))
m, mg = s["metrics"], s["metrics_lvs_gds"]
drc = json.load(open(f"{out}/drc/summary.json"))
resolved = json.load(open(f"{out}/ll/resolved.json"))
hold = {k.split(":")[1]: v for k, v in m.items() if k.startswith("timing__hold__ws__corner:")}
setup = {k.split(":")[1]: v for k, v in m.items() if k.startswith("timing__setup__ws__corner:")}
wl = sum(float(r["length_um"].rstrip("\u00b5m")) for f in
         glob.glob(f"{out}/signoff/librelane/*-odb-reportwirelength/wire_lengths.csv")
         for r in csv.DictReader(open(f, encoding="utf-8")))
lec = re.findall(r"EQUIVALENT: (\d+) matched signals proven", open(f"{out}/signoff/lec.log").read())

def junit(path):
    t = ET.parse(path).getroot()
    cases = t.findall(".//testcase")
    bad = [c for c in cases if c.find("failure") is not None or c.find("error") is not None]
    return len(cases), len(bad)

gl_n, gl_bad = junit(f"{out}/signoff/gl_results.xml")
tt_n, tt_bad = junit(f"{out}/workspace-gl/test/results.xml")
pre = ET.parse(f"{out}/precheck-reports/results.xml").getroot()
pre_cases = [(c.get("name"), "FAIL" if c.find("failure") is not None or c.find("error") is not None
              else "skipped" if c.find("skipped") is not None else "pass")
             for c in pre.iter("testcase")]
files = [(f"{top}.gds", "the GDS, streamed out with Magic at sign-off"),
         (f"{top}.lef", "the LEF, written with Magic at sign-off"),
         (f"{top}.pnl.v", "the engine's powered netlist (final/pnl)")]
L = []
L += [f"Layout of Tiny Breakout (Paved), top module {top}, made by tools/harden.sh.", ""]
L += ["Sources"]
L += [f"  Tiny Breakout     https://github.com/zvea/tiny-breakout commit {tb_sha}",
      f"                    tag {' '.join(tags)}, the tiny-breakout submodule",
      f"  P&R engine        commit {git(pave, 'rev-parse', 'HEAD')} (experimental; private repository)",
      f"  LibreLane         {resolved['meta']['librelane_version']} (synthesis, and sign-off's steps), in its Docker image",
      f"  PDK               {resolved['PDK']}, open_pdks {ll_pdk} (LibreLane's pin)",
      f"  tt-support-tools  https://github.com/TinyTapeout/tt-support-tools commit {git(f'{out}/tree/tt', 'rev-parse', 'HEAD')}",
      ""]
L += ["Files"] + [f"  {n:<30} {sha256(f'{root}/layout/{n}')}\n    {d}" for n, d in files] + [""]
L += ["How it was made: tools/harden.sh ENGINE_REPO ENGINE_REV OUT_DIR, which ran",
      "  tools/generate.sh OUT_DIR/tree all      (the renamed tree, from the submodule)",
      "  tt/tt_tool.py --create-user-config      (Tiny Tapeout's LibreLane configuration)",
      "  python -m librelane --dockerized ... --to Yosys.Synthesis src/config_merged.json",
      "  ENGINE harden RUN_DIR NETLIST.json RULES CELLS DRC_RULES OUT_DIR",
      "  signoff/signoff.py OUT_DIR SIGNOFF_DIR --top TOP --config src/config.json",
      "      --config src/user_config.json --lec 'tools/lec.sh \"$SIGNOFF_RUN_DIR\"'",
      "      --gl 'cp \"$SIGNOFF_PNL\" test/gate_level_netlist.v && cd test && make -B GATES=yes'",
      "      --gl-results test/results.xml",
      "  signoff/drc.py OUT_DIR/final/def/TOP.def OUT_DIR/known_bad.json DRC_DIR",
      "  then Tiny Tapeout's custom_gds action, precheck and gate-level test, reproduced locally",
      ""]
L += ["Sign-off (the engine's harness)",
      f"  Magic DRC              {m['magic__drc_error__count']} errors, {m['magic__illegal_overlap__count']} illegal overlaps",
      f"  KLayout DRC            {drc['errors']} errors (front end, back end, off grid)",
      f"  LVS from the DEF       {m['design__lvs_error__count']} errors",
      f"  LVS from the GDS       {mg['design__lvs_error__count']} errors",
      f"  Antenna                {m['antenna__violating__nets']} violating nets, {m['antenna__violating__pins']} pins",
      f"  Worst setup slack      {min(setup.values()):.3f} ns ({min(setup, key=setup.get)}); none negative in 9 corners",
      f"  Worst hold slack       {min(hold.values()):.3f} ns ({min(hold, key=hold.get)}); margin {resolved['PL_RESIZER_HOLD_SLACK_MARGIN']} ns met in 9 corners",
      f"  Equivalence (LEC)      {'EQUIVALENT, ' + lec[-1] + ' matched signals proven' if lec else 'passed'}",
      f"  Gate-level test        {gl_n - gl_bad} of {gl_n} passed",
      f"  Cells                  {m['design__instance__count__stdcell']} standard cells, {m['design__instance__count']} instances in all",
      f"  Utilisation            {100 * m['design__instance__utilization']:.1f}%",
      f"  Wirelength             {wl:.0f} um routed", ""]
L += ["Tiny Tapeout's checks on the custom_gds artifact (reproduced locally)",
      f"  precheck (PDK {pre_pdk[:7]})"] + [f"    {n:<40} {r}" for n, r in pre_cases] + [
      f"  gate-level test        {tt_n - tt_bad} of {tt_n} passed", ""]
def usage(path):
    t = dict(l.strip().rsplit(": ", 1) for l in open(path) if ": " in l)
    return (f"{t['Elapsed (wall clock) time (h:mm:ss or m:ss)']} wall, "
            f"{float(t['User time (seconds)']):.1f} s user, {float(t['System time (seconds)']):.1f} s system, "
            f"{int(t['Maximum resident set size (kbytes)']) // 1024} MB max RSS")

L += ["Run time (/usr/bin/time -v, at nice 10)",
      f"  engine harden          {usage(f'{out}/harden.time')}",
      f"  sign-off harness       {usage(f'{out}/signoff.time')} (its own process tree;",
      "                         LibreLane's containers' CPU is not counted)", ""]
text = "\n".join(L)
text.encode("ascii")
open(f"{root}/layout/README.txt", "w").write(text)
print(text)
PY
echo "harden.sh: done; layout/ holds the layout and README.txt; outputs in $OUT"
