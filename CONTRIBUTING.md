# Contributing

Thank you. The most valuable contribution right now is a capture from
hardware this project has not seen: a different Bluetooth adapter, a
different Wi-Fi card, a venue that is not a hacker conference. Second is a
fix with a test that would have caught it. Third is everything else.

## The rules that shape every change

- **Receive-only.** Nothing transmits. A contribution that adds a transmit
  path, however useful for testing, is declined; test senders are your own
  devices in a contained space (`docs/flipper-spam-capture.md`).
- **Say what the data supports.** Records carry an identity tier and
  locations carry an error bar. A change that claims more than that, in
  code or in prose, is asked to claim less.
- **Measured, not assumed.** A threshold, a field name, a package name, a
  compile result: if it can be checked, check it and say when and where.
  The README, the manifests and the docs all carry dates for that reason.
- **Tested, and falsifiable.** Every check in `tests/` was broken on
  purpose once to prove it goes red. Do the same for a new one.

## Before you open a pull request

```bash
./tests/test-toolkit.sh                       # the whole suite, ~10 minutes
shellcheck -S warning -x scripts/*.sh tests/*.sh
ruff check scripts/*.py tests/*.py
```

CI runs the same on Python 3.11 and 3.13. If you changed a detector, the
precision/recall gate (`tests/test-detector-metrics.py`, both modalities)
must still show `fp_rate 0.00` on every profile; if a real ambient capture
of yours trips it, that is the finding to report, with the capture recorded
via `scripts/add-corpus-sample.sh`.

## What to include

- **A capture** (`.btsnoop` or the tshark `.tsv`), scrubbed if you prefer,
  for anything about detection. Synthetic fixtures live in `tests/`, real
  ones under `tests/corpus/real/` (git-ignored; only the manifest line is
  tracked).
- **The doctor output** (`./scripts/skid-finder.sh --doctor`) for anything
  about a machine.
- **A CHANGELOG line** under `[Unreleased]`, in the voice of the file.
- **Docs in the same change.** A feature without its README or docs entry
  is not finished; the README's roadmap section is where caveats live.

## Style

Shell is `bash` with `set -euo pipefail`, shellcheck clean at warning
level, and never `source`s a config file. Python targets 3.11, ruff clean
under `ruff.toml`, standard library only except `paho-mqtt` behind a clear
error when absent. Comments explain why, not what. Commit messages say what
was measured and where.

## Licence

Apache-2.0. By contributing you agree your contribution is licensed the
same way.
