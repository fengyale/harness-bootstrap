# SQL 评审规范

> **本文件是骨架**：`<!-- slot:… -->` 必须在安装时用项目事实替换，替换不到就整条删除。
> 触发：新增 / 修改 SQL、加字段、加索引、改分页或批量写入。
> 改代码时看本文；线上慢查询排查看 `trouble-shooting/01-slow-sql`。

## 1. 三条必做

| # | 动作 | 判据 |
| --- | --- | --- |
| 1 | 估数据量 | 查询 count 或表统计；大表（> 10 万行）必须有可用索引 |
| 2 | 看执行计划 | <!-- slot:db.explain --> |
| 3 | 写结论 | `summary.md` 的 `sql_review:` 一行，含表名、预估行数、访问路径 |

缺第 3 条 → pre-commit 拒绝提交（`scripts/sql-review-gate.ps1`）。
`scripts/harness-required.json` 的 `sqlGate=true` 表示本门禁已启用：规则文件与 gate 脚本必须同时存在且可运行。要关闭门禁，必须在**同一次提交**里把 `sqlGate` 改为 `false` 并删除规则与 gate；分两次提交会被 hook 拦下（off+残留或 on+无规则）。只删规则不改配置会被 `verify-harness` 判 FAIL。
`sqlGate` 只从 **index / HEAD** 读取；配置还没入库时按 legacy（规则存在即启用）处理，避免工作区里未暂存的 `false` 把门禁关掉。

## 2. 高危写法

| 写法 | 风险 | 改法 |
| --- | --- | --- |
| `select *` | 回表与传输放大 | 只列需要的字段 |
| `not in (子查询)` | 空值导致结果错误、难以走索引 | 改 `not exists` |
| `like '%x'` | 前导通配索引失效 | 前缀匹配，或另建索引列 |
| 大 offset 分页 | 先扫前 N 行 | 游标 / 延迟关联 |
| 循环单条 insert | N 次往返 | 批量，单批有上限 |
| 索引列套函数 | 索引失效 | 改写条件，慎建函数索引 |
| 隐式类型转换 | 索引失效 | 参数类型与列一致 |

## 3. 方言差异

| 项 | <!-- slot:db.dialectA --> | <!-- slot:db.dialectB --> |
| --- | --- | --- |
| 分页 | <!-- slot:db.paging.a --> | <!-- slot:db.paging.b --> |
| 空值 | <!-- slot:db.null.a --> | <!-- slot:db.null.b --> |
| 日期 | <!-- slot:db.date.a --> | <!-- slot:db.date.b --> |
| 执行计划 | <!-- slot:db.explain.a --> | <!-- slot:db.explain.b --> |

**禁止**把一处方言的 SQL 直接复用到另一数据源。

## 4. 与 slow-sql 的分工

- 事前（改代码时）→ 本规范 + 本技能
- 事后（已变慢）→ `trouble-shooting/01-slow-sql`：日志拿完整 SQL → 执行计划 → 索引

## 证据锚点

<!-- slot:evidence - 至少一条 - [E2] 真实文件路径 :: 证明了什么 -->
