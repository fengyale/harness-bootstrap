# 技能矩阵总览

> 技能的**完整清单**由 `.trae/skills/` 的实际内容决定（每个技能一个目录 + `SKILL.md`）；
> 正文真源在 `.harness/skills/<分类>/<技能>/SKILL.md`。
> 本文件是**分类索引**，新增/删除技能后要回来同步。

## 三层分工（分层契约）

| 分类 | 管什么 | 编号含义 | 数量 |
| --- | --- | --- | --- |
| `main-dev/` | **流程管控**：什么时候做什么、每步门槛 | 覆盖开发阶段 1–3、5–9（阶段 4 由 pre-commit 自动、阶段 10 无专属技能） | 6 |
| `biz-dev/` | **具体实现**：这类代码怎么写 | **技术专题编号**（01–14） | 14 |
| `trouble-shooting/` | **线上排查**：出事后怎么定位 | **事故类型编号**（01–05） | 5 |

> **关键原则**：流程技能**只定义流程与检查点，不重复展开模式细节**；
> 模式细节一律下推到 `biz-dev`。规则文件（`.harness/rules/`）只定义边界，同样不展开做法。

## main-dev（流程类，6 个）

| 技能 | 对应阶段 | 什么时候用 |
| --- | --- | --- |
| `request-analysis` | 1–2 | 收到任何新需求 / 变更请求，**进入开发之前**（含方案与任务拆分） |
| `coding-skill` | 3 | 需求已确认，开始写代码（阶段 4 静态检查由 pre-commit 自动） |
| `unit-test-write` | 5 | 编码完成，补单测 |
| `expert-reviewer` | 6 | 准备合并，要评审 |
| `unit-test-ci` | 7 | 跑质量门禁、CI 挂了 |
| `deploy-verify` | 8–9 | 发版 / 冒烟验证 / 线上回滚（阶段 10 沉淀无专属技能） |

## biz-dev（实现类，14 个）

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

## trouble-shooting（排查类，5 个）

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
