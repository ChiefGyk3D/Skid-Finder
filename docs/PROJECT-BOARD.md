# The project board

Every piece of Skid Finder work, shipped or planned, is a card on one
GitHub Project: [Skid Finder](https://github.com/users/ChiefGyk3D/projects/TBD).
The board is defined as code in [`board.yaml`](../board.yaml) for
[Scrum Around and Find Out](https://github.com/ChiefGyk3D/scrum-around-and-find-out)
(SAFO), and is laid out like the board of the Hammunition suite so one
reading habit works for both. The stage definitions and the milestone list
stay in [ROADMAP.md](ROADMAP.md); the board is where the work lives.

## The hard rules

1. **An issue before work.** Nothing starts without an issue and a card.
   Roadmap items without an issue get one first.
2. **Pull requests link their issue** (`Closes #N` or `Refs #N`). A pull
   request is a card too: ready is In review, draft is In progress, merged
   is Done.
3. **Agents get an `issue:` line.** A brief to an agent starts with
   `issue: ChiefGyk3D/Skid-Finder#N`, so every agent action traces to a card.
4. **Receive-only still governs everything.** A card that adds a transmit
   path is declined, as in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Fields

| Field | Holds |
|---|---|
| Status | Backlog, Next, In progress, In review, Blocked, Done |
| Area | Detector, BLE, Wi-Fi, Sensor net and collector, Other radios, Hardware and field, Docs, CI and release, Security, Process |
| Kind | Feature, Bug, Decision, Bench, Chore, Docs, Release, Epic. A Bench card is a hardware measurement or field run that produces a capture and a finding |
| Epic | One option per ROADMAP milestone, plus Process and security |
| Priority | P0 now, P1 soon, P2 later, P3 someday |
| Effort | S about 2 hours, M about 5, L about 12, XL about 30 (split an XL before scheduling) |
| Agent | Claude, Codex, Copilot, ChatGPT, Ollama, RAG, You |
| Sprint | S1 to S8, 14-day iterations |
| Start date, Target date | Draw the bar on the Roadmap view |
| Done on | The day the card closed or merged |
| Decision | Free text: the ruling, when the card is a decision |

A card with no Sprint is Backlog: wanted and ordered by priority, not
promised. The sprint load counts the maintainer's own hours (Agent You);
about 11 hours a week, 22 per sprint. Items done by agents are limited by
their budgets and by review time.

## Views

All Items, Board, Roadmap, Sprint, Sprint plan, Epics, Bugs, Blocked: needs
the maintainer, By area, Security, Docs, Done log, Agents at work. The
filters are in `board.yaml`; grouping, columns and date fields are set in
the GitHub UI and listed under `ui_only` there.

## Running SAFO

```bash
safo --board board.yaml validate      # offline schema check, reads nothing
safo --board board.yaml bootstrap     # create missing fields, views, iterations
safo --board board.yaml reconcile     # add missing issues and PRs, repair blanks
safo --board board.yaml audit         # compare the live board with board.yaml
```

`validate` needs no login. The others run from the maintainer's own `gh`
login (a user-owned Project cannot be written by an App), so no token is
stored in CI. `bootstrap` never edits existing options: an option added to
a field that already holds values is added in the GitHub UI.

## Where the schedule stands

The sprint calendar starts **2027-02-23** (to be confirmed: Skid Finder
resumes after the Hammunition 1.0 work). The hardware checklist in
[ROADMAP.md](ROADMAP.md) is the first stretch: it needs the uConsole in
hand. The Hammunition side of the work is tracked in
[Renegade-Penguin/Hammunition#334](https://github.com/Renegade-Penguin/Hammunition/issues/334).
