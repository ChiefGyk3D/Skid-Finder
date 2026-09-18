# Roadmap, versions and stages

This page is the record of where Skid Finder is going, what each version
means, and what has to be true before a stage label is used. The caveats
travel with the tool on purpose: a reader of any checkout can see which
claims are measured and which are still promises.

## Where it is going

Skid Finder is a passive, defensive detector for the scripted RF attacks
that turn up at conferences and in enterprises: BLE spam and flood tooling
first, Wi-Fi deauth, beacon and evil-twin patterns next. It started as one
hand-carried uConsole and is growing into a sensor net of cooperating nodes
whose records feed a SIEM, so that an event or a security team gets a
timeline and a rough location instead of a hunch. Everything stays
receive-only: it detects and never transmits.

The order of work, each stage building on the same primitive, a versioned
observation record:

1. **BLE spam** — detector measured against a labeled corpus, live alerting,
   a field menu. *v0.1.x*
2. **Sensor net** — several nodes emitting the same records to a collector
   that merges by identity and estimates location. *v0.2.x*
3. **Wi-Fi** — a passive capture frontend that emits the same record shape
   and a detector for the common floods. *v0.3.x*
4. **Hardware validation** — every threshold baselined on the uConsole +
   AIO v2 against real quiet RF and real spam. *v0.9.x, beta*
5. **Field-proven** — used at an event, records landing in a SIEM, carried
   as a unit inside [Hammunition](https://github.com/ChiefGyk3D/Hammunition).
   *v1.0.0*

## Stages

A stage says how much of the tool's behaviour has been **measured**, not how
much code exists. Code volume is the wrong yardstick for a detector.

| Stage | Means | Version range |
|---|---|---|
| **alpha** | The milestone's features are complete and green in CI, which runs against synthetic captures and stubbed radios. Nothing in the milestone has been confirmed on the target hardware. A match is a lead, not a verdict. | `0.x.y-alpha.N` |
| **beta** | The hardware checklist below is done: thresholds hold against a real quiet baseline and real spam on the uConsole + AIO v2, and the live path has fired on a real Flipper. Remaining defects are usability, not correctness. | `0.9.y-beta.N` |
| **rc** | Used through at least one real event without a field-blocking defect, with records shipped to a SIEM end to end. | `1.0.0-rc.N` |
| **stable** | rc plus carried by Hammunition as a catalog unit. From here SemVer applies to the CLI, the config keys and the record schemas. | `1.0.0` and up |

### The hardware checklist (alpha → beta)

These need the uConsole, the AC1200 radio and a Flipper Zero in a contained
space. They are the same items draft PR #6 carried and are recorded here so
they do not depend on a PR staying open.

- [ ] uConsole ambient baseline on the AC1200 recorded in the corpus and
      silent on every profile
- [ ] Flipper Zero spam captured per mode (Apple, Fast Pair, SwiftPair,
      Samsung) and recorded as labeled spam samples; `balanced` and
      `aggressive` recall 1.00
- [ ] `ble-live-watch.sh` fires within a window or two of the Flipper
      starting and goes quiet when it stops
- [ ] End-to-end field run on the uConsole with the AC1200
- [ ] `hci1`/AC1200 stable across a session, or `recover-hci.sh` documented
      as the fix
- [ ] The field menu walked through on the 1280x480 display

## Versioning

- **SemVer**, with pre-release tags. `VERSION` at the repository root holds
  the current version; `scripts/skid-finder.sh --version` prints it, and a
  test refuses a version that has no entry in `CHANGELOG.md`.
- Before 1.0 a **minor** bump is a milestone (a new capability), a **patch**
  is fixes within one. The pre-release suffix is the stage: `-alpha.N`,
  `-beta.N`, `-rc.N`.
- Every version is an annotated git tag `vX.Y.Z[-stage.N]` and a GitHub
  release; pre-releases are marked as such so nobody installs an alpha by
  accident.
- **Record schemas are versioned separately** (`ble-obs/1`, `ble-alert/1`,
  `wifi-obs/1`). A schema version changes only when a consumer would break.
  The tool version can move many times without touching them.
- `CHANGELOG.md` follows Keep a Changelog: one section per version, dated,
  with the milestone it closes.

## Milestones

GitHub milestones track the same list; issues attach to them.

| Version | Milestone | Exit criteria |
|---|---|---|
| 0.1.0-alpha | [#1](https://github.com/ChiefGyk3D/Skid-Finder/milestone/1) | Measured detector, normalized observations, live alerting with JSON alert records, field menu, versioning in place. |
| 0.2.0-alpha | [#2](https://github.com/ChiefGyk3D/Skid-Finder/milestone/2) | Collector merging records from several sensors by identity, an MQTT transport, a written node contract, reference nodes for Linux/SBC and ESP32, location estimate with its error stated. |
| 0.3.0-alpha | [#3](https://github.com/ChiefGyk3D/Skid-Finder/milestone/3) | Passive Wi-Fi capture emitting `wifi-obs/1`, a detector for deauth/disassoc floods, beacon floods and evil-twin patterns measured against a labeled corpus, live alerting, records accepted by the collector. |
| 0.9.0-beta | [#4](https://github.com/ChiefGyk3D/Skid-Finder/milestone/4) | The hardware checklist above, complete. |
| 1.0.0 | [#5](https://github.com/ChiefGyk3D/Skid-Finder/milestone/5) | One event's worth of use, SIEM path exercised end to end, Hammunition manifest merged. |

## What is deliberately not promised

- A pin on a map. RSSI location indoors is metres to tens of metres at best;
  the collector states its error and only estimates `strong`/`session` tier
  identities and continuous spam sources. See `docs/sensor-net-notes.md`.
- Attribution to a specific tool or person. Signatures name pattern
  families; a `model`-tier identity is a product, possibly several people.
- Any transmit capability, ever.

## Cutting a release

Releases are cut from `main`, after the milestone's PRs have merged, so the
tag points at a commit everyone can check out. One exception, used for the
first three alphas: while milestone branches are stacked and waiting for
review, a pre-release tag may be placed on the milestone branch head whose
`VERSION` names it, so the milestone is trackable and other projects can pin
it. Content is what a tag pins, and a squash merge reproduces that content on
`main`. Beta and later are tagged on `main` only.

1. Set `VERSION`, move the `[Unreleased]` notes in `CHANGELOG.md` under a
   dated heading for that version, and add its link at the bottom. Run
   `./tests/test-toolkit.sh`; the versioning test refuses a mismatch.
2. Merge that change, then on `main`:

   ```bash
   v="v$(cat VERSION)"
   git tag -a "$v" -m "Skid Finder $v"
   git push origin "$v"
   gh release create "$v" --title "Skid Finder $v" --notes-from-tag --prerelease
   ```

   Drop `--prerelease` only for `1.0.0` and later stable versions.
3. Close the GitHub milestone. Open the next `[Unreleased]` section.
