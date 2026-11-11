---
name: harness-bootstrap
description: AI 编码 Harness 化元技能：搭框架、沉淀、技能体检、调触发词、复盘、维护。当用户说"搭 harness""规范 AI 编码""建规则体系""沉淀一下""技能体检""复盘""该触发不触发""怎么维护"时使用。
---

# Harness Bootstrap —— 元技能

> **你不是在复制一套模板。你是在为一个具体项目，从零设计它自己的 AI 编码框架。**
> `templates/` 是**参考样本**，不是要铺进去的东西。多数情况下应该改写、裁剪、重建。
>
> **运行时 vs 包源**：安装后日常任务只读项目 `AGENTS.md`、`.harness/wiki`、`.harness/rules`、
> `.harness/modules`、`.harness/skills`、`.harness/project-brief.md`；`templates/` 只在安装、升级、
> 自建技能/模块/适配器时读，**不能当项目事实**。默认**项目级安装**（每个项目独立，不跨项目串文件）；
> 日常任务不读 `templates/`；`probe-stack` / `red-line-scan` 已排除 `.trae`。
> `.harness/upgrade/` 只用于升级回滚；验证通过后默认删除，日常任务不读。

---

## 第零部分：基调

> **基调**（我们在做什么、为什么现在不行）见 `references\核心论述.md`「基调」。一句话：把 AI 编码从「看运气」变成「看流程」。

### 0.1 我们在做的是什么

**把 AI 编程"工程化 / 自动化 / 流水化"。**

不是让 AI 更会聊天，是让它像一条**受控产线**：
需求进 → 分析 → 设计 → 编码 → 测试 → 评审 → 部署，
每一步有明确输入、有判定标准、有产出物、过不了就停下。

**这件事的意义**：AI 编码的能力已经不是瓶颈，**可预测性才是**。
同一个需求，今天写得好、明天写得歪，人工就得一直盯着——那不叫工程化。
Harness 就是把"看运气"变成"看流程"。

### 0.2 这个立场意味着什么（三条推论）

**推论一：能自动化的，绝不留给人工。**
凡是"每次都要人提醒一遍"的动作，都是没做完的地方——要么写进规则，要么做成门禁。

**推论二：能机器判定的，绝不靠自觉。**
"注意别用浮点算金额"是口号；"扫到浮点数就红"是机制。
**宁可少写三条规范，也要把一条做成门禁。**

**推论三：框架要替你进步，不是替你重复。**
这不是"把现有做法抄一遍存档"。发现项目里有明显短板（该加缓存的地方没加、
该有索引的地方没建、该幂等的地方没做），**在合适的时机补上**，并把这条经验沉淀成资产。
> 详见 1.6「守约定 vs 补短板」。

### 0.3 你自己要有的态度

**你是这个框架的设计者和推行者，不是命令的执行器。**

- **有判断**：模板跟项目对不上，就按 `references/自建指南.md` 重新设计，不要硬套
- **有担当**：看到项目里明显该改而不敢改的东西，**提出来并给方案**，而不是绕过去
- **守底线**：无论如何，**0.1 说的"受控、可判定、能自动"不能丢**——
  可以换技术栈、换目录结构、换技能清单，但**不能让产出重新变成"看运气"**

> 一句话：**方法可以变，目标不能变。**

---

## 第一部分：你要达成什么（先读这一部分，它决定你后面所有判断）

### 1.1 唯一目的

**让这个项目的 AI 编码，从"用户反复纠正"变成"派活就走"。**

用户要的效果是具体的：

> 提一个需求 → 智能体自己分析、自己拆解、自己实现、自己验证 → 交出来的东西基本可用，
> **用户不需要一轮一轮纠正、检查、来回打太极。**

不是"文档齐全"，不是"目录结构漂亮"，不是"跑通了自检脚本"。
**那些都只是手段。判断标准只有一个：用户的干预次数有没有降下来。**

### 1.2 为什么现在不行（病根）

> 病根分析见 `references\核心论述.md`「为什么现在不行」。

### 1.3 达成标志（**验收标准，必须逐条自问**）

搭完之后，下面每条都应该能回答"是"：

| # | 验收项 | 怎么验证 |
| --- | --- | --- |
| A1 | 丢一个新需求进去，它会**先分析再动手**（产出 `summary.md`），而不是直接开始写代码 | 真实跑一次 |
| A2 | 它写代码时会**主动加载对应的技能**，而不是凭通用知识写 | 观察它读了哪些文件 |
| A3 | 产出**符合本项目约定**（分层、命名、异常、缓存 Key 等），不是"正确的通用写法" | 抽查 3 条改动，≥2 条能对应到 `.harness/rules/` 的具体条款 |
| A3+ | **该补的短板补上了**：约定之外明显缺失的能力（该缓存没缓存、该索引没索引、该幂等没幂等）**在合适场景中补上并说明**，而不是"以前没有，现在也不加" | `summary.md` 的「待补短板」至少 1 条并写明原因（"无"也算结论） |
| A4 | 它**自己会跑校验**（编译、红线扫描），不通过不会说"完成" | 看它有没有贴真实输出 |
| A5 | 有一道**机器门禁**能拦住违规提交——不靠它自觉 | 故意造违规 → 提交被拦 |
| A6 | 用户只需要**确认关键决策**（业务规则、红线取舍），不需要盯实现细节 | **两层都成立**：① 任务级 `summary.md` 的 `corrections:` ≤ 2，且 `impl_corrections: 0`；② 项目级 `metrics.ps1 -Days 14 -Compare` 比较**两个连续 14 天窗口**，趋势不为 `REGRESSING`（需要 ≥28 天历史，不足时为 `INSUFFICIENT DATA`） |
| **A7** | **闭环成立**：同一个错误不会犯第二次。第 1 次只记 `lesson_id`，**第 2 次才晋升**（规则 / 门禁 / 技能） | 过两周回看：同类错误还犯不犯；`metrics.ps1` 里同一 `lesson_id` 是否 ≥2 次 |

> **A6 是跷跷板，不是单边指标**：人纠正次数下降，必须伴随机器拦截次数存在。\
> 只有"人纠正少了"而 `blocked` 一直是 0，通常是门禁没装或已被绕过（看 `bypassRate`）。
> 单看一次任务不能下结论——用 `-Compare` 看趋势。

> **A1–A7（含 A3+）全过才算搭成。只跑通 `verify-harness.ps1` 只是"结构对了"，不等于"效果到了"。**
> 自检脚本负责 A5 的机制部分；A1–A4、A6 只能靠**跑一个真实任务**来验证；
> **A7 需要时间——它验证的不是"搭好了"，而是"能不能自己变好"**（见 1.4④）。
> **A3 守约定，A3+ 补短板**——两者都要，分界线见 1.6。

### 1.4 四条不可动摇的核心思想

> 四条核心思想的完整论述见 `references\核心论述.md`「四条核心思想」。

### 1.5 你（智能体）的角色定位

**你是给这个项目做"AI 编码框架设计"的人，不是来复制文件的。**

- `templates/` 里的每一个文件，你都要问：**"这个项目需要它吗？需要的话，应该长什么样？"**
- 凑巧适用（比如 `03-redis-cache` 的结构、`verify-harness` 的检查项）→ 直接用或小改
- 不适用（多数情况）→ **按这个项目重建**，参考它的**结构**，但内容必须是这个项目的
- 项目的技术栈、目录、术语、红线**只能来自真实代码**，不能来自模板
### 1.6 守约定 vs 补短板（**A3 和 A3+ 的分界，最容易走偏**）

> 守约定 vs 补短板的完整判据见 `references\核心论述.md`「守约定 vs 补短板」。

## 第二部分：怎么做

### 2.1 六种请求，六种做法

用户可能说下面任何一句，**先判断属于哪一种，不要混着做**：

| 用户说什么 | 这是哪种请求 | 你要做什么 |
| --- | --- | --- |
| "搭 harness""规范 AI 编码""建规则体系" | **从零自建** | 走完 2.2 全部步骤 |
| "沉淀一下""记住这次教训" | **沉淀** | 只读 `references/维护与体检.md` 第一节，提炼一条 |
| "做一次技能体检""技能太多了" | **体检** | 只读 `references/维护与体检.md` 第二节 |
| "该触发不触发""调触发词" | **调优** | 只读 `references/维护与体检.md` 第三节 |
| "复盘""这两周有没有用""A7 怎么样" | **两周复盘** | 只读 `references/两周复盘.md`（这是验 A7 的唯一方式） |
| "加一条红线""补一个技能" | **增量** | 只做那一个小动作，不要重跑全程 |
| "升级 harness""更新到新版" | **升级** | 只跑 `scripts\update-harness.ps1 -PackagePath <新包>`：先不加 `-Apply` 看差异，确认后 `-Apply`；脚本替换、`AGENTS.md`/`harness-required.json` 只自动合并已知行/键；要同步已装技能正文再加 `-UpdateSkills`；不要重跑第 0 步 |

> **只有第一种需要跑完整流程**——其余都是小操作，把它们做成大工程是最常见的误判。
>
> **选不准手段时**（该写成规则、做成技能，还是上 fail-closed 门禁？）先读
> `references/落地策略.md` 第三节「干预矩阵」：按 **频率 × 代价 × 可机器判定性** 选，选错手段等于白写。

### 2.2 从零自建：流程

> **先分路径，再动手：**
> - **存量加固**：仓库里已有业务代码 → 从第 0 步直接往下走，证据来自 E1/E2。
> - **新项目初始化**：仓库里还没有代码（或只有脚手架）→ **先读 `references/新项目初始化.md`**，
>   走完五轮确认并产出 `.harness/project-brief.md`，再回到第 0 步落核心。
>   这个阶段只有 E0（用户确认）证据，代码落地后必须逐条升级为 E1/E2。
>
> 两条路径共用同一套资产结构和同一套验收标准（A1–A7），区别只在**证据从哪来**。

#### 第 0 步 · 探测平台 + 把核心落到项目里（**只复制，不改内容**）

两件事，顺序不能反（完整契约见 `references/平台适配.md`）：

**1) 探测平台（只读）**：看仓库根有没有 `.trae/` `.claude/` `.codex/` `.codebuddy/` `.cursor/`，
以及已有的 `AGENTS.md` / `CLAUDE.md` / `.cursorrules`。
**探测不到就问用户一次**；仍不确定就按"未知平台"处理（走索引模式，见第 3 步）。

**2) 落核心 + 写常驻入口**（平台无关的部分先落，入口只建一种）：

```powershell
# $PKG = 本技能包根目录
# 重要：Copy-Item 默认会静默覆盖同名文件（-Force 只影响只读/隐藏），单靠"不加 -Force"
# 挡不住覆盖。这里用 Copy-Missing：只复制不存在的文件，已存在的列成冲突清单，
# 按 3.2 读后合并——绝不覆盖用户已有的 scripts\ / .harness\ / AGENTS.md。
function Copy-Missing([string]$Src, [string]$DstDir) {
    Get-ChildItem -LiteralPath $Src -Recurse -File -Force | ForEach-Object {
        $rel    = $_.FullName.Substring($Src.Length).TrimStart('\')
        $target = Join-Path $DstDir $rel
        if (Test-Path -LiteralPath $target) { Write-Host "[SKIP] conflict: $target" }
        else {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $target
        }
    }
}

Copy-Missing "$PKG\templates\scripts"          "<项目根>\scripts"
Copy-Missing "$PKG\templates\.harness\rules"   "<项目根>\.harness\rules"
Copy-Missing "$PKG\templates\.harness\wiki"    "<项目根>\.harness\wiki"
Copy-Missing "$PKG\templates\.harness\modules" "<项目根>\.harness\modules"
Copy-Missing "$PKG\templates\.harness\changes" "<项目根>\.harness\changes"

# 已晋升清单是单个 tracked 文件，Copy-Missing 只接目录，这里单独补。
$promotedFile = "<项目根>\.harness\lessons-promoted.txt"
if (-not (Test-Path -LiteralPath $promotedFile)) {
    Copy-Item "$PKG\templates\.harness\lessons-promoted.txt" $promotedFile
}

# 技能只落索引；25 个技能模板带 <!-- slot: --> 未填，整目录复制会让
# verify-grounding 全部 FAIL，也违背「首轮只建 3–5 个」。技能在第 2 步按启用集编译。
$skillsReadme = "<项目根>\.harness\skills\README.md"
if (Test-Path -LiteralPath $skillsReadme) { Write-Host "[SKIP] conflict: $skillsReadme" }
else {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $skillsReadme) | Out-Null
    Copy-Item "$PKG\templates\.harness\skills\README.md" $skillsReadme
}

# 平台子智能体定义（评审 / 一致性校验 / 红线审计）：有 agents 目录的平台才装。
# 按第 1) 步的探测结果选目标目录，三个分支只走一个：
#   TRAE         -> $AgentDir = "<项目根>\.trae\agents"
#   Claude Code  -> $AgentDir = "<项目根>\.claude\agents"
#   Codex / 未知 -> 不执行本行（走清单模式，别假装子智能体存在）
Copy-Missing "$PKG\templates\.trae\agents" $AgentDir

# .gitignore：模板里有 .harness/metrics/（门禁日志每次提交都追加，不忽略会让工作区恒 dirty）
# 项目已有 .gitignore 时不要覆盖，把缺的那几行读后手工补上，并列进冲突清单
$ignore = "<项目根>\.gitignore"
if (Test-Path -LiteralPath $ignore) { Write-Host "[SKIP] conflict: $ignore (merge the lines listed in templates\.gitignore by hand)" }
else { Copy-Item "$PKG\templates\.gitignore" $ignore }

# 版本标记：升级脚本靠它判断当前装的是哪一版。首次安装就写入，别等升级时再补。
$marker = "<项目根>\.harness\.installed-version"
if (-not (Test-Path -LiteralPath $marker)) {
    $ver = (Get-Content -LiteralPath "$PKG\VERSION" -TotalCount 1) -replace '^.*VERSION\s+', ''
    Set-Content -LiteralPath $marker -Value $ver -Encoding ASCII
}

# 平台入口：只建与探测结果对应的一种（同样先判存在，已存在就 SKIP 并按 3.2 合并）
# TRAE / Codex / 未知 -> AGENTS.md；Claude Code -> CLAUDE.md
```

- **不要复制全部平台目录**：是哪个平台就建哪个入口，其余一律不建
- `scripts\` / `.harness\` **可能已存在**：输出里的每一条 `[SKIP] conflict` 都要**逐条列给用户**，按 3.2 冲突策略**读后合并，不覆盖**；忽略 SKIP 等于默默丢掉已有规则
- **agents 目录同理**：`.trae\agents` 已存在就 SKIP 并读后合并；Claude 项目改拷到 `.claude\agents`；
  Codex / 未知平台不装，按清单模式手工评审（不要假装子智能体存在）
- **技能模板不进项目**：`.harness\skills\<分类>\<技能>\` 在第 2 步由启用集编译生成；
  第 0 步只复制 `skills\README.md` 索引。需要骨架时从 `$PKG\templates\.harness\skills\<分类>\<技能>\SKILL.md` 读取后改写
- 后面所有命令都假设 `scripts\` 在项目根；跳过这一步，下一步会直接失败

#### 第 0.5 步 · 先看这个项目是什么样（**只读，不许动任何文件**）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-project.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-stack.ps1
```

产出 `baseline\baseline.md` / `baseline.json`（项目骨架）与 `.harness\stack.json`（能力栈：orm / cache / mq / test / frontend）。
**stack.json 是技能编译的输入**——没有它，就无法判断一个技能里写的技术本项目到底有没有。

> **探测结果只是证据来源，不是结论。** 写进规则/技能的每条项目专属内容，都要带 `- [E1]` / `- [E2]` 锚点——
> 格式与拒绝条件见 `references/接地协议.md`。无证据的内容只能写 `TODO(待确认)`。
>
> **新项目**：`baseline.json` 的 `srcRoots` / `testRoots` 为空是正常的，不要因此判成"项目坏了"。
> 此时事实来源是 `.harness/project-brief.md`；命令一律标「待实测」，脚手架第一次跑通就改回实测值。

**脚本只给你骨架事实，下面这些必须你自己查：**

1. **实测命令**——编译、跑全部测试、跑单个测试、lint、本地启动。每条**真的执行一次**，贴真实输出。跑不了的写清原因。
   **命令不许猜。** 猜出来的命令写进 `AGENTS.md` 会天天坑人。
2. **真实的分层与目录**——不是理想结构，是现在这个样子。
3. **既有惯例**——从真实代码里举 3 个带路径的例子（怎么抛异常、怎么建缓存 Key、Controller 怎么写）。
4. **最容易反复犯错的点**——凭代码迹象判断，不要凭想象。
5. **冲突清单**——已有的 `AGENTS.md` / `CLAUDE.md` / `.trae/agents/` / `scripts/` 同名文件 / 已有技能。

**做完停下来汇报**：项目是什么、命令是什么、有哪些冲突、你打算建什么。**等确认再动手。**

#### 第 1 步 · 确认两件事（**缺一件都不能往下走**）

1. **工作区可回滚吗？** 跑 `git status`。
   - 不干净 → 让用户提交 / 暂存 / 你帮他 `git stash`，等他决定
   - 不是 git 仓库 → 明确告诉用户"本次改动没有回滚手段"，建议先 `git init`
   - **理由**：合并策略只是指令，`git` 才是机制。改错了要能一键还原。

2. **这个项目该启用哪些技能？** 按 `references/落地策略.md` 的默认启用集：
   - **必上 3 个**：`request-analysis`、`coding-skill`、`expert-reviewer`
   - **按需 1–2 个**：从 `biz-dev/` 挑这个项目**最高频**的专题
   - **其余先不建**——技能清单每轮占上下文。同一条纠正出现第 2 次，再加一个。

**逐文件列出三类清单，等确认**（不要只说大概）：

| 类别 | 说明 |
| --- | --- |
| **新建** | 逐个列路径 + 用途 |
| **改写** | 参考模板但内容要重建的，写清"改什么、为什么" |
| **跳过** | 已存在且不该动的，写清理由 |

#### 第 2 步 · 生成（**内容跟着项目走，不是跟着模板走**）

| 生成什么 | 内容来源 | 关键要求 |
| --- | --- | --- |
| `.harness/project-brief.md` | **仅新项目**：`references/新项目初始化.md` 的五轮确认结论 | 记录确认人、确认日期、非目标与未决项；它是新项目模式（E0 合法）的判定标志 |
| `AGENTS.md` | 探测到的技术栈 + **实测命令** + 挑选后的红线 + **实际启用的技能** | ≤150 行；**只放每轮必须**：技术栈 / 命令 / 红线 / 索引 / 纪律。项目知识→`wiki/`，检查清单与流程→`rules/`，做法→`skills/`；禁止在常驻层重复 |
| `rules/编码规范.md` | 项目既有惯例（从代码提取） | 保留 🔴/🟡 图例；每条约定都要是这个项目的 |
| `rules/工程结构.md` | **真实目录树** | 目录树照抄；禁止写"理想结构" |
| `rules/开发流程规范.md` | 十阶段（按项目裁剪）+ 质量门 | 质量门必须可判定 |
| `rules/缓存与一致性.md` / `消息与异步.md` / `数据迁移与回滚.md` | 项目是否真有缓存 / MQ / 数据库 | 三项都是通用判据，**没有对应能力就整份删除**，不要留下用不到的规则 |
| `wiki/*` 四份 | **从真实代码提取** | 保留「权威来源声明」；提取不到标 `TODO(待确认)` |
| `skills/*`（**仅启用集**） | **编译**，不是复制：骨架来自模板，绑定来自 `stack.json` + 代码证据（见 `references/技能编译协议.md`） | 目标 ≤80 行，硬上限 120 行；正文不得出现本项目没有的技术；`description` 同步改写，不写技术栈名 |
| `.trae/agents/*` | 按实际红线调整 | 只新增，不覆盖已有 |
| `scripts/red-line-rules.json` | 从 `references/红线候选池.md` **挑 5–8 条** | 每条 pattern 先手工试跑，确认不误报 |
| `rules/SQL评审规范.md` + `skills/*/sql-review` | **仅当项目有数据库访问** | 方言、执行计划方式、大表 / 索引现状；没有数据库的项目整条跳过 |

**五条硬规矩：**

- **目录树、包名、类名、表名、字段名、接口路径**——只能来自真实代码，**不许编造**
- 不确定的标 `TODO(待确认)`，**不要用听起来合理的猜测填空**（看起来完整比缺着更危险）
- **规则只定义边界，不展开做法**；做法交给技能，不要重复
- 技能之间的 `description` 触发词**不能重叠**
- **每条项目专属结论必须带证据锚点**（`- [E1]` 可跑命令 / `- [E2]` 真实文件+行号）；
  拿不出 E1/E2 的，写进 `TODO(待确认)`，**不写进正文**——见 `references/接地协议.md`
- **新项目无代码阶段**：项目结论用 `- [E0] confirm:<确认人> <YYYY-MM-DD> :: <确认了什么>`；
  **代码落地后逐条升级为 E1/E2**。非新项目模式下出现 E0，`verify-grounding.ps1` 直接判 FAIL

#### 第 3 步 · 建技能发现入口（**按平台选一种，不要全建**）

| 平台能力 | 做法 |
| --- | --- |
| 有自动发现目录（TRAE / Claude Code） | 在平台目录建链接：TRAE `-Dest .trae\skills`（默认）、Claude `-Dest .claude\skills` |
| 没有自动发现（Codex / CodeBuddy / 未知） | 用 `templates\adapters\generic\HARNESS-INDEX.md` 生成 `.harness\skills\INDEX.md`，并把"某类任务必须先读哪个技能"写进常驻文件 |

```powershell
# 有自动发现目录时
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-links.ps1 -Dest .trae\skills
```

**环境不允许执行命令**就把命令列给用户手工执行；非 Windows 用 `ln -s` 等价替换。
没有发现入口又没索引 → 技能等于不存在，后面所有"按技能干活"都是空话。

#### 第 4 步 · 装门禁（**存量项目必须"只拦新增"**）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-git-hooks.ps1
```

**存量项目先按 `references/落地策略.md` 的"只拦新增"模式**。
否则第一次扫描报出几百处历史违规 → 用户崩溃 → 关掉门禁 → 整套废掉。
**这是这套东西最常见的死法。**

**SQL 评审门禁随 hook 一起安装**（`scripts/sql-review-gate.ps1` / `.py`）：diff 新增行含 SQL 时，要求
`.harness/changes` 下有 `sql_review:` 结论（≥4 字符）。查找顺序：**本次提交携带的 summary → `HARNESS_TASK` →
磁盘上最新的 summary**（第三条会打印实际用的路径）。**summary 不必随提交携带**；缺字段时自动追加一行
`- sql_review: TODO(...)` 占位，但仍拒绝提交直到 TODO 被替换为真实结论（表 / 预估行数 / 访问路径）。
只检 `.java/.sql/.xml/.kt/.py/.js/.ts/.vue/.cs`，排除门禁脚本自身与 `.md`；`select *` / `not in` / 前导 `%` 只提示。
**没有数据库的项目**：在**同一次提交**里把 `scripts/harness-required.json` 的 `sqlGate` 设为 `false`，并删除 `.harness/rules/SQL评审规范.md`、`sql-review` 技能与 `sql-review-gate.*`；分两次提交会被 hook 拦下（先设 false 但残留，或先删但配置仍为 true）。只删文件不改 `sqlGate` 会被 `verify-harness` 判 FAIL（配置与产物不一致）。
**`sqlGate=true`（新装默认）**：规则与 gate 必须同时存在且可运行；只删一侧会被 hook 或 `verify-harness` 第 13 项拦下，第 13 项还会用 empty-diff + positive probe 验证 gate 真的能跑、且会在“有 SQL 无 summary”时拒绝。

#### 第 5 步 · 自检（**跑脚本，不要自述**）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-harness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-grounding.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\agents-delta.ps1
```

要求**三个脚本都 0 FAIL**，把真实输出贴给用户。
`verify-harness` 查结构（含常驻文件五块是否齐全、是否空心、有无模板占位符），
`verify-grounding` 查"技能里写的路径/证据是不是真的"，`agents-delta` 查重装差异。

阶段门（**手动跑，不接 hook**——它要跑编译和测试，接进提交会拖慢每次 commit）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stage-gate.ps1 -Stage 7 -Feature <name>
```

- 阶段定义与项目十阶段一致（1 需求 / 2 方案 / 3 编码 / 4 静态检查 / 5 测试 / 6 评审 / 7 合并 / 8 部署 / 9 验证 / 10 沉淀）
- `red-lines` 判据读 `.harness\metrics\gate.jsonl` 的最近一次扫描，**不跑全量扫描**（存量违规会让门永远 BLOCKED）
- AUTO 条件机器判定；编译 / 测试判据会**真跑 `AGENTS.md` 必跑命令表里的那条命令**（行内仍是占位符或写了「待实测 / 不适用」→ `[SKIP]`，不阻断；**整行缺失 → BLOCKED**）；HUMAN 条件只报告、不阻塞；无状态，从盘上重算
- `Gate result: BLOCKED` 时 exit 1；**L2 / L3 合并前跑 Stage 7**
- **真正的自动门禁是 pre-commit 红线扫描 + SQL 评审**（第 4 步装的）；阶段门是交付前的自查

但它只验证**结构**——**A1–A4、A6 必须靠跑一个真实任务来验**（见 1.3）。

#### 第 6 步 · 交付时**必须说清五件事**

1. **哪些是 A/B/C 级**（见 `references/质量分级.md`）——不许笼统说"全部完成"
2. **A1–A7（含 A3+）里哪些已验证、哪些还没验**（跑了真实任务没有？A7 要过一段时间才验得了）
3. **本次发现的短板**（即使没动手）：哪些过了闸门做了、哪些只提议、依据是什么（见 1.6）
4. **本轮新建的技能不会立即生效**——要重启工具或开新对话
5. **需要用户做什么**：开 AGENTS.md 开关、重启、验证触发、门禁自查
6. **贴出 `scripts\metrics.ps1` 的当前数字**（tasks / corrections / blocked）——这是 A7 的起点数据，不是可选

### 2.3 自成长机制（**框架不是装完就结束，它必须自己长**）

> 自成长节律见 `references\维护与体检.md`（沉淀 / 体检 / 调优）与 `references\两周复盘.md`。

### 2.4 升级已有项目（**不是重装**）

第 0 步是 Copy-Missing，重跑不会更新旧脚本。升级走独立入口：

```powershell
# 先看差异，不改任何文件
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\update-harness.ps1 `
  -PackagePath <新包根目录>

# 确认后执行：备份旧脚本、写版本标记、重装 hook、跑 verify-harness
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\update-harness.ps1 `
  -PackagePath <新包根目录> -Apply
```

更新边界：

- `scripts\*.ps1` / `*.py`（机制）：替换，旧文件先备份到 `.harness\upgrade\<时间戳>\`
- `scripts\*.json`（项目配置）：**不覆盖**；`harness-required.json` 只自动合并已知键（`required` / `requiredAnyOf` / `sqlGate`），其余键保留，`-NoMergeKnown` 退回只打印差异
- `.harness\rules|wiki|modules`：只补缺失文件；有差异的项目文件标 MANUAL（红线汇总只替换 R5/R6 的脚本检查格，规则名和其余内容保留）
- `.harness\skills`：README 是项目索引，有差异只标 MANUAL；**已装技能正文**默认标 MANUAL；`-UpdateSkills` 只替换仍含 `slot:` 的未编译副本，已编译技能保持 MANUAL（`-ForceSkills` 才强制覆盖，但它会把技能重置为骨架，需重新编译后再跑 `verify-harness.ps1`，重置步骤用 `-SkipVerify`）；未安装的模板技能不会补装
- `AGENTS.md`、平台 agents：`AGENTS.md` 只自动合并已知框架行（扫描命令、R5/R6、summary 分工、SQL 评审、lesson_id、源码归因），其余行保留；平台 agents 只报告差异
- `.harness\changes|metrics`：L2/L3 历史**永不触碰**；旧 L1 summary 目录 COMPACT 到升级备份（验证后随备份删除，`-KeepL1` 保留）；`_small.md` 缺失时才补模板；`_template` 视为包资产，有新版会替换并备份；`lessons.md` / `lessons-promoted.txt` 从旧 `metrics\` 迁移一次
- `.gitignore` 只追加缺的 `.harness/metrics/` 与 `.harness/upgrade/` 两行，不重写用户文件
- 验证通过后**默认删除** `.harness\upgrade\<时间戳>` 备份，审计写进 `.harness\.installed-version`；需要回滚点加 `-KeepBackup`，清理旧备份加 `-PruneBackups`
- 首次安装会写 `.harness\.installed-version`；老项目没有也能升级，脚本会从技能目录的 `VERSION` 推断旧版本

升级后先跑阶段 3/5/7/10：新的编译/测试判据会真跑 `AGENTS.md` 的命令。缺行 BLOCKED、占位 SKIP，这是机制在生效，不是回归。

## 第三部分：约束与坑

### 3.1 硬约束（违反即重做）

1. **不许编造**：命令、路径、表名、字段名、接口路径、业务规则，一律以真实项目为准
2. 不确定的标 `TODO(待确认)`，不要用猜测填空
3. 常驻文件必须**薄**；厚内容一律下沉成技能
4. 规则只定义**边界**，做法交给技能，**不要重复展开**
5. 技能名**全局唯一**（平台只扫一层目录）
6. 能机器判定的规则，**不要只写进文档**，要同时给脚本或门禁
7. **Windows 脚本必须纯 ASCII**（PS 5.1 编码坑，见下）
8. **改任何已存在文件之前，工作区必须可回滚**——合并策略只是指令，`git` 才是机制
9. **绝不覆盖**：默认动作永远是"读 → 合并 → 报告"；只有用户对**具体那一个文件**说"覆盖"才允许
10. **技能可以缺，检查不能缺**——没装某技能时，用 `开发流程规范.md` 的降级表手工替代，并在交付时说明
11. **补短板必须过 1.6 的四道闸门**，并且**必须留痕 + 当面说明**；
    没过闸门的，只能提议不能动手
12. **不许默默改**：任何超出本次需求的改动，都要在 `summary.md` 写清并主动告知用户，给"要不要回退"的选择

### 3.2 冲突与合并策略

> 冲突与合并策略见 `references\核心论述.md`「冲突与合并策略」。

### 3.3 本机环境坑（都是实测踩出来的）

> 本机环境坑见 `references\核心论述.md`「本机环境坑」。

## 第四部分：去哪找细节

| 你要做的事 | 读哪份 |
| --- | --- |
| **理解立场与方法论**（基调、为什么现在不行、四条核心思想、自成长） | `references/核心论述.md` |
| **判断一条内容能不能写进技能**（E0–E4 证据锚点、拒绝条件） | `references/接地协议.md` |
| **从模板编译一个技能**（四动作、栈绑定、行数预算） | `references/技能编译协议.md` |
| **模板不适用、要从零设计这个项目的框架时** | **`references/自建指南.md`** ← 这是元技能的核心方法 |
| **仓库里还没有代码，要做新项目初始化** | **`references/新项目初始化.md`** ← 五轮确认 + `.harness/project-brief.md` + E0 |
| **落地后第 14 天：验 A7 有没有成立** | **`references/两周复盘.md`** ← 唯一能验闭环的方式 |
| **动手前必读**：默认启用集、存量项目渐进路径、首周节奏、增量入口 | `references/落地策略.md` |
| 判断哪个文件能直接用、哪个必须现场补（交付时要按它说明） | `references/质量分级.md` |
| 挑红线（按技术栈分组的候选 + 检查动作） | `references/红线候选池.md` |
| 写 `SKILL.md` / 写红线 / 调 description | `references/规则与技能写法.md` |
| 沉淀技能、技能体检、触发调优、维护周期 | `references/维护与体检.md` |
| **某条经验要不要回灌进模板（两个项目都踩过才允许）** | `references/回灌协议.md` |
| 解释"为什么分两处放""三层约束力" | `references/架构与职责.md` |
| 平台入口怎么建、技能怎么被发现（TRAE / Claude / 通用索引） | `references/平台适配.md` |
| 遇到平台行为不符预期 | `references/踩坑清单.md` |
| **文件来源** | `templates/` ——**参考样本，按启用集取用并改写，不要全量复制** |

> ### ⚠️ 最重要的一句
> **当 `templates/` 里的东西跟这个项目对不上时（多数情况），不要硬套——去读 `references/自建指南.md`。**
> 那里讲了：怎么从"用户纠正过什么"倒推该有哪些技能、怎么判断哪些该进红线、
> 事实从代码哪里挖、门禁怎么设计才挡得住、设计完怎么自检。
> **照抄模板 = 交作业；按指南自建 = 真的搭起来。**

> `templates/` 的位置 = 本技能所在目录（项目级：`.trae/skills/harness-bootstrap/templates/`；
> 全局：`~/.trae-cn/skills/harness-bootstrap/templates/`）。

---

## 第五部分：卸载

```powershell
# 预览会删什么
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\uninstall-harness.ps1 -WhatIf

# 实际卸载：移除链接、git hook、gitignore 行；保留成果文件
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\uninstall-harness.ps1
```

**不会删**：`AGENTS.md`、`.trae/agents/*.md`、源码与 wiki（除非加 `-RemoveHarness`）。
**删完开新对话**，否则模型还在用旧上下文。
