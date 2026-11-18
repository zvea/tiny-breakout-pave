Layout of Tiny Breakout (Paved), top module tt_um_tiny_breakout_pave, made by tools/harden.sh.

Sources
  Tiny Breakout     https://github.com/zvea/tiny-breakout commit 63e0f66705f4f38b5415e01323f915849f1e5e2a
                    tag sky26e, the tiny-breakout submodule
  P&R engine        commit 2ad8795e9a3f7158cf9db78398a80af0787bfb71 (experimental; private repository)
  LibreLane         3.0.14 (synthesis, and sign-off's steps), in its Docker image
  PDK               sky130A, open_pdks 8afc8346a57fe1ab7934ba5a6056ea8b43078e71 (LibreLane's pin)
  tt-support-tools  https://github.com/TinyTapeout/tt-support-tools commit 8f7b5060d7f6df73bfd2e0b8d8fa0fd1dca0a0b1

Files
  tt_um_tiny_breakout_pave.gds   46ff0200f9d2c53e48dad3fc38b542afe905d6d923eadea838a21df64dfa3108
    the GDS, streamed out with Magic at sign-off
  tt_um_tiny_breakout_pave.lef   57642f25b9e532d7fb749f7ef68544af327bb292acbe4af706ad3f5c64e38869
    the LEF, written with Magic at sign-off
  tt_um_tiny_breakout_pave.pnl.v 794012f67f51177d658a24878cf679909d9822f426ad33bbed880e8e6d9fcf05
    the engine's powered netlist (final/pnl)

How it was made: tools/harden.sh ENGINE_REPO ENGINE_REV OUT_DIR, which ran
  tools/generate.sh OUT_DIR/tree all      (the renamed tree, from the submodule)
  tt/tt_tool.py --create-user-config      (Tiny Tapeout's LibreLane configuration)
  python -m librelane --dockerized ... --to Yosys.Synthesis src/config_merged.json
  ENGINE harden RUN_DIR NETLIST.json RULES CELLS DRC_RULES OUT_DIR
  signoff/signoff.py OUT_DIR SIGNOFF_DIR --top TOP --config src/config.json
      --config src/user_config.json --lec 'tools/lec.sh "$SIGNOFF_RUN_DIR"'
      --gl 'cp "$SIGNOFF_PNL" test/gate_level_netlist.v && cd test && make -B GATES=yes'
      --gl-results test/results.xml
  signoff/drc.py OUT_DIR/final/def/TOP.def OUT_DIR/known_bad.json DRC_DIR
  then Tiny Tapeout's custom_gds action, precheck and gate-level test, reproduced locally

Sign-off (the engine's harness)
  Magic DRC              0 errors, 0 illegal overlaps
  KLayout DRC            0 errors (front end, back end, off grid)
  LVS from the DEF       0 errors
  LVS from the GDS       0 errors
  Antenna                0 violating nets, 0 pins
  Worst setup slack      26.674 ns (max_ss_100C_1v60); none negative in 9 corners
  Worst hold slack       0.064 ns (min_ff_n40C_1v95); margin 0.05 ns met in 9 corners
  Equivalence (LEC)      EQUIVALENT, 231 matched signals proven
  Gate-level test        4 of 4 passed
  Cells                  1902 standard cells, 3080 instances in all
  Utilisation            79.1%
  Wirelength             33475 um routed

Tiny Tapeout's checks on the custom_gds artifact (reproduced locally)
  precheck (PDK 0536d02)
    Magic DRC                                pass
    KLayout FEOL                             pass
    KLayout BEOL                             pass
    KLayout offgrid                          pass
    KLayout pin label overlapping drawing    pass
    KLayout zero area                        pass
    KLayout Checks                           pass
    Pin check                                pass
    Boundary check                           pass
    Power pin check                          pass
    Layer check                              pass
    Cell name check                          pass
    urpm/nwell check                         pass
    Analog pin check                         pass
    Verilog syntax check                     pass
  gate-level test        4 of 4 passed

Run time (/usr/bin/time -v, at nice 10)
  engine harden          0:50.29 wall, 48.1 s user, 0.5 s system, 449 MB max RSS
  sign-off harness       14:15.50 wall, 972.1 s user, 4.5 s system, 246 MB max RSS (its own process tree;
                         LibreLane's containers' CPU is not counted)
