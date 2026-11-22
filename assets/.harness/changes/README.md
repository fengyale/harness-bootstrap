# 变更记录（changes）

每个特性 / 修复一个目录，**目录名即特性名**（与分支名无关，分支只是标签）。

```
.harness/changes/<特性名>/
├── summary.md            （必须）
├── evidence/             （可选：编译日志、EXPLAIN、查询结果摘要、截图）
├── sql-review/           （可选：SQL 评审证据，summary 只引用路径）
├── db-migrations.sql     （有 DDL/DML 变更时必须有）
└── rollback.sql          （与 db-migrations.sql 成对，缺一不可）
```

## 规则

1. **有迁移必配回滚**：`db-migrations.sql` 与 `rollback.sql` 必须成对存在，评审时检查。
2. **脚本可重复执行**，或失败时不留半完成状态（DDL 与 DML 分开、按序编号）。
3. **代码回滚先于数据修复**。
4. **交付终态写进 `delivery_status`**：`已部署` 时「部署记录」必须有至少一行真实内容；`已交付未提交` / `已提交未部署` / `不适用` 写清原因即可，不再让部署记录永远空白。
5. **跨仓特性各留一份 summary**：每个仓库的 `.harness/changes/<特性名>/summary.md` 用自己的 `linked_records` 指向另一个仓库的记录（`repo:path` 或 URL，多个用逗号分隔；无跨仓记录写 `-`）。门禁只校验字段存在且非占位，不要求能访问另一个仓库。
6. **证据放 `evidence/`**：编译日志、EXPLAIN、查询结果摘要、截图放 `.harness/changes/<特性名>/evidence/`，summary 只引用路径。除已有的 `sql_review` 证据锚点外不新增硬门禁。
7. 特性交付后，把特性登记到 `.harness/rules/开发流程规范.md` 的「变更特性清单」和根 `AGENTS.md` 的文件索引。
8. **初始 `summary.md` 单独提交**：新增 summary 的提交只应包含 `.harness/` 下的文件，之后再提交代码。pre-commit 会拒绝「新增 summary + `.harness/` 之外的改动」同一个提交——git 看不到编辑顺序，提交顺序是唯一可判定的证据。
9. **源码提交要能归因**：特性名按 `HARNESS_TASK=<名>` → `check-summary -Feature <名>` 自动写入的 `.git/harness-current-task` → 唯一变更目录 的顺序解析，**与分支名无关**；HEAD 必须先有 `.harness/changes/<名>/summary.md`；L1 则在同一提交里改 `_small.md`。多个目录且未显式声明时跳过并记入 `gate.jsonl`；L0 / 一次性导入用 `HARNESS_ALLOW_NO_RECORD=1` 显式放行。

## `db-migrations.sql` 模板

```sql
-- <特性名> 数据库变更
-- 环境执行顺序：test → staging → production
-- 幂等：可重复执行；如不可重复执行，必须在注释里写明前置条件

-- 1) DDL（先结构）
-- ALTER TABLE `xxx` ADD COLUMN `yyy` INT NOT NULL DEFAULT 0 COMMENT '说明';

-- 2) DML（后数据）
-- UPDATE `xxx` SET `yyy` = 0 WHERE `yyy` IS NULL;
```

## `rollback.sql` 模板

```sql
-- <特性名> 回滚脚本（与 db-migrations.sql 逆序执行）
-- 注意：删列/删表会造成数据不可恢复，执行前必须确认已备份

-- 2') 逆序回滚 DML
-- 1') 逆序回滚 DDL
-- ALTER TABLE `xxx` DROP COLUMN `yyy`;
```
