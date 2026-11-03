# Agent Harness Bootstrap

**AI coding capability is no longer the bottleneck. Predictability is.**

> [中文版](README.md) · [Why this exists](harness工程化ai编程-为什么做这件事.md)

[![package gate](https://github.com/fengyale/agent-harness-bootstrap/actions/workflows/verify.yml/badge.svg)](https://github.com/fengyale/agent-harness-bootstrap/actions/workflows/verify.yml)
[![version](https://img.shields.io/github/v/release/fengyale/agent-harness-bootstrap?display_name=tag)](https://github.com/fengyale/agent-harness-bootstrap/releases)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![stars](https://img.shields.io/github/stars/fengyale/agent-harness-bootstrap?style=social)](https://github.com/fengyale/agent-harness-bootstrap/stargazers)

---

## The problem it solves

Today's models are **good enough** to write code for most business work. What
actually blocks teams is something else:

> **You don't dare hand the work over to it.**

Because it may have misunderstood the requirement while sounding confident; may
miss an unwritten rule of your project; may say "done" when it does not even
compile.

No amount of prompt tuning fixes this. Trying to remove a model's uncertainty
with better prompts is **fighting the nature of the model**.

The workable move is to stop improving the core and put a **deterministic shell
around** it:

```
Harness = rules + execution engine + closed loop
```

| | Rules only | Engine only | No closed loop |
|---|---|---|---|
| Outcome | Documents nobody follows | Runs, but nothing says what "right" is | Finds errors, has nothing to fix them with |

All three are needed to turn "depends on luck" into "follows a process".

---

## What changes after you install it

| Before | After |
| --- | --- |
| Project knowledge is re-supplied by hand every round | Written into `AGENTS.md` / rules / wiki, loaded on demand, indexed |
| Rules exist but the agent never reads them | Exit checks: `summary.md` fields, stage gates, `verify-*` scripts point them out |
| Gates rely on discipline; `--no-verify` skips them | git hooks really block; bypasses are recorded and counted in `bypassRate` |
| No way to tell if things are improving | `metrics.ps1` trends correction count, blocks, and skill load rate |
| The same mistake happens over and over | When a `lesson_id` appears a 2nd time, the script says to promote it to a rule / gate / skill |

In one line: **turn "please follow the conventions" into "you cannot pass without
following them."**

### For engineering leads

| Your question | The answer here |
| --- | --- |
| **How big is the commitment?** | Cold start installs 3–5 skills (hard cap 8), not all 25. Roughly 1–2 person-days for the first landing |
| **Where is the risk?** | On an existing codebase the first scan may report hundreds of legacy violations → must run in "new lines only" mode; historical debt is never blocked |
| **How do we accept it?** | A1–A7 are checkable; `corrections ≤ 2` and `impl_corrections = 0` are the hard numbers |
| **How fast does it pay off?** | The mechanism is verifiable the same day (A5: make a bad commit, see if it is blocked). The closed loop (A7) needs two consecutive 14-day windows |
| **Will it rot?** | A biweekly review decides what to add, what to promote to a gate, and **what to delete**; a skill loaded 0 times in 4 weeks is flagged as a candidate |

### For solo developers

| Your question | The answer here |
| --- | --- |
| **How much do I have to learn?** | Nothing. Install it and the agent follows the process; you only confirm business trade-offs |
| **Is it worth it?** | One criterion: **will the same mistake happen a second time?** |
| **Does it lock me in?** | Content lives in `.harness/` (yours), entry points live in the platform directory (rebuildable). Switching tools only changes links |
| **Could I just skip it?** | Sure — then you keep watching. **Predictability is bought once and pays for a long time** |

---

## Try it in 60 seconds (no need to install it anywhere yet)

```powershell
git clone https://github.com/fengyale/agent-harness-bootstrap.git
cd agent-harness-bootstrap
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-package.ps1
```

You will see:

```text
[PASS] parse      19 .ps1 file(s) parse
[PASS] encoding   ASCII without BOM, or UTF-8 with BOM
[PASS] json       4 JSON file(s) parse
[PASS] structure  required files present, package-only files absent
[PASS] contract   26 rule/script/doc contract(s) hold
[PASS] smoke      install -> stage 4 -> unfilled summary rejected -> uninstall, in a temp copy

package gate: OPEN
```

Those 26 contracts check one thing: **does the same rule say the same thing in
the script, the JSON, the SKILL, the AGENTS file and the rule document?** Changing
one place and drifting five is the most common way this category of project dies.

For a deeper look:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1
```

Two behavioural suites build a throw-away project under `%TEMP%` and assert the
real exit codes: missing row → BLOCKED, placeholder → SKIP, compile and test rows
really run, pre-commit checks basic fields only, all three hooks install and
uninstall, and a spoofed A3+ is rejected.

---

## Install it into your project

### 1. Put it in a skills directory

| Platform | Location |
| --- | --- |
| TRAE | `.trae/skills/harness-bootstrap/` |
| Claude Code | `.claude/skills/harness-bootstrap/` |
| Codex / platforms without subagents | Reference `SKILL.md` in index mode; do not copy the agents directory |

`tools/` is **for this package's own self-check**; it is not copied into your project.

### 2. Have the agent run step 0 of `SKILL.md`

It probes the platform and the project first, then takes one of two paths:

- **Existing codebase**: run `probe-project.ps1` / `probe-stack.ps1`, then generate
  `AGENTS.md`, rules, skills, wiki and module cards from the evidence;
- **New project**: confirm background / domain / stack choices first, produce
  `.harness/project-brief.md`, then generate the skeleton.

Both paths obey the **grounding protocol**: every project-specific claim needs
E1 (a runnable command) or E2 (a real file + line number). Only a new project
before any code may use E0 (user confirmation), and that must be upgraded once
code lands.

### 3. Install the gates

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-git-hooks.ps1
```

Three hooks:

- `pre-commit`: red-line scan (new lines only) + SQL review + summary basic fields;
- `post-commit`: records whether this commit was covered by the gate, so a bypass
  rate can be computed;
- `pre-merge-commit`: merge commits are not exempt either.

### 4. Verify

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-harness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-grounding.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stage-gate.ps1 -Stage 7 -Feature <name>
```

All-green `verify-*` only means the **structure** is right. A1–A4 and A6 need one
real task; A7 needs two 14-day windows.

---

## What you end up with

```text
AGENTS.md                    the only always-resident file (<=150 lines)
.harness/
  rules/                     coding conventions, project structure, workflow
  skills/                    skill bodies (loaded on demand)
  wiki/                      domain terms, business model, data model, API contract
  modules/                   module cards: focus / difficulty / traps / verification
  changes/<feature>/         summary.md, migration scripts, rollback scripts
  metrics/                   gate.jsonl, promoted.txt
.trae/                       platform entry points: skill links, agents, hooks
scripts/                     probes, scanners, stage gates, field checks, metrics
```

---

## Acceptance criteria (A1–A7)

| # | Criterion | How it is verified |
| --- | --- | --- |
| A1 | Analyses before acting | Run one real requirement |
| A2 | Loads skills on its own | Watch which files it reads |
| A3 | Matches project conventions | Sample 3 changes; at least 2 map to a rule clause |
| A3+ | Fills a genuine gap and says so | `summary.md` has a conclusion under "gaps to fill" |
| A4 | Runs its own checks and pastes real output | Look for command output in the delivery |
| A5 | A machine gate blocks a bad commit | Make a violation on purpose; the commit must fail |
| A6 | A human only confirms key decisions | Per task `corrections <= 2` and `impl_corrections: 0`; per project, the 14-day trend must not be `REGRESSING` |
| A7 | The same mistake is not made twice | Promotion happens on the 2nd occurrence; `metrics.ps1` shows the same `lesson_id` >= 2 times |

These criteria have been exercised on a real existing codebase for the install,
gate and stage-gate flow. A7 takes time; this repository does not draw that
conclusion for you.

---

## Why not another prompt collection

1. **The deliverable is not 24 markdown files — it is executable gates and
   metrics.** The skill templates are raw material. The product is the
   `pre-commit` block, the stage gate, the field validation, the trend review and
   a clean uninstall path.
2. **It tells you plainly when it did not work.** `verify-harness`,
   `verify-grounding` and `stage-gate` output PASS / FAIL / SKIP, not "looks good".
3. **It holds itself to the same rules.** This repository ships its own gate:
   26 cross-file contracts + behavioural tests + its own `pre-commit`. A project
   that sells gates cannot be without one.

---

## Platform support and limits

- **Windows + Windows PowerShell 5.1** is the primary supported path; the
  scripts and tests are validated there.
- **pwsh 7 / macOS / Linux**: written in 5.1-compatible syntax, but path
  separators and `chmod` behaviour are not verified everywhere. The gate layer
  (`red-line-scan.py`) is cross-platform; the audit layer is not yet adapted.
- **Platform discovery**: TRAE (`.trae/`), Claude Code (`.claude/`), Codex /
  unknown (index mode). When there is no matching directory, it does not pretend
  subagents exist.
- **Known trade-offs**: the red-line scan only covers new lines (legacy
  violations do not block commits); E0 in a new project reports WARN after code
  lands and asks for an upgrade rather than blocking the merge — the first real
  task must turn it into E1/E2.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Before changing anything, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-package.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1
```

## License

MIT. See [LICENSE](LICENSE).

---

**If you have ever had rules nobody reads, gates nobody enforces, and the same
mistake made three times — this repository is worth a star.**
