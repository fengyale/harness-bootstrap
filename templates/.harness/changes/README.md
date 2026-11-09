# 变更记录（changes）

每个特性 / 修复一个目录，**目录名与分支名 `feature/<名>` 一致**。

```
.harness/changes/<特性名>/
├── summary.md            （必须）
├── db-migrations.sql     （有 DDL/DML 变更时必须有）
└── rollback.sql          （与 db-migrations.sql 成对，缺一不可）
```

## 规则

1. **有迁移必配回滚**：`db-migrations.sql` 与 `rollback.sql` 必须成对存在，评审时检查。
2. **脚本可重复执行**，或失败时不留半完成状态（DDL 与 DML 分开、按序编号）。
3. **代码回滚先于数据修复**。
4. 部署完成后**回写** `summary.md` 的「部署记录」章节。
5. 特性交付后，把特性登记到 `.harness/rules/开发流程规范.md` 的「变更特性清单」和根 `AGENTS.md` 的文件索引。
6. **初始 `summary.md` 单独提交**：新增 summary 的提交只应包含 `.harness/` 下的文件，之后再提交代码。pre-commit 会拒绝「新增 summary + `.harness/` 之外的改动」同一个提交——git 看不到编辑顺序，提交顺序是唯一可判定的证据。

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
