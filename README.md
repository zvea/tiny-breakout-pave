# Tiny Breakout (Paved)

[Tiny Breakout](https://github.com/zvea/tiny-breakout), a brick-breaker game for Tiny Tapeout,
laid out with an experimental place-and-route engine.

The design is the `tiny-breakout` submodule, pinned at the commit the layout was made from. This
repository adds the layout, in [layout/](layout); how it was made is recorded in
[layout/README.txt](layout/README.txt). `docs/` and `test/` are generated from the submodule by
`tools/generate.sh`.

## Syncing with Tiny Breakout

```sh
tools/sync.sh REF                                # submodule to REF; info.yaml, LICENSE redone
tools/harden.sh ENGINE_REPO ENGINE_REV OUT_DIR   # the layout into layout/, checked
git add -A && git commit
```

REF is a tag, a branch or a commit of Tiny Breakout; ENGINE_REPO is a clone of the engine and
ENGINE_REV the commit to lay out with. `harden.sh`'s header lists what it needs and the steps it
runs.

## Tests

```sh
python3 -m pytest tools/test     # with TB_REPO set to a Tiny Breakout clone, also the real design
```
