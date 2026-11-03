# Harness Bootstrap

> 把 AI 编码从“看运气”变成“看流程”。

一个给真实项目安装 **AI 编码 Harness** 的元技能：约束边界、规定输入、仪表观测、外部判据、可重复。
装好之后，编码智能体不再靠通用知识即兴发挥，而是像熟悉这个项目的资深工程师一样工作；人只看关键决策。

**English summary**: A meta-skill that installs a harness into an AI coding project — constraints, gates, observability and review loops — so the agent works like a senior engineer who knows the codebase. Windows-first; see [Platform support](#platform-support).

---

## 它解决什么

普通 AI 编码工具给的是通用脚手架：它知道怎么写 Java、怎么写 React，但不知道**你这个项目**——

- 金额只能用分、异常必须走统一体系、缓存 Key 有前缀；
- 该先写变更摘要、该在哪一步停下来给人确认；
- 规则写了没人读，门禁靠自觉，同一个错误反复犯。

Harness Bootstrap 把这些隐性的项目知识变成**显性的、可加载的、可校验的资产**，并把“有没有做到”变成机器判定。

## 三个承诺

1. **实现层的错由机器吸收，人只确认关键决策。** 能机器判定的绝不留给人提醒。
2. **每一次纠正必须落到「规则 / 门禁 / 技能」三者之一。** 只在对话里说“下次注意”等于没发生。
3. **项目知识必须在该被读到的时刻被读到；读不到就由出口校验拦回来。**

所有机制只服务这三句话，写在 `references/核心论述.md` 的基调里。

## 快速开始

### 1. 放到技能目录

| 平台 | 位置 |
| --- | --- |
| TRAE | `.trae/skills/harness-bootstrap/` |
| Claude Code | `.claude/skills/harness-bootstrap/` |
| Codex / 无子智能体平台 | 按索引模式引用 `SKILL.md`，不复制 agents 目录 |

把本仓库（或发布包）整个放到对应目录。`tools/` 是**本包自检用**，安装时不会复制进项目。

### 2. 让智能体执行 `SKILL.md` 第 0 步

智能体会先探测平台和项目事实，然后：

- 存量项目：跑 `probe-project.ps1` / `probe-stack.ps1`，按证据生成 `AGENTS.md`、规则、技能、wiki、模块卡；
- 新项目：先做背景 / 业务 / 选型确认，产出 `.harness/project-brief.md`，再生成骨架。

两条路径都必须遵守**接地协议**：项目断言要有 E1（可跑命令）或 E2（真实文件 + 行号）证据；新项目无代码阶段才允许 E0（用户确认）。

### 3. 安装门禁

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-git-hooks.ps1
```

安装三个 git hook：`pre-commit`（红线扫描 + SQL 评审 + summary 基础字段）、`post-commit`（记录提交是否被门禁覆盖）、`pre-merge-commit`（合并提交也走门禁）。

### 4. 验收

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-harness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-grounding.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stage-gate.ps1 -Stage 7 -Feature <name>
```

`verify-*` 通过只代表**结构对了**；A1–A4、A6 必须靠跑一个真实任务来验，A7 需要两个 14 天窗口。

## 装好之后你会得到

```
AGENTS.md                    唯一常驻文件（≤150 行）：技术栈 / 必跑命令 / 红线 / 文件索引 / 编码纪律
.harness/
  rules/                     编码规范、工程结构、开发流程（不可协商的边界）
  skills/                    技能正文（按需加载，被平台入口链接）
  wiki/                      领域术语、业务模型、数据模型、接口协议
  modules/                   模块卡：重点 / 难点 / 坑点 / 验证方式
  changes/<feature>/         summary.md、迁移脚本、回滚脚本
  metrics/                   gate.jsonl、promoted.txt（度量与晋升）
.trae/                       平台发现入口：skills 链接、agents、hooks
scripts/                     探测、扫描、阶段门、字段校验、度量、卸载
```

## 这个仓库为什么特殊：自举门禁

它卖“机器门禁”，所以自己也必须有门禁。仓库自带：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-package.ps1
```

检查项：PS 解析 / 编码（PS 5.1 的 ASCII-BOM 规则）/ JSON / 必需文件 / **26 条跨文件契约** / 行为冒烟。

- `-Fast` 供本仓库的 `pre-commit` 使用，提交时自动跑；
- 全量（含冒烟）在发布前跑；
- 契约文件 `tools/package-contract.json` 把“同一规则写在脚本、JSON、SKILL、AGENTS、规则五处”变成可判定断言，防止改一处漂五处。

真实输出：

```text
[PASS] parse      19 .ps1 file(s) parse
[PASS] encoding   ASCII without BOM, or UTF-8 with BOM
[PASS] json       4 JSON file(s) parse
[PASS] structure  required files present, package-only files absent
[PASS] contract   26 rule/script/doc contract(s) hold
[PASS] smoke      install -> stage 4 -> unfilled summary rejected -> uninstall, in a temp copy

package gate: OPEN
```

行为测试：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1
```

`tests/` 里的两套测试会在 `%TEMP%` 建临时项目，验证真实退出码（缺行 BLOCKED、占位 SKIP、编译/测试真跑、pre-commit 只查 initial、三 hook 安装/卸载、A3+ 伪造被拒）。

## 验收标准（A1–A7）

| # | 标准 | 怎么验 |
| --- | --- | --- |
| A1 | 先分析再动手 | 真实跑一个需求 |
| A2 | 主动加载技能 | 看它读了哪些文件 |
| A3 | 符合项目约定 | 抽查 3 条改动，≥2 条对应到规则条款 |
| A3+ | 该补的短板补上并说明 | `summary.md` 的「待补短板」有结论 |
| A4 | 自己跑校验并贴真实输出 | 看它有没有贴命令结果 |
| A5 | 机器门禁能拦住违规提交 | 故意造违规 → 提交被拦 |
| A6 | 人只确认关键决策 | 任务级 `corrections ≤ 2` 且 `impl_corrections: 0`；项目级两个 14 天窗口趋势不为 `REGRESSING` |
| A7 | 同一个错误不犯第二次 | 第 2 次才晋升；`metrics.ps1` 同一 `lesson_id` ≥2 次 |

## Platform support

- **Windows + Windows PowerShell 5.1**：主要支持路径，所有脚本与测试在此验证。
- **pwsh 7 / macOS / Linux**：机制脚本按 5.1 兼容语法编写，但路径分隔与 `chmod` 行为未逐一验证；欢迎按 `CONTRIBUTING.md` 补充平台测试。
- **平台发现**：TRAE（`.trae/`）、Claude Code（`.claude/`）、Codex / 未知平台（索引模式，无子智能体）。没有对应目录时不假装子智能体存在。

## 已知限制

- 技能是否触发仍依赖平台匹配；`AGENTS.md` 的“必上技能”是兜底，不是保证。
- `A7` 需要时间，仓库不提供“已跑通”的案例数据；请用自己的项目验。
- 红线扫描只覆盖新增行（存量违规不阻塞提交），这是刻意取舍。
- 新项目 E0 在代码落地后只报 WARN 要求升级，不会自动阻止合并；第一个真实任务必须把它换成 E1/E2。

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。改动前先跑：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-package.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1
```

## License

MIT. 见 [LICENSE](LICENSE)。
