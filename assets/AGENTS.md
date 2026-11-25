# <项目名> AI 编码约束

<!-- harness:upgrade:begin id=start-command -->
> **开工第一件事（不可跳过）**：改源码 / 配置 / SQL / 接口前，先跑
> `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\harness-start.ps1 -Feature 特性名 -Requirement "需求原文"`。
> 未 exit 0 / summary 未建 / Stage 1 未 OPEN 之前，不得 Edit/Write 源码；用户说「开始做吧」只是同意方案，不等于跳过。
> 只改文档 / 注释 / 格式（L0）或 L1 轻量改动时，先在回复里写明「L0：无记录」/「L1：写 _small.md」，再走轻量路径。
<!-- harness:upgrade:end id=start-command -->

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

> **多模块项目**：在上表加一列「模块」，表头为 `| 用途 | 模块 | 命令 |`；模块名必须与 `.harness/modules/` 的卡片名一致，`*` 表示任何模块都适用的默认行。
> `stage-gate` 的阶段 3/5/7/8 会按 `summary.md` 的 `touched_modules` 取并集，逐个模块跑对应的编译 / 测试命令。
> 缺该模块的行且没有 `*` 行 → FAIL；只有单条命令、没有模块列的旧表只 WARN，并提示补模块列。
> 有模块列但 `touched_modules` 为空 / none 且没有 `*` 行 → 同样 FAIL；默认行必须写 `*`，模块列留空不等于 `*`。

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
| R5 | `<如 事务必须声明回滚范围>` | 扫描器只拦 `@Transactional()` 空括号；无括号 / 带属性未声明 `rollbackFor` 人工复核 |
| R6 | `<如 禁止敏感信息入日志>` | 扫描器覆盖单行 / 多行 log 调用；嵌套括号或复杂拼接人工复核 |
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

<!-- skills-index:begin -->
| 分类 | 技能 | 用途（description 首句，≤40 字） |
| --- | --- | --- |
| biz-dev | `crud-scaffold` | 为一张新业务表从零搭一套增删改查，或给已有表补齐管理端维护接口时使用 |
| biz-dev | `pagination-query` | 列表接口要返回总数、深翻页变慢、翻页数据重复或总数对不上时使用 |
| biz-dev | `redis-cache` | 缓存设计与读写：判断该不该缓存、加缓存、处理缓存与数据库不一致、应对穿透击穿雪… |
| biz-dev | `mq-messaging` | 要用消息做跨进程通知、异步解耦、削峰，或已有消费者重复处理、丢消息、积压时需要… |
| biz-dev | `transaction-consistency` | 一次请求要写多张表、调外部接口、更新缓存，或跨服务写入需要最终一致、请求可能重… |
| biz-dev | `exception-handling` | 接口报错信息前后端理解不一致、对外暴露内部堆栈、线上排障找不到对应请求时使用 |
| biz-dev | `business-validation` | 业务规则校验散落在多处、同一错误在入口与落库时口径不一、并发下出现重复提交时使用 |
| biz-dev | `excel-import-export` | 批量导入表格文件、按条件导出大数据量、导入失败要定位到行时使用 |
| biz-dev | `db-migration` | 上线要改表结构、加索引、加字段，或给大表批量订正数据时使用 |
| biz-dev | `scheduled-task` | 周期性批处理、定时同步或定时清理任务上线时使用 |
| biz-dev | `file-upload` | 附件、头像、凭证等文件上传功能开发或改造时使用 |
| biz-dev | `notification` | 面向使用者的消息提醒（站内、短信、邮件、推送）上线或改造时使用 |
| biz-dev | `stats-report` | 报表或看板指标开发、口径争议、数据刷新不及时时使用 |
| biz-dev | `sql-review` | SQL 性能评审：新增或修改 SQL、加索引、改分页、改批量写入时使用 |
| main-dev | `coding-skill` | 编码实现：源码写操作前必须使用，先跑 harness-start 并贴 DECLARE |
| main-dev | `deploy-verify` | 一次发布上线前后使用 |
| main-dev | `expert-reviewer` | 代码评审：按结构、红线、性能、安全、一致性、可测性六个维度评审改动并输出分级结论 |
| main-dev | `request-analysis` | 需求分析与拆解：编码需求、首次 Edit/Write 前必须使用，先定档建 summary |
| main-dev | `unit-test-ci` | 搭建或调整持续集成流水线时使用 |
| main-dev | `unit-test-write` | 为新逻辑补测试、或修完缺陷后补回归用例时使用 |
| trouble-shooting | `slow-sql` | 慢查询排查与优化：接口响应变慢、数据库 CPU 高、报表查询超时时使用 |
| trouble-shooting | `oom-troubleshoot` | 进程内存持续上涨、频繁被系统终止或响应逐渐变慢时使用 |
| trouble-shooting | `cpu-high-troubleshoot` | 进程占用持续偏高、请求响应变慢或线程疑似卡死时使用 |
| trouble-shooting | `mq-backlog-troubleshoot` | 消息积压、消费延迟持续增长或消费速度明显低于生产速度时使用 |
| trouble-shooting | `redis-hotkey-troubleshoot` | 缓存中单个键访问极度集中，导致某节点负载不均、时延抖动或热点集体失效击穿时使用 |
<!-- skills-index:end -->

> 用不到的专题**直接删掉技能目录**（技能清单每轮占上下文）。
> 上表由 `scripts/sync-skills-index.ps1` 扫描 `.harness/skills/` 生成：加删技能后跑一次 `-Write`，`verify-harness` 的 `skills-index` 会校验它是否漂移。
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
| `.harness/changes/<特性名>/summary.md` | L2/L3 变更摘要、验收标准、回滚方案、交付状态（`delivery_status`）、测试跳过原因（`test_skip_reason`） |
| `.harness/changes/<特性名>/evidence/` | 编译日志 / EXPLAIN / 查询结果摘要 / 截图；`summary.md` 只引用路径（可选，不新增硬门禁） |
| `.harness/changes/<特性名>/db-migrations.sql` | 迁移脚本（与 `rollback.sql` **必须成对**） |
| `.harness/changes/<特性名>/rollback.sql` | 回滚脚本 |

> 证据统一放 `evidence/`，`summary.md` 只引用路径；除已有的 `sql_review` 证据锚点外不新增硬门禁。
> 跨仓特性在**每个仓库各留一份** `summary.md`，用 `linked_records` 指向另一个仓库的记录（`repo:path` 或 URL；无跨仓记录写 `-`）；门禁不校验对端仓库。

### 校验与门禁

| 文件 | 用途 |
| --- | --- |
| `.trae/agents/code-reviewer.md` | 代码评审智能体（独立上下文）：合并前优先委派，结论并入 `summary.md` 评审结论 |
| `.trae/agents/consistency-verifier.md` | 代码 ↔ 文档漂移检测智能体：每月体检或大改后委派 |
| `.trae/agents/red-line-auditor.md` | 全库红线语义审计智能体：每周按熵管理周期表委派 |
| `.harness/lessons.md` | 教训索引（`metrics.ps1` 自动刷新、团队共享）；写 `lesson_id` 前先查表 |
| `.harness/reviews.md` | 评审发现索引（`metrics.ps1` 自动刷新、团队共享）；写 P0/P1 指纹前先查表，同一问题复用同一指纹 |
| `.harness/lessons-promoted.txt` | 已晋升教训清单（团队共享）；**晋升必须带断言**：`id :: check=路径::说明`，检查脚本内要有 `# lesson: id` 与 `# fails-when: 什么改动会让它变红`；缺一由 `metrics.ps1 -LessonGate` 判 FAIL |
| `scripts/install-git-hooks.ps1` | 安装 git pre-commit 强制门禁（**真正的拦截点**，不是可选的编辑器 hook） |
| `scripts/update-harness.ps1` | 升级：日常从**新包**跑 `assets\upgrade\upgrade-harness.ps1 -Root 项目根目录`（它调用新包的 `update-harness.ps1`，项目旧 updater 被绕过）；本文件是**被替换的机制文件**，`-PackagePath` 直调只用于 1.30.0 及更早的首次升级或兼容排查。`-Apply` 才执行；`-MergeSkills` 用新版通用段并保留项目绑定 |
| `scripts/red-line-scan.ps1` | 红线扫描脚本（hooks 与 CI 共用） |
| `scripts/check-summary.ps1` | `summary.md` 校验：pre-commit 查档位 / 技能 / 模块 + 验收标准、影响面、任务拆分三节内容；阶段 10 查收尾字段 |
| `scripts/audit-order.ps1` | CI 提交区间审计：源码提交前是否已有 summary；`[L0]` 豁免，合并提交跳过。记录目录被 `.gitignore` 忽略时直接 FAIL（不是静默跳过） |
| `scripts/sync-skills-index.ps1` | 技能清单单一真源：扫 `.harness/skills/` 生成索引表；加删技能后跑 `-Write`，`verify-harness` 的 `skills-index` 校验漂移 |
| `scripts/suggest-flow.ps1` | 只读定档建议：按当前 diff 估 L0–L3，输出可直接粘贴的 `flow:` / `touched_modules:` 与变更清单草稿；开发期先跑 |
| `scripts/harness-plan.ps1` | 只读上下文包：按需求输出相关模块卡、必上技能、预计门禁、涉及表/接口与档位提示；需求进来先跑 |
| `scripts/verify-harness.ps1` / `verify-grounding.ps1` | 结构与接地自检；已填项目里目录树占位、rules/wiki 残留尖括号占位、技能 project 块为空都会 FAIL |

> 非 TRAE 平台把 `.trae/agents/` 换成探测到的目录（Claude 为 `.claude/agents/`）；两者都没有时按清单模式手工评审，不要假装子智能体存在。
> 平台侧的 `.trae/hooks.json` 是可选的快速反馈（默认空壳），只有你手工配置后才存在，**不在本索引里**。

## AI 编码纪律（与 `开发流程规范.md` 保持一致，此处只留摘要）

- **开工第一件事**：见文件顶部「开工第一件事（不可跳过）」。L2/L3 先跑 `scripts\harness-start.ps1 -Feature 特性名 -Requirement "需求原文"`（出上下文、建 summary 骨架、过 Stage 1、写 `.git/harness-task-started`），Stage 1 通过后再改代码；L0/L1 先在回复里写明档位，再走轻量路径。`requireTaskStart` 默认 false（升级与新装都不启用，L0 / 纯文档 / harness-only / merge 提交不受影响），团队 adoption 后手动改 true；开启后 pre-commit 只在提交 `summary.md` 时校验该 marker。
- **超限例外**：跨模块改造、数据迁移、上线评审可多读，在 `summary.md` 写一行「额外读取：… ｜ 原因：…」。
- **单次变更量 ≤ 文件总量的 40%**，超过必须拆分；每次改完必须过上面的"必跑命令"。多智能体并行时，读代码可并行，**编译 / 测试 / 迁移一次只跑一个**，避免共享 target 与 fixture 互相污染
- **先定档再落盘**：L0（纯文档 / 注释 / 格式 / typo，不改行为）不建记录；L1（单文件、diff ≤30 行、不碰公共层 / DB / 配置 / 接口）只在 `.harness/changes/_small.md` 追加一行，**提交时 pre-commit 按实际 diff 核对，超过 1 文件或 30 行会被拒绝**；L2/L3 先复制 `.harness/changes/_template/summary.md` 到 `.harness/changes/` 下的特性目录（目录名即特性名），运行 `check-summary.ps1 -Feature 特性名 -Stage initial` 通过后**单独提交一次**（只含 `.harness/` 下文件），再改代码——pre-commit 会拒绝「新增 summary + `.harness/` 之外的改动」同一个提交，因为 git 只能看提交顺序、看不到编辑顺序。`/plan` 模式的计划必须写进对应记录，不能只留在工具的计划面板。只读排查用 `scripts\harness-start.ps1 -Investigation`（`flow: L1` + `record_kind: investigation`），验收 / 影响 / 任务三节不强制。
- **必上技能**：收到需求先跑 `scripts\harness-start.ps1 -Feature 特性名 -Requirement "需求原文"`（内含 `harness-plan` 与 `stage-gate.ps1 -Stage 1`），再加载 `request-analysis`；**动代码前把 `DECLARE` 行贴进回复**（出现 `[HINT]` 说明记录缺失，先补记录），再加载 `coding-skill`；合并前加载 `expert-reviewer`，平台装了 `code-reviewer` 子智能体时**优先委派它**做独立评审。改动后先跑 `scripts\suggest-flow.ps1`，用它的 `flow:` / `touched_modules:` 填记录，再按档位走流程
- **涉及 SQL 必评审**：新增/修改 SQL、加索引、改分页或批量写入时，**已装 `sql-review` 就必须加载它**并按步骤评估；未装时按 `.harness/rules/SQL评审规范.md` 手工评审。两种情况都要写 `sql_review:`，含正确性四层（语法 / 结构 / 绑定 / 结果）与执行计划结论；**四层里有「未验证」时结论不得写「通过」**，结论为「通过 / 已改写」时必须引用 `.harness/changes/` 下本特性 `sql-review/` 里真实存在的证据文件（EXPLAIN 或结果摘要），只写通过不引用路径会在阶段 10 FAIL；引用的证据路径必须真实存在；stage-gate 阶段 10 校验（**涉及 SQL 的改动合并前就要跑**），缺则不能收尾
- **禁止在未加载对应技能时凭印象编码**——先查 `.harness/skills/README.md`；清单里没有的技能按“技能缺失”处理并说明
- **任务摘要必须可判定**：L2/L3 的 `summary.md` 由 `scripts/check-summary.ps1` 校验；**pre-commit 查档位 / 加载技能 / 触及模块，外加验收标准、影响面（或技术变更清单）、任务拆分的真实内容**（模板占位符算未填）；`corrections` / `impl_corrections` / `lesson_id` / `sql_review` / `delivery_status` / `linked_records` 由 `stage-gate` 阶段 10 查——它们做完才知道，`delivery_status` 为 `已部署` 时还要求部署记录有真实一行；`linked_records` 有跨仓时写 `repo:path` 或 URL，无跨仓写 `-`，整行缺失视为单仓（不算未完成），但占位符会 FAIL。L1 的 `_small.md` 行由 `metrics.ps1` 解析，字段不全或写坏会报 malformed，且 pre-commit 会按实际 diff 核对 L1 声明（>1 文件或 >30 行直接拒绝）。**缺字段或留占位符 = 任务未完成**
- **评审发现必须落表**：评审结论写进 `summary.md`「评审结论」表（严重度 / 范围 / 状态 / 指纹 / 问题 / 证据 / 处置）；P0 必须 `已修`，P1 必须有处置（`已修` / `转待办` / `接受`）；P0/P1 必须带 kebab-case 指纹，写前先查 `.harness/reviews.md` 复用同一指纹
- **源码提交必须能归因到记录**：特性名按 `HARNESS_TASK=特性名` → `check-summary -Feature 特性名` 自动写入的 `.git/harness-current-task` → `.harness/changes/` 下唯一目录 的顺序解析，**与分支名无关**；HEAD 需已有该特性的 `summary.md`，或同提交带 summary / `_small.md` 行；L0 与一次性导入用 `HARNESS_ALLOW_NO_RECORD=1` 显式放行
- **提交信息用中文**：格式为 `type(scope): 中文说明`，type 取 feat / fix / refactor / test / docs / chore；标题与正文用中文写清「为什么改」，代码、命令、路径、标识符保留原文。提交日志是团队要读的文档，不写英文句子
