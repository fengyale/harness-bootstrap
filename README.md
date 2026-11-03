# Harness Bootstrap

**你缺的不是更强的模型，是可预测的 AI 编码。**

同一个需求，今天写得好，明天写得歪；规则写了没人读，门禁靠自觉，同一个错误犯三次——
这不是模型能力问题，是缺少工程约束。

Harness Bootstrap 是一个元技能：给一个真实项目装上**约束、门禁、观测与复盘**，
让编码智能体像熟悉这个项目的资深工程师一样工作。人只看关键决策。

> **English**: A meta-skill that installs a verifiable harness into an AI coding project —
> constraints, gates, observability and review loops. Not another prompt collection.

---

## 30 秒看懂

| 你现在的状态 | 装上 Harness 之后 |
| --- | --- |
| 项目知识靠人每轮临时补 | 写进 `AGENTS.md` / 规则 / wiki，按需加载，有索引可查 |
| 规范写了，智能体不读 | 出口校验：`summary.md` 字段、阶段门、`verify-*` 会指出来 |
| 门禁靠自觉，`--no-verify` 一绕就过 | git hook 真拦截；绕过会被记录并计入 `bypassRate` |
| 不知道有没有变好 | `metrics.ps1` 看纠正次数、拦截数、技能加载率的趋势 |
| 同一个错误反复犯 | `lesson_id` 第 2 次出现时，脚本直接提示晋升为规则 / 门禁 / 技能 |

一句话：**把“请你遵守规范”变成“不遵守就过不去”。**

## 为什么不是又一个 prompt 合集

1. **交付物不是 24 个 md，而是可执行的门禁和度量。** 技能模板只是原料，真正的产物是
   `pre-commit` 拦截、阶段门、字段校验、趋势复盘和卸载路径。
2. **它会明确告诉你“没做到”。** `verify-harness`、`verify-grounding`、`stage-gate`
   的输出是 PASS / FAIL / SKIP，不是“看起来不错”。
3. **它对自己执行同一套规则。** 这个仓库自带自举门禁：26 条跨文件契约 +
   行为测试 + 自己的 `pre-commit`。一个卖门禁的项目，自己不能没有门禁。

## 60 秒试一下（不用先装进项目）

```powershell
git clone https://github.com/fengyale/harness-bootstrap.git
cd harness-bootstrap
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-package.ps1
```

你会看到：

```text
[PASS] parse      19 .ps1 file(s) parse
[PASS] encoding   ASCII without BOM, or UTF-8 with BOM
[PASS] json       4 JSON file(s) parse
[PASS] structure  required files present, package-only files absent
[PASS] contract   26 rule/script/doc contract(s) hold
[PASS] smoke      install -> stage 4 -> unfilled summary rejected -> uninstall, in a temp copy

package gate: OPEN
```

那 26 条契约检查的是一件事：**同一条规则，在脚本、JSON、SKILL、AGENTS、规则文件里
是不是说同一句话。** 改一处漂五处，是这个类目最常见的失败方式。

想再看深一点：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1
```

两套行为测试会在 `%TEMP%` 建临时项目，验证真实退出码：缺行 BLOCKED、占位 SKIP、
编译 / 测试真跑、pre-commit 只查基础字段、三个 hook 安装与卸载、A3+ 伪造被拒。

## 装到你的项目

### 1. 放到技能目录

| 平台 | 位置 |
| --- | --- |
| TRAE | `.trae/skills/harness-bootstrap/` |
| Claude Code | `.claude/skills/harness-bootstrap/` |
| Codex / 无子智能体平台 | 按索引模式引用 `SKILL.md`，不复制 agents 目录 |

`tools/` 是**本包自检用**，安装时不会复制进项目。

### 2. 让智能体执行 `SKILL.md` 第 0 步

它会先探测平台和项目事实，然后走两条路径之一：

- **存量项目**：跑 `probe-project.ps1` / `probe-stack.ps1`，按证据生成 `AGENTS.md`、
  规则、技能、wiki、模块卡；
- **新项目**：先做背景 / 业务 / 选型确认，产出 `.harness/project-brief.md`，再生成骨架。

两条路径都遵守**接地协议**：项目断言必须有 E1（可跑命令）或 E2（真实文件 + 行号）证据；
只有新项目无代码阶段允许 E0（用户确认），代码落地后必须升级。

### 3. 安装门禁

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-git-hooks.ps1
```

三个 hook：

- `pre-commit`：红线扫描（只查新增行）+ SQL 评审 + summary 基础字段；
- `post-commit`：记录本次提交是否被门禁覆盖，用于计算绕过率；
- `pre-merge-commit`：合并提交也不放过。

### 4. 验收

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-harness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-grounding.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stage-gate.ps1 -Stage 7 -Feature <name>
```

`verify-*` 全绿只代表**结构对了**；A1–A4、A6 必须靠跑一个真实任务来验，
A7 需要两个 14 天窗口。

## 装好之后你会得到

```text
AGENTS.md                    唯一常驻文件（<=150 行）：技术栈 / 必跑命令 / 红线 / 索引 / 纪律
.harness/
  rules/                     编码规范、工程结构、开发流程（不可协商的边界）
  skills/                    技能正文（按需加载，由平台入口链接）
  wiki/                      领域术语、业务模型、数据模型、接口协议
  modules/                   模块卡：重点 / 难点 / 坑点 / 验证方式
  changes/<feature>/         summary.md、迁移脚本、回滚脚本
  metrics/                   gate.jsonl、promoted.txt（度量与晋升）
.trae/                       平台发现入口：skills 链接、agents、hooks
scripts/                     探测、扫描、阶段门、字段校验、度量、卸载
```

## 验收标准（A1–A7）

| # | 标准 | 怎么验 |
| --- | --- | --- |
| A1 | 先分析再动手 | 真实跑一个需求 |
| A2 | 主动加载技能 | 看它读了哪些文件 |
| A3 | 符合项目约定 | 抽查 3 条改动，至少 2 条能对应到规则条款 |
| A3+ | 该补的短板补上并说明 | `summary.md` 的「待补短板」有结论 |
| A4 | 自己跑校验并贴真实输出 | 看它有没有贴命令结果 |
| A5 | 机器门禁能拦住违规提交 | 故意造违规，提交必须被拦 |
| A6 | 人只确认关键决策 | 任务级 `corrections <= 2` 且 `impl_corrections: 0`；项目级两个 14 天窗口趋势不为 `REGRESSING` |
| A7 | 同一个错误不犯第二次 | 第 2 次才晋升；`metrics.ps1` 同一 `lesson_id` 出现 >= 2 次 |

这套标准已在一个真实存量项目上跑过安装、门禁与阶段门流程；A7 需要时间，
仓库不替你下结论。

## 平台与限制

- **Windows + Windows PowerShell 5.1**：主要支持路径，脚本与测试在这里验证。
- **pwsh 7 / macOS / Linux**：按 5.1 兼容语法编写，但路径分隔与 `chmod` 行为未逐一验证；
  欢迎按 `CONTRIBUTING.md` 补平台测试。
- **平台发现**：TRAE（`.trae/`）、Claude Code（`.claude/`）、Codex / 未知平台（索引模式）。
  没有对应目录时，不假装子智能体存在。
- **已知取舍**：红线扫描只覆盖新增行（存量违规不阻塞提交）；新项目 E0 在代码落地后
  只报 WARN 要求升级，不会自动阻止合并——第一个真实任务必须把它换成 E1/E2。

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。改动前先跑：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-package.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1
```

## License

MIT. 见 [LICENSE](LICENSE)。

---

**如果你也经历过“规则写了没人读、门禁靠自觉、同一个错误犯三次”——这个仓库值得一个 star，也值得一次试用。**
