# 加载覆盖率补齐 + 阶段门可用化 + flow 度量

- 日期：2026-10-29
- 需求来源：用户「P1 P2 一起改吧 记得同步所有文件所在地修正就行」
- 加载技能：`loaded_skills: none`（harness 自维护）
- 触及模块：`touched_modules: none`
- 流程档位：`flow: L2`
- 纠正次数：`corrections: 2`（① stage-gate 的 `compiles` / `tests-green` 若走 AUTO 会执行 AGENTS 里带 `<module>` 占位符的命令并误报，改为 HUMAN；② `Find-AgentsCommand` 原先只跳过以 `<` 开头的命令，改为跳过任何含占位符的命令）
- 教训编号：`lesson_id: rule-without-load-path`（同一教训第 2 次：规则只在索引里挂名、没有技能引用等于不存在）
- sql_review: 无 SQL 变更（仅脚本与文档改动）

## 改什么

**P1 加载覆盖率（5 份 0 引用 → 全部有触发者）**

| 文件 | 接进 |
| --- | --- |
| `.harness/rules/编码规范.md` | `coding-skill`（红线依据）、`expert-reviewer`（评审依据） |
| `.harness/wiki/业务模型.md` | `request-analysis` |
| `.harness/wiki/数据模型.md` | `request-analysis`、`04-sql-review` |
| `.harness/wiki/接口协议.md` | `request-analysis` |
| `.harness/wiki/环境与工具.md` | `01-slow-sql` |

**P2 度量与阶段门**

1. `scripts/metrics.ps1`：解析 summary 的 `flow:`，输出 L1/L2/L3 分布与缺 flow 数（文本 + `-Json` 的 `flows` / `flowMissing`）。
2. `scripts/stage-gate.ps1`：
   - 阶段定义重写为项目十阶段（1 需求 / 2 方案 / 3 编码 / 4 静态检查 / 5 测试 / 6 评审 / 7 合并 / 8 部署 / 9 验证 / 10 沉淀）
   - `red-lines` 判据改读 `.harness\metrics\gate.jsonl` 的最近一次 scan，不再全量扫描（存量 182 条违规会让门永远 BLOCKED）
   - `compiles` / `tests-green` 改为 HUMAN（AGENTS 里的命令带 `<module>` 占位符，自动执行会误报）
   - 新增 `verification-recorded` / `review-recorded` / `distill-recorded`
   - `summarySections` 对齐项目 summary 模板
3. 文档：`开发流程规范.md` 新增 3.1「阶段门（手动，合并前跑）」；`SKILL.md` 第 5 步改写；`harness-bootstrap流程图与机制详解.md` 边界第 9 条更新。
4. 模板同步：`templates` 的 `开发流程规范.md`、三个脚本；VERSION 1.18.0。

## 为什么

- `编码规范.md` 是红线依据，实测 0 处引用——不读它，红线只是口号。
- 业务/数据/接口三份 wiki 是影响面判断的依据，同样 0 引用。
- 阶段门原先读全量扫描，在本项目永远 BLOCKED，等于不可用；度量不统计 `flow:`，无法发现"所有任务都自称 L1"。

## 影响面

- 技能：5 个（coding-skill 55、request-analysis 44、expert-reviewer 47、04-sql-review 67、01-slow-sql 45 行）
- 脚本：`metrics.ps1`、`stage-gate.ps1`、`stage-gate-rules.json`
- 常驻：AGENTS.md 未改，仍 150 行
- 前端是否同步：不涉及

## 怎么验的

```powershell
scripts\metrics.ps1 -Root .
# tasks: 4 ... flow: L2=1   summaries without flow: 3

scripts\stage-gate.ps1 -Stage 1 -Feature workflow-tiering   # OPEN
scripts\stage-gate.ps1 -Stage 6 -Feature workflow-tiering   # OPEN
scripts\stage-gate.ps1 -Stage 7 -Feature workflow-tiering   # OPEN（AUTO 2 PASS / HUMAN 2）
scripts\verify-harness.ps1                                  # 34 PASS / 1 WARN / 0 FAIL
```

- 包与副本 `templates` 全量对比 diff = 0
- `stage-gate.ps1` 0 个非 ASCII 字节；`metrics.ps1` 仅 3 字节 UTF-8 BOM（PS 5.1 认 BOM，安全）

## 评审结论

未单独发起 agent 评审（脚本改动为判据逻辑，已用 4 个阶段实测 + verify-harness 验证）。

## 待沉淀

- [ ] 用一次真实需求验证 `flow:` 是否被正确填写（当前 4 个 summary 中 3 个缺 flow）
- [ ] `metrics.ps1` 复用的 `lesson_id: rule-without-load-path` 已出现 2 次，应晋升为一条常驻纪律或门禁
- [ ] 包仍未重打 zip