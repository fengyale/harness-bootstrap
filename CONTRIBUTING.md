# Contributing

Thanks for taking a look. This project is a meta-skill: most changes affect
either the installed harness or the package's own gate, so the bar is
"change one rule in every place that carries it".

## Before you start

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-package.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1
```

Both must pass. The pre-commit hook runs `tools\verify-package.ps1 -Fast`
automatically; do not bypass it with `--no-verify`.

## What belongs here

- Fixes to gate behaviour, field validation, hook installation, metrics.
- New platform adapters that do not break the existing ones.
- Documentation that removes a contradiction between SKILL, references and templates.
- New project-path or grounding-rule improvements with a machine-checkable consequence.

What does not belong here:

- More prose that no mechanism reads.
- New skills for a specific business stack (those belong in an installed project).
- Features that only work on one private codebase.

## Rules for code

- `.ps1` files are **pure ASCII**, or UTF-8 **with exactly one BOM** if they must contain Chinese.
  A BOM-less file with non-ASCII bytes is parsed as ANSI by Windows PowerShell 5.1 and will break.
- Generated git hooks use **POSIX sh + LF**. Do not add Bash-only syntax.
- Prefer PowerShell 5.1 compatible syntax; do not assume `pwsh` 7 or `$IsLinux`.
- A rule that lives in more than one file must be added to
  `tools/package-contract.json` so the copies cannot drift.
- Keep `AGENTS.md` under the 150-line budget; the template is the source of that budget.

## Changing a gate rule

1. Change the behaviour in `templates/scripts/`.
2. Update the JSON that carries the match strings (scripts must stay ASCII).
3. Update the doc that describes the rule: `SKILL.md`, `templates/AGENTS.md`,
   `templates/.harness/rules/开发流程规范.md`, or `references/`.
4. Add or update a contract in `tools/package-contract.json`.
5. Add a behavioural test in `tests/` when the change is about blocking/skipping.
6. Run the full gate and the tests.

## Pull requests

- One concern per PR; say what the user-visible behaviour changes.
- Include the output of `tools\verify-package.ps1` and `tests\run-all.ps1`.
- If you change a contract, explain which drift it prevents.
- No CLA is required. By submitting a PR you agree your contribution is
  licensed under the MIT License (inbound = outbound), the same as this project.

## Reporting bugs

Include:

- platform and PowerShell version;
- the exact command;
- the full output (not a summary);
- whether the project is greenfield or an existing codebase.
