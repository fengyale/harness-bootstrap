# Legacy upgrade fixtures

Exact snapshots of the package files a real installed project had at the tagged
version. `tests/test-update.ps1` copies one into a temp project, compiles the one
installed skill, and runs the **current** package's
`assets/upgrade/upgrade-harness.ps1 -Apply -MergeSkills`, then asserts that the
new behaviour is actually active.

| Version | Why this one |
| --- | --- |
| 1.31.20 | before the marked upgrade blocks: AGENTS has no start-command paragraph, `harness-required.json` lacks the newer keys |
| 1.31.22 | the version that shipped the unmarked start-command paragraph: the upgrade must dedupe it instead of writing it twice |

Included per version:

- `AGENTS.md`
- `rules/开发流程规范.md`
- `changes/_template/summary.md`
- `harness-required.json`
- `skills/coding-skill/SKILL.md`

The test moves these into the installed layout (`scripts/`, `.harness/rules`,
`.harness/changes/_template`, `.harness/skills/main-dev/coding-skill`). The
fixture itself stays flat so a diff against the tag is easy to read.

## Refresh a snapshot

Only do this when a new legacy version must be covered; the point is that the
snapshot does not move with the package.

```powershell
$tag = 'v1.31.20'
$map = @{
  'assets/AGENTS.md' = 'AGENTS.md'
  'assets/.harness/rules/开发流程规范.md' = 'rules/开发流程规范.md'
  'assets/.harness/changes/_template/summary.md' = 'changes/_template/summary.md'
  'assets/scripts/harness-required.json' = 'harness-required.json'
  'assets/.harness/skills/main-dev/coding-skill/SKILL.md' = 'skills/coding-skill/SKILL.md'
}
foreach ($k in $map.Keys) {
  $out = Join-Path ('tests\fixtures\legacy-' + $tag.TrimStart('v')) $map[$k]
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null
  Start-Process -FilePath git -ArgumentList @('cat-file', 'blob', ($tag + ':' + $k)) `
    -RedirectStandardOutput $out -NoNewWindow -Wait
}
```

`Start-Process` is used on purpose: PowerShell redirection would re-encode the
blob, and `Set-Content -Encoding UTF8` would add a BOM.
