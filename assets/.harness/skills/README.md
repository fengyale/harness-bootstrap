# 技能矩阵总览

> 技能的**完整清单**由 `.harness/skills/<分类>/<技能>/SKILL.md` 的目录结构决定——
> **目录是唯一真源**；`.trae/skills` 只是指向它的发现入口（junction，不入库）。
> 下面「分类清单」那张表由 `scripts/sync-skills-index.ps1` 生成，**不要手改标记块内的内容**；
> 分类说明里的数量只是参考；新增/删除技能后，以生成表里的条目为准（生成表不含数量，自己数条目）。

> 新增或删除技能后跑一次 `sync-skills-index.ps1 -Write`；`verify-harness` 的 `skills-index` 会校验它是否漂移。

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
| main-dev | `coding-skill` | 编码实现：按项目分层写业务代码，遵守数据访问、异常与缓存约定，改完必须做编译验证 |
| main-dev | `deploy-verify` | 一次发布上线前后使用 |
| main-dev | `expert-reviewer` | 代码评审：按结构、红线、性能、安全、一致性、可测性六个维度评审改动并输出分级结论 |
| main-dev | `request-analysis` | 需求分析与拆解：把一句话需求转成可验证的任务清单，判断落在哪个模块、影响哪些接… |
| main-dev | `unit-test-ci` | 搭建或调整持续集成流水线时使用 |
| main-dev | `unit-test-write` | 为新逻辑补测试、或修完缺陷后补回归用例时使用 |
| trouble-shooting | `slow-sql` | 慢查询排查与优化：接口响应变慢、数据库 CPU 高、报表查询超时时使用 |
| trouble-shooting | `oom-troubleshoot` | 进程内存持续上涨、频繁被系统终止或响应逐渐变慢时使用 |
| trouble-shooting | `cpu-high-troubleshoot` | 进程占用持续偏高、请求响应变慢或线程疑似卡死时使用 |
| trouble-shooting | `mq-backlog-troubleshoot` | 消息积压、消费延迟持续增长或消费速度明显低于生产速度时使用 |
| trouble-shooting | `redis-hotkey-troubleshoot` | 缓存中单个键访问极度集中，导致某节点负载不均、时延抖动或热点集体失效击穿时使用 |
<!-- skills-index:end -->

## 三层分工（分层契约）

| 分类 | 管什么 | 编号含义 | 数量 |
| --- | --- | --- | --- |
| `main-dev/` | **流程管控**：什么时候做什么、每步门槛 | 覆盖开发阶段 1–3、5–9（阶段 4 由 pre-commit 自动、阶段 10 无专属技能） | 6 |
| `biz-dev/` | **具体实现**：这类代码怎么写 | **技术专题编号**（01–14） | 14 |
| `trouble-shooting/` | **线上排查**：出事后怎么定位 | **事故类型编号**（01–05） | 5 |

> **关键原则**：流程技能**只定义流程与检查点，不重复展开模式细节**；
> 模式细节一律下推到 `biz-dev`。规则文件（`.harness/rules/`）只定义边界，同样不展开做法。

## main-dev（流程类）

| 技能 | 对应阶段 | 什么时候用 |
| --- | --- | --- |
| `request-analysis` | 1–2 | 收到任何新需求 / 变更请求，**进入开发之前**（含方案与任务拆分） |
| `coding-skill` | 3 | 记录已在盘（第 0 步跑 `stage-gate -Stage 1` 并通过），开始写代码（阶段 4 静态检查由 pre-commit 自动） |
| `unit-test-write` | 5 | 编码完成，补单测 |
| `expert-reviewer` | 6 | 准备合并，要评审 |
| `unit-test-ci` | 7 | 跑质量门禁、CI 挂了 |
| `deploy-verify` | 8–9 | 发版 / 冒烟验证 / 线上回滚（阶段 10 沉淀无专属技能） |

## biz-dev（实现类）

| 编号 | 技能 | 什么时候用 |
| --- | --- | --- |
| 01 | `crud-scaffold` | 新增业务模块 / 一套增删改查 |
| 02 | `pagination-query` | 列表分页查询 |
| 03 | `redis-cache` | 给查询接口加缓存 |
| 04 | `mq-messaging` | 异步解耦、发消息、写消费者 |
| 05 | `transaction-consistency` | 多表写入、跨服务一致性 |
| 06 | `exception-handling` | 异常怎么抛、错误码怎么设计 |
| 07 | `business-validation` | 接口校验、业务规则前置检查 |
| 08 | `excel-import-export` | 批量导入导出 |
| 09 | `db-migration` | 改表结构、加索引、批量修数据 |
| 10 | `scheduled-task` | 定时对账 / 超时取消 / 周期统计 |
| 11 | `file-upload` | 图片 / 附件上传下载 |
| 12 | `notification` | 站内信 / 短信 / 邮件 |
| 13 | `stats-report` | 看板 / 统计报表 |
| 14 | `sql-review` | 新增 / 修改 SQL、加索引、改分页、批量写入（**提交前必须**） |

> **项目里用不到的专题，直接删掉那个技能目录**——不要为了凑数保留，技能清单每轮都占上下文。

## trouble-shooting（排查类）

| 编号 | 技能 | 什么时候用 |
| --- | --- | --- |
| 01 | `slow-sql` | 接口变慢、慢查询告警、DB CPU 高 |
| 02 | `oom-troubleshoot` | OOM、Full GC 频繁、进程被杀 |
| 03 | `cpu-high-troubleshoot` | CPU 持续打满、整体变慢无报错 |
| 04 | `mq-backlog-troubleshoot` | 消息积压、消费延迟上涨 |
| 05 | `redis-hotkey-troubleshoot` | Redis 单分片 CPU 满、热 Key |

## 命名与触发约定（**必须遵守，否则技能会互抢触发**）

1. **技能名全局唯一**：`.trae/skills/` 只扫一层，不同分类下不能同名。
2. **目录名可以带编号前缀**（如 `03-redis-cache`），但 frontmatter 的 `name` **不带编号**（`redis-cache`）。
3. **`description` 是触发的唯一依据**（平台只扫 name + description）：
   - 格式：**「做什么 + 关键技术点。当 <具体场景 / 用户原话> 时使用本技能。」**
   - 把用户**会说的话**写进去（"这个接口太慢了，加个 Redis"），命中率最高
   - **必须短**（平台会截短），且**不同技能的触发词不能重叠**
4. 正文结构固定：`触发条件 → 前置准备 → 核心规则 → 执行流程 Step 1..N → 自检清单 → 红线`
5. **自检清单必须可判定**：写"所有缓存操作被 try-catch 包裹" ✅，写"代码要优雅" ❌
6. 技能正文里的**文件路径必须真实存在**（含大小写）。改名后要全局搜一遍。

## 新增一个技能的步骤

1. `.harness/skills/<分类>/<技能名>/SKILL.md`，用上面的固定结构
2. frontmatter 只写 `name` + `description`（**不需要** whenToUse，触发条件写在正文和 description 里）
3. 跑 `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-links.ps1` 建入口
4. 在根 `AGENTS.md` 的技能分类里登记，并在**本文件**的对应表里加一行
   （`verify-harness.ps1` 的 `skills-registry` 会查两件事：本文件有没有登记、平台发现目录有没有同名入口；缺任一项直接 FAIL）
5. 重启工具，发一句匹配 `description` 的话，**验证它真的自动触发**

## 淘汰机制（别忘了）

**每两周**：跑 `metrics.ps1 -Days 28`，把 `retire candidate` 列成清单——**只列清单，不删**。
**人确认后**才删目录，并同步本文件与根 `AGENTS.md` 的技能索引。
**每月技能体检**时：核对技能是否与代码同步、`description` 是否还能命中。
> 与代码不同步的技能**比没有技能更坏**——它会自信地教错；未经人确认的删除同样危险。
