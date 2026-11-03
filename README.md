# Agent Harness Bootstrap

**AI 编码的能力已经不是瓶颈。可预测性才是。**

> **English**: A meta-skill that installs a verifiable harness into an AI coding project —
> constraints, gates, grounding, observability and review loops. Not another prompt collection.
> [English version](README.en.md) · [中文说明](harness工程化ai编程-为什么做这件事.md)

[![package gate](https://github.com/fengyale/agent-harness-bootstrap/actions/workflows/verify.yml/badge.svg)](https://github.com/fengyale/agent-harness-bootstrap/actions/workflows/verify.yml)
[![version](https://img.shields.io/github/v/release/fengyale/agent-harness-bootstrap?display_name=tag)](https://github.com/fengyale/agent-harness-bootstrap/releases)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![powershell](https://img.shields.io/badge/powershell-5.1%20%2B%20pwsh7-blue.svg)](references/平台适配.md)
[![stars](https://img.shields.io/github/stars/fengyale/agent-harness-bootstrap?style=social)](https://github.com/fengyale/agent-harness-bootstrap/stargazers)

---

## 这解决的是哪个问题

今天的模型写代码,对绝大多数业务场景**够用了**。真正卡住团队的是另一件事:

> **你不敢把活交给它。**

因为它可能理解偏了却看起来很自信;可能漏掉项目里一条不成文的规矩;可能说"完成了",其实编译都没过。

这不是"提示词写得不够好"能解决的。想靠更好的提示词消除模型的不确定性,是**跟模型的本质对抗**。

正确做法是**不去改造内核,而是给它套一层确定性的外壳**:

```
Harness = 规则 + 执行引擎 + 闭环反馈
```

| | 只有规则 | 只有执行引擎 | 没有闭环 |
|---|---|---|---|
| 结果 | 一堆文档,没人执行 | 会跑,但不知道什么算对 | 能发现错,但没东西可改 |

三层齐了,才能把"看运气"变成"看流程"。

---

## 装上之后会怎样

| 你现在的状态 | 装上 Harness 之后 |
| --- | --- |
| 项目知识靠人每轮临时补 | 写进 `AGENTS.md` / 规则 / wiki,按需加载,有索引可查 |
| 规范写了,智能体不读 | 出口校验:`summary.md` 字段、阶段门、`verify-*` 会指出来 |
| 门禁靠自觉,`--no-verify` 一绕就过 | git hook 真拦截;绕过会被记录并计入 `bypassRate` |
| 不知道有没有变好 | `metrics.ps1` 看纠正次数、拦截数、技能加载率的趋势 |
| 同一个错误反复犯 | `lesson_id` 第 2 次出现时,脚本直接提示晋升为规则 / 门禁 / 技能 |

一句话:**把"请你遵守规范"变成"不遵守就过不去"。**

### 对团队负责人

| 你关心的 | 这套东西怎么回答 |
| --- | --- |
| **投入多大** | 冷启动只装 3–5 个技能(硬上限 8),不是 25 个全上。首次落地约 1–2 人日 |
| **风险在哪** | 存量项目第一次扫描会报几百处历史违规 → 必须"只拦新增",历史债不碰 |
| **怎么验收** | A1–A7 可判定标准;`corrections ≤ 2`、`impl_corrections = 0` 是硬指标 |
| **多久见效** | 机制当天可验(A5 造个违规提交看是否被拦);闭环 A7 需两个 14 天窗口 |
| **会不会烂掉** | 每两周复盘决定"补什么 / 升级什么 / **删什么**";技能 4 周 0 加载即列候选 |

### 对独立开发者

| 你关心的 | 这套东西怎么回答 |
| --- | --- |
| **要学多少** | 不用学框架。装完,智能体自己按流程走,你只确认业务取舍 |
| **值不值** | 判断标准只有一条:**同一个错误,会不会犯第二次** |
| **会被绑死吗** | 内容在 `.harness/`(你的),入口在平台目录(可重建)。换工具只改链接 |
| **不加约束行不行** | 行,但你就要一直盯着。**可预测性**是要花力气买的,买一次管很久 |

---

## 60 秒试一下(不用先装进项目)

```powershell
git clone https://github.com/fengyale/agent-harness-bootstrap.git
cd agent-harness-bootstrap
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-package.ps1
```

你会看到:

```text
[PASS] parse      19 .ps1 file(s) parse
[PASS] encoding   ASCII without BOM, or UTF-8 with BOM
[PASS] json       4 JSON file(s) parse
[PASS] structure  required files present, package-only files absent
[PASS] contract   26 rule/script/doc contract(s) hold
[PASS] smoke      install -> stage 4 -> unfilled summary rejected -> uninstall, in a temp copy

package gate: OPEN
```

那 26 条契约检查的是一件事:**同一条规则,在脚本、JSON、SKILL、AGENTS、规则文件里
是不是说同一句话。** 改一处漂五处,是这个类目最常见的失败方式。

想再看深一点:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1
```

两套行为测试会在 `%TEMP%` 建临时项目,验证真实退出码:缺行 BLOCKED、占位 SKIP、
编译 / 测试真跑、pre-commit 只查基础字段、三个 hook 安装与卸载、A3+ 伪造被拒。

---

## 装到你的项目

### 1. 放到技能目录

| 平台 | 位置 |
| --- | --- |
| TRAE | `.trae/skills/harness-bootstrap/` |
| Claude Code | `.claude/skills/harness-bootstrap/` |
| Codex / 无子智能体平台 | 按索引模式引用 `SKILL.md`,不复制 agents 目录 |

`tools/` 是**本包自检用**,安装时不会复制进项目。

### 2. 让智能体执行 `SKILL.md` 第 0 步

它会先探测平台和项目事实,然后走两条路径之一:

- **存量项目**:跑 `probe-project.ps1` / `probe-stack.ps1`,按证据生成 `AGENTS.md`、
  规则、技能、wiki、模块卡;
- **新项目**:先做背景 / 业务 / 选型确认,产出 `.harness/project-brief.md`,再生成骨架。

两条路径都遵守**接地协议**:项目断言必须有 E1(可跑命令)或 E2(真实文件 + 行号)证据;
只有新项目无代码阶段允许 E0(用户确认),代码落地后必须升级。

### 3. 安装门禁

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-git-hooks.ps1
```

三个 hook:

- `pre-commit`:红线扫描(只查新增行)+ SQL 评审 + summary 基础字段;
- `post-commit`:记录本次提交是否被门禁覆盖,用于计算绕过率;
- `pre-merge-commit`:合并提交也不放过。

### 4. 验收

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-harness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-grounding.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stage-gate.ps1 -Stage 7 -Feature <name>
```

`verify-*` 全绿只代表**结构对了**;A1–A4、A6 必须靠跑一个真实任务来验,
A7 需要两个 14 天窗口。

---

## 装好之后你会得到

```text
AGENTS.md                    唯一常驻文件(<=150 行):技术栈 / 必跑命令 / 红线 / 索引 / 纪律
.harness/
  rules/                     编码规范、工程结构、开发流程(不可协商的边界)
  skills/                    技能正文(按需加载,由平台入口链接)
  wiki/                      领域术语、业务模型、数据模型、接口协议
  modules/                   模块卡:重点 / 难点 / 坑点 / 验证方式
  changes/<feature>/         summary.md、迁移脚本、回滚脚本
  metrics/                   gate.jsonl、promoted.txt(度量与晋升)
.trae/                       平台发现入口:skills 链接、agents、hooks
scripts/                     探测、扫描、阶段门、字段校验、度量、卸载
```

---

## 验收标准(A1–A7)

| # | 标准 | 怎么验 |
| --- | --- | --- |
| A1 | 先分析再动手 | 真实跑一个需求 |
| A2 | 主动加载技能 | 看它读了哪些文件 |
| A3 | 符合项目约定 | 抽查 3 条改动,至少 2 条能对应到规则条款 |
| A3+ | 该补的短板补上并说明 | `summary.md` 的「待补短板」有结论 |
| A4 | 自己跑校验并贴真实输出 | 看它有没有贴命令结果 |
| A5 | 机器门禁能拦住违规提交 | 故意造违规,提交必须被拦 |
| A6 | 人只确认关键决策 | 任务级 `corrections <= 2` 且 `impl_corrections: 0`;项目级两个 14 天窗口趋势不为 `REGRESSING` |
| A7 | 同一个错误不犯第二次 | 第 2 次才晋升;`metrics.ps1` 同一 `lesson_id` 出现 >= 2 次 |

这套标准已在一个真实存量项目上跑过安装、门禁与阶段门流程;A7 需要时间,
仓库不替你下结论。

---

## 为什么不是又一个 prompt 合集

1. **交付物不是 24 个 md,而是可执行的门禁和度量。** 技能模板只是原料,真正的产物是
   `pre-commit` 拦截、阶段门、字段校验、趋势复盘和卸载路径。
2. **它会明确告诉你"没做到"。** `verify-harness`、`verify-grounding`、`stage-gate`
   的输出是 PASS / FAIL / SKIP,不是"看起来不错"。
3. **它对自己执行同一套规则。** 这个仓库自带自举门禁:26 条跨文件契约 +
   行为测试 + 自己的 `pre-commit`。一个卖门禁的项目,自己不能没有门禁。

---

## 平台与限制

- **Windows + Windows PowerShell 5.1**:主要支持路径,脚本与测试在这里验证。
- **pwsh 7 / macOS / Linux**:按 5.1 兼容语法编写,但路径分隔与 `chmod` 行为未逐一验证;
  门禁层(`red-line-scan.py`)跨 OS,体检层未适配。详见
  [平台适配](references/平台适配.md)。
- **平台发现**:TRAE(`.trae/`)、Claude Code(`.claude/`)、Codex / 未知平台(索引模式)。
  没有对应目录时,不假装子智能体存在。
- **已知取舍**:红线扫描只覆盖新增行(存量违规不阻塞提交);新项目 E0 在代码落地后
  只报 WARN 要求升级,不会自动阻止合并——第一个真实任务必须把它换成 E1/E2。

---

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。改动前先跑:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-package.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1
```

## License

MIT. 见 [LICENSE](LICENSE).

---

**如果你也经历过"规则写了没人读、门禁靠自觉、同一个错误犯三次"——这个仓库值得一个 star。**
