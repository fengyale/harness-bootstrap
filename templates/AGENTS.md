# <项目名> AI 编码约束

> 这是**唯一常驻文件**（TRAE 全量加载）。只放**每轮必须**的内容：技术栈、必跑命令、红线、文件索引、编码纪律。
> 目标：**≤150 行**。写每一行前先问「每轮都必须读吗」，再按类型归位：
> 项目知识（规则入口 / 业务流 / 数据模型 / 接口协议 / 环境工具）→ `.harness/wiki/`；
> 流程、质量门、检查清单 → `.harness/rules/`；具体做法 → `.harness/skills/`。常驻层不许重复它们。
> ⚠️ 生成说明：所有 `<…>` 占位符都要用**项目真实情况**替换；无法确认的写 `TODO(待确认)`，禁止编造。

## 技术栈

| 层级 | 技术 |
| --- | --- |
| 语言 / 运行时 | `<如 Java 21 / Node 20 / Go 1.22>` |
| 后端框架 | `<如 Spring Boot 3.x + MyBatis-Plus>` |
| 数据库 / 缓存 / 消息 | `<如 MySQL 8.0 + Redis 7.x + RocketMQ 5.x>` |
| 前端 | `<如 Vue 3 + TypeScript + Vite>` |

**必跑命令**（每次改完必须验证，命令必须实测过）

| 用途 | 命令 |
| --- | --- |
| 编译 / 类型检查 | `<如 mvn -q compile 或 npx vue-tsc --noEmit>` |
| 跑全部测试 | `<如 mvn -q test>` |
| 跑单个测试 | `<如 mvn -q test -Dtest=XxxTest>` |
| Lint / 格式化 | `<如 mvn -q spotless:check>` |
| 本地启动 | `<如 mvn spring-boot:run>` |
| 红线扫描（增量） | `git diff --cached -U0 \| powershell -NoProfile -ExecutionPolicy Bypass -File scripts\red-line-scan.ps1 -Root . -DiffFromStdin` |

> 扫描器在 diff 模式下读 **index** blob，所以先 `git add -p` 或 `git add` 再跑；`-Files` 是整文件扫描，会把历史违规一起吐出来，不要拿它做日常增量检查。

## 🔴 红线（不可违反）

> 图例：**🔴 红线（零容忍）｜🟡 强烈建议**。全项目统一使用这两个标记。
> 每条红线都必须**能用脚本判定**（给出搜索动作），否则它只是口号。
> **编号必须与 `scripts/red-line-rules.json`、`.harness/rules/编码规范.md` 的「红线汇总」一一对应，不许跳号。**

| # | 红线 | 检查方法（可执行） |
| --- | --- | --- |
| R1 | `<如 金额字段一律整数最小单位>` | `<如 全局搜 Double\|BigDecimal\|float + 金额语义字段；DDL 搜 DECIMAL\|FLOAT>` |
| R2 | `<如 缓存 Key 必须有统一前缀>` | `<扫描 Key 构造点>` |
| R3 | `<如 异常必须走统一异常体系>` | `<搜 throw new RuntimeException\|IllegalStateException>` |
| R4 | `<如 禁止 @Autowired 字段注入>` | `<搜 @Autowired 后接 private>` |
| R5 | `<如 事务必须声明回滚范围>` | `<扫描器只拦 @Transactional() 空括号；无括号/带属性未声明 rollbackFor 人工复核>` |
| R6 | `<如 禁止敏感信息入日志>` | `<扫描器覆盖单行/多行 log 调用；嵌套括号或复杂拼接人工复核>` |
| R7 | `<如 Mapper XML 禁止 ${} 占位>` | `<搜 *mapper*.xml 里的 ${}>` |
| R8 | `<占位红线：按项目补充，或三处一并删除>` | `<改 red-line-rules.json 的占位 pattern，或删掉三处的 R8>` |

> 上表的 R1–R7 与 `scripts/red-line-rules.json` 的**语义**必须一致（不只是编号）；
> R8 在 JSON 中是一条永不匹配的占位规则——按项目实际替换，或把三处的 R8 一并删掉。

**红线冲突的处理方式**：立即停止 → 修复 → 从受影响阶段重新验证。**禁止"先合入后续再改"。**

## 文件索引

> 这就是"目录"。技能 `description` 每轮在场，但**规范与事实文件需要被显式指到**。
> 新增文件后，**必须回到本表登记**（与 `开发流程规范.md` 的「变更特性清单」同步）。

### 规则（不可协商的边界）

| 文件 | 用途 |
| --- | --- |
| `.harness/rules/编码规范.md` | 单文件内代码怎么写（含 🔴/🟡 图例定义） |
| `.harness/rules/工程结构.md` | 文件放哪、怎么命名、依赖方向 |
| `.harness/rules/开发流程规范.md` | 阶段流程、质量门、回滚、变更管理、AI 编码纪律 |
| `.harness/rules/缓存与一致性.md` | 该不该缓存、Key/TTL、更新顺序、穿透/击穿/雪崩预案（无缓存项目删除） |
| `.harness/rules/消息与异步.md` | 该不该异步、发送失败处理、消费幂等、重试与死信（无 MQ 项目删除） |
| `.harness/rules/数据迁移与回滚.md` | 扩展→迁移→收缩、DDL 红线、回填校验、回滚触发条件（无 DB 项目删除） |

### 技能（按需加载）

> ⚠️ **生成说明（落地时必须改这张清单）**：下面列的是**全部可用技能**，
> 不是"本项目已安装的技能"。按 `references/落地策略.md` 的默认启用集，
> 首次通常只装 3–5 个。**这一节必须改成"实际装了什么"**，因为它是你（模型）
> 判断"该用哪个技能"的唯一索引——列了没装的技能，你会去找不存在的文件。

- **主流程**（`main-dev`）：`request-analysis` · `coding-skill` · `expert-reviewer`
  <br>（可选，装了才写：`unit-test-write` · `unit-test-ci` · `deploy-verify`）
- **业务实现**（`biz-dev`）：`<只列实际安装的专题，如 redis-cache>`
- **线上排查**（`trouble-shooting`）：`<只列实际安装的，如 slow-sql>`

> 用不到的专题**直接删掉技能目录**（技能清单每轮占上下文）。
> 完整索引与触发约定见 `.harness/skills/README.md`；本表要与它保持一致。
> **技能缺失不是问题，检查缺失才是问题**——缺技能时按 `coding-skill` 的"下一步"表用最低限度手工替代。

### 项目事实（wiki，被技能引用）

| 文件 | 用途 |
| --- | --- |
| `.harness/wiki/领域术语.md` | 统一术语表（**术语与代码实体映射以本文为准**） |
| `.harness/wiki/业务模型.md` | 实体关系、核心流程、消息与缓存拓扑 |
| `.harness/wiki/数据模型.md` | 表结构（**DDL 权威来源是迁移脚本**） |
| `.harness/wiki/接口协议.md` | 接口清单（**端点权威来源是 controller**） |

### 模块卡片（按需，定位到模块后读）

| 位置 | 用途 |
| --- | --- |
| `.harness/modules/<module>.md` | 该模块的重点 / 难点 / 坑点 / 验证方式（每条带 E1/E2） |
| `.harness/modules/README.md` | 已生成卡片索引；只写高频 3–5 个，不是每个 module 都写 |

### 变更记录

| 位置 | 用途 |
| --- | --- |
| `.harness/changes/_small.md` | L1 小改滚动记录（一行一次；L0 不写） |
| `.harness/changes/<特性名>/summary.md` | L2/L3 变更摘要、验收标准、回滚方案 |
| `.harness/changes/<特性名>/db-migrations.sql` | 迁移脚本（与 `rollback.sql` **必须成对**） |
| `.harness/changes/<特性名>/rollback.sql` | 回滚脚本 |

### 校验与门禁

| 文件 | 用途 |
| --- | --- |
| `.trae/agents/code-reviewer.md` | 代码评审智能体（独立上下文，多维度分级评审） |
| `.trae/agents/consistency-verifier.md` | 代码 ↔ 文档漂移检测智能体 |
| `.trae/agents/red-line-auditor.md` | 全库红线扫描智能体 |
| `.harness/lessons.md` | 教训索引（`metrics.ps1` 自动刷新、团队共享）；写 `lesson_id` 前先查表 |
| `.harness/lessons-promoted.txt` | 已晋升教训清单（团队共享）；晋升后追加 id，`metrics` 不再重复提醒 |
| `scripts/install-git-hooks.ps1` | 安装 git pre-commit 强制门禁（**真正的拦截点**，不是可选的编辑器 hook） |
| `scripts/update-harness.ps1` | 升级已装项目：不加 `-Apply` 只预览，`-Apply` 执行；`-MergeSkills` 用新版通用段并保留项目绑定（推荐）；`-UpdateSkills` 只替换未编译技能；`-ForceSkills` 强制覆盖 |
| `scripts/red-line-scan.ps1` | 红线扫描脚本（hooks 与 CI 共用） |
| `scripts/check-summary.ps1` | `summary.md` 字段校验：pre-commit 只查基础字段，stage-gate 阶段 10 查收尾字段 |
| `scripts/audit-order.ps1` | CI 提交区间审计：源码提交前是否已有 summary；`[L0]` 豁免，合并提交跳过 |

> 非 TRAE 平台把 `.trae/agents/` 换成探测到的目录（Claude 为 `.claude/agents/`）；两者都没有时按清单模式手工评审，不要假装子智能体存在。
> 平台侧的 `.trae/hooks.json` 是可选的快速反馈（默认空壳），只有你手工配置后才存在，**不在本索引里**。

## AI 编码纪律（与 `开发流程规范.md` 保持一致，此处只留摘要）

- **加载范围**：默认只读「本任务涉及的模块卡 + 直接相关的 1–2 份 wiki / 规则」；**技能与模块卡不占此额度**，按流程必上。
- **超限例外**：跨模块改造、数据迁移、上线评审可多读，在 `summary.md` 写一行「额外读取：… ｜ 原因：…」。
- **单次变更量 ≤ 文件总量的 40%**，超过必须拆分；每次改完必须过上面的"必跑命令"。
- **先定档再落盘**：L0（纯文档 / 注释 / 格式 / typo，不改行为）不建记录；L1（单文件、diff ≤30 行、不碰公共层 / DB / 配置 / 接口）只在 `.harness/changes/_small.md` 追加一行；L2/L3 先复制 `.harness/changes/_template/summary.md` 到 `.harness/changes/<特性>/summary.md`，运行 `check-summary.ps1 -Feature <特性> -Stage initial` 通过后**单独提交一次**（只含 `.harness/` 下文件），再改代码——pre-commit 会拒绝「新增 summary + `.harness/` 之外的改动」同一个提交，因为 git 只能看提交顺序、看不到编辑顺序。`/plan` 模式的计划必须写进对应记录，不能只留在工具的计划面板。
- **必上技能**：收到需求先加载 `request-analysis`；动代码先加载 `coding-skill`；合并前加载 `expert-reviewer`
- **涉及 SQL 必评审**：新增/修改 SQL、加索引、改分页或批量写入时，**已装 `sql-review` 就必须加载它**并按步骤评估；未装时按 `.harness/rules/SQL评审规范.md` 手工评审。两种情况都要写 `sql_review:`，含正确性四层（语法 / 结构 / 绑定 / 结果）与执行计划结论；stage-gate 阶段 10 校验，缺则不能收尾
- **禁止在未加载对应技能时凭印象编码**——先查 `.harness/skills/README.md`；清单里没有的技能按“技能缺失”处理并说明
- **任务摘要必须可判定**：L2/L3 的 `summary.md` 由 `scripts/check-summary.ps1` 校验；L1 的 `_small.md` 行由 `metrics.ps1` 解析，字段不全或写坏会报 malformed。分工：**pre-commit 只查 summary 基础字段**，`lesson_id` / `sql_review` 由 `stage-gate` 阶段 10 查。**缺字段或留占位符 = 任务未完成**
- **源码提交必须能归因到记录**：在 `feature/<名>` / `fix/<名>` 分支或 `HARNESS_TASK=<名>` 下，HEAD 需已有 `.harness/changes/<名>/summary.md`，或同提交带 summary / `_small.md` 行；L0 与一次性导入用 `HARNESS_ALLOW_NO_RECORD=1` 显式放行
- **提交信息用中文**：格式仍是 `<type>(<scope>): <中文说明>`，type 取 `<feat|fix|refactor|test|docs|chore>`；标题与正文用中文写清「为什么改」，代码、命令、路径、标识符保留原文。提交日志是团队要读的文档，不写英文句子
