# SQL 评审规范

> **定位**：改代码时的事前评审——SQL 会不会慢、索引够不够、数据量与回滚条件是否清楚。
> `<!-- slot:… -->` 必须在安装时用项目事实替换，替换不到就整条删除。
> 触发：新增 / 修改 SQL、加字段、加索引、改分页或批量写入。
> 线上已经变慢的排查走 `trouble-shooting/01-slow-sql`，不要用本文代替。

## 1. 四条必做

| # | 动作 | 判据 |
| --- | --- | --- |
| 1 | 验正确性 | 语法能解析、表列存在、参数绑定安全、只读结果符合预期；写操作事务回滚或 dry-run |
| 2 | 估数据量 | 查询 count 或表统计；大表（> 10 万行）必须有可用索引 |
| 3 | 看执行计划 | `<!-- slot:db.explain -->`；结论写进 `summary.md` 的 `sql_review:` |
| 4 | 写结论 | 含正确性四层、表名、预估行数、访问路径、结论 |

缺第 4 条 → pre-commit 拒绝提交（`scripts/sql-review-gate.ps1`）。
`scripts/harness-required.json` 的 `sqlGate=true` 表示本门禁已启用：规则文件与 gate 脚本必须同时存在且可运行。要关闭门禁，必须在**同一次提交**里把 `sqlGate` 改为 `false` 并删除规则与 gate；分两次提交会被 hook 拦下（off+残留或 on+无规则）。只删规则不改配置会被 `verify-harness` 判 FAIL。
`sqlGate` 只从 **index / HEAD** 读取；配置还没入库时按 legacy（规则存在即启用）处理，避免工作区里未暂存的 `false` 把门禁关掉。

## 1.1 正确性校验（先证明对，再评估快）

> `sql_review:` 只要求“有结论”，不校验结论真假；正确性由本节四层判据与 `14-sql-review` 技能步骤保证。

| 层 | 判据 | 做法 |
| --- | --- | --- |
| 语法 / 方言 | 目标库能解析 | 只读账号跑 `EXPLAIN` / `PREPARE`，或按方言 parse |
| 结构 | 表、列、类型、约束存在 | 对照 `.harness/wiki/数据模型.md` 与迁移脚本，必要时查 catalog |
| 绑定 | 参数安全且匹配 | 只用 `#{}`，无 `${}`；检查个数、类型、NULL、IN、`ORDER BY` 白名单 |
| 结果 | 语义符合预期 | 只读沙箱用代表性参数 / fixture 跑一次，断言列、行数与关键值；写操作事务回滚或 dry-run |

- 无法验证的层必须写“未验证 + 原因”，**不能写“通过”**
- DDL、大表、批量写等高风险 SQL：没有结果或计划证据时，必须人工确认后才能合并
- 证据落盘到 `.harness/changes/<特性>/sql-review/`，在 `sql_review:` 里引用路径

## 2. 高危写法

| 写法 | 风险 | 改法 |
| --- | --- | --- |
| `select *` | 回表与传输放大 | 只列需要的字段 |
| `not in (子查询)` | 空值导致结果错误、难以走索引 | 改 `not exists` |
| `like '%x'` | 前导通配索引失效 | 前缀匹配，或另建索引列 |
| 大 offset 分页 | 先扫前 N 行 | 游标 / 延迟关联 |
| 循环单条 insert / update | N 次往返 | 批量，单批有上限 |
| 索引列套函数 | 索引失效 | 改写条件，慎建函数索引 |
| 隐式类型转换 | 索引失效 | 参数类型与列一致 |
| 无 where 的 update / delete | 全表误操作 | 先 select 同条件确认范围，再执行 |
| `or` 跨不同列 | 难以命中单索引 | 拆成 `union all` 或补组合索引 |

## 3. 执行计划怎么看

| 指标 | 健康 | 有问题 | 动作 |
| --- | --- | --- | --- |
| `type` / 访问方式 | `const` / `eq_ref` / `ref` / `range` | `ALL` / `index` 全扫 | 补索引或改写条件 |
| `key` | 命中预期索引 | `NULL` | 查 where / join 列与顺序 |
| `rows` | 与预估返回量同量级 | 数量级偏差 | 更新统计信息或改写 |
| `Extra` | `Using index` / `Using where` | `Using filesort` / `Using temporary` | 排序字段进索引；拆子查询 |

- 执行计划是**估算**，不替代实测；关键查询在预发用真实参数跑一次
- 一次只看一条 SQL；多表 join 逐个表看访问方式
- 深分页、批量写入、报表聚合必须单独评估，不能只看单表索引

## 4. 索引判据

- **最左前缀**：组合索引 `(a,b,c)` 只能从 `a` 开始用；where 里跳过 `a` 就等于没用
- **选择性**：不重复值 / 总行数；低于 10% 通常不值得单独建索引（先看数据分布）
- **覆盖索引**：查询列都在索引里可避免回表；只读接口优先考虑
- **冗余**：已有 `(a,b)` 时不再建 `(a)`；同一列上的单列索引要定期清理
- **写入成本**：每个索引都拖慢写入；新增索引要说明收益，删除索引要走评审
- **大表变更**：加索引 / 改结构用 online 或并发方式：`<!-- slot:db.online.ddl -->`

## 5. 方言差异（默认值，按项目裁剪）

| 项 | MySQL | Oracle | SQL Server | PostgreSQL |
| --- | --- | --- | --- | --- |
| 分页 | `LIMIT/OFFSET` | `FETCH FIRST` / `ROWNUM` | `OFFSET ... FETCH` | `LIMIT/OFFSET` |
| 空字符串 | `''` 与 `NULL` 不同 | `''` 即 `NULL` | `''` 与 `NULL` 不同 | `''` 与 `NULL` 不同 |
| 当前时间 | `NOW()` | `SYSDATE` | `GETDATE()` | `now()` |
| 执行计划 | `EXPLAIN` | `EXPLAIN PLAN` | `SET SHOWPLAN` | `EXPLAIN (ANALYZE)` |
| 批量写入 | 多值 `INSERT` | `INSERT ALL` | 表值参数 | `COPY` / 多值 |

**禁止**把一处方言的 SQL 直接复用到另一数据源。
本项目数据源与版本：`<!-- slot:db.sources -->`

## 6. 大表、批量与事务

- 单批上限建议 500–1000 行，按主键分段，可断点重跑
- 批量失败要能定位到具体批次；禁止整批吞异常
- 避免长事务：循环内不调用远程服务、不 sleep
- 大表 DDL 要提前说明锁表时间与执行窗口，并准备回滚
- 深分页改游标 / 延迟关联；报表类查询考虑离线表

## 7. 结论模板（写进 `summary.md` 的 `sql_review:`）

```text
sql_review: <表名> · 语法 <OK/失败> · 结构 <OK/缺 X> · 绑定 <#{} / 无 ${}> · 结果 <已验(fixture/参数) / 未验证(原因)> · 计划 <type=ref key=idx_x rows≈N / 未跑> · 结论 <通过 / 已改写 / 待 DBA>
```

示例：`sql_review: t_order · 语法 OK · 结构 OK · 绑定 #{} 无 ${} · 结果 已验(fixture 20 条) · 计划 type=ref key=idx_user_status rows≈120 · 通过`

## 8. 与 slow-sql 的分工

- 事前（改代码时）→ 本规范 + 技能 `biz-dev/14-sql-review`
- 事后（已变慢）→ `trouble-shooting/01-slow-sql`：日志拿完整 SQL → 执行计划 → 索引

## 证据锚点

<!-- slot:evidence - 至少一条 - [E2] 真实文件路径 :: 证明了什么 -->
