# Pull request

## What changed

<!-- One or two sentences. State the user-visible behaviour change, not the diff. -->

## Why

<!--
If this touches a gate, a rule or a script, say which failure it prevents.
"Adds consistency" is not a reason; "the scanner silently skipped files staged
with `git add -p`" is.
-->

## Which surfaces this touches

<!--
This project keeps one rule in several places on purpose. Tick what you changed.
If you changed one of them, the package contract may need a new entry.
-->

- [ ] `templates/scripts/` — behaviour
- [ ] `templates/scripts/*.json` — the strings the scripts match on
- [ ] `SKILL.md` — the installer's only entry point
- [ ] `templates/AGENTS.md` — the always-resident file
- [ ] `templates/.harness/rules/` — the rule documents
- [ ] `references/` — the method documents
- [ ] `tools/package-contract.json` — the assertions that keep the above in sync
- [ ] `tests/` — behavioural coverage
- [ ] docs only

## Checks

Both must pass. The pre-commit hook runs `tools\verify-package.ps1 -Fast`
automatically — do not bypass it with `--no-verify`.

<!-- Paste the real output. A summary is not accepted here. -->

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-package.ps1
```

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1
```

## If you changed a contract

<!--
`tools/package-contract.json` asserts that one rule says the same thing in
script, JSON, SKILL, AGENTS and the rule documents. Explain which drift the
new entry prevents.
-->

## Checklist

- [ ] `.ps1` files are pure ASCII, or UTF-8 with exactly one BOM
- [ ] `AGENTS.md` is still under the 150-line budget
- [ ] `AGENTS.md` contains all five sections: 技术栈 / 必跑命令 / 红线 / 文件索引 / AI 编码纪律
- [ ] No rule was added without a matching entry in `red-line-rules.json`
- [ ] The change works on Windows PowerShell 5.1
