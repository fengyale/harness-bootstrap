---
name: request-analysis
description: 需求分析与拆解：把一句话需求转成可验证的任务清单，判断落在哪个模块、影响哪些接口与表。收到新需求或变更、进入开发之前使用。
---

# 需求分析

> **本文件是骨架**：`<!-- slot:… -->` 必须在安装时用项目事实替换，替换不到就整条删除。

## 何时用

- 用户说"加个功能 / 改个逻辑 / 优化一下"，且改动可能跨文件或跨模块
- 需求里出现业务词但含义不明确

> **先定档，再选记录方式**：按 `.harness/rules/开发流程规范.md` 第 1.1 节选 `L0 / L1 / L2 / L3`。
> L0 不建记录；L1 只在 `.harness/changes/_small.md` 追加一行；L2/L3 才建 `summary.md`。拿不准就升档。

## 项目绑定（编译时替换）

- 模块划分与归属规则：<!-- slot:module.map -->
- 模块卡片目录（定位到模块后先读）：<!-- slot:module.cards -->
- 领域词表位置：<!-- slot:domain.terms -->
- 接口形态与返回结构：<!-- slot:api.contract -->

## 模式（跨技术栈不变）

### 步骤

1. 复述需求，写成**一句可验证的验收描述**
2. 定位模块，列出受影响的接口、表、前端页面
3. 与项目硬约束比对，冲突先报，不自行取舍
4. 按档位落盘：L0 不建记录；L1 在 `.harness/changes/_small.md` 追加一行（字段按表头填齐）；L2/L3 **复制** `.harness/changes/_template/summary.md` 到 `.harness/changes/<特性>/summary.md` 再填
5. L2/L3 填完骨架先跑 `check-summary.ps1 -Feature <特性> -Stage initial`；不通过不得开始编码。L1 的 `_small.md` 行由 `metrics.ps1` 解析。`/plan` 模式的计划要复制进对应记录，不能只留在工具的计划面板
6. 无法确认的标 `TODO(待确认)`，**开工前只问一次**

### 检查项

- [ ] 模块归属明确
- [ ] 影响面是否含前端 / 其他仓库
- [ ] 是否触碰项目红线
- [ ] 档位已定：L0 无记录 / L1 已追加 `_small.md` 行 / L2-L3 已建 summary.md
- [ ] L2/L3 的 `check-summary -Stage initial` 已通过（未通过不得进入编码）

### 常见错误

- 不判断模块直接改代码 → 改错层，返工
- 术语按字面理解，与代码实体对不上

## 证据锚点（编译后填写）

<!-- slot:evidence - 至少一条 - [E2] 真实文件路径 :: 证明了什么 -->
