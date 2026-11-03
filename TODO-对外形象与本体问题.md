# harness-bootstrap 待办与问题清单

> 状态：讨论中，尚未动手。记录于 2026-11-03。
> 背景：仓库 https://github.com/fengyale/harness-bootstrap ，本机副本 v1.7.0，GitHub 为 v1.22.0。
> 作者本人账号 fengyale / King_Feng。

---

## A. 本体问题（"本身的问题"，后续单独讨论）

### A1. 本机副本落后 15 个版本
- 本机 `harness-bootstrap\` = v1.7.0；GitHub = v1.22.0
- 两个 zip（`harness-bootstrap-上传用.zip` / `harness-bootstrap.zip`）同为 1.7.0
- 缺失的关键能力：接地协议 + verify-grounding、metrics 度量闭环、lesson_id 晋升、行级 diff 门禁、SQL 评审门禁、平台适配层、模块卡、技能编译协议、包级自举门禁
- 待定：升级方式、是否保留本机定制内容、zip 重打

### A2. A7 无法自证
- 终点验收要两个 14 天窗口（≥28 天），中间缺强制触发机制
- 双周复盘目前是纯人力动作，无任何机制保障它发生
- 待定：是否把复盘半自动化（脚本检测窗口 + 预填数据）

### A3. 门禁判定天花板 + 代理指标代价
- 大部分红线是正则；`select *` / `not in` / 前导 `%` 只能 WARN
- SQL 用 `sql_review:` 字段做代理指标，但 `≥4 字符` 卡的是字符数不是质量
- 待定：是否要求 sql_review 附可执行计划证据或 EXPLAIN 输出引用路径

### A4. Windows-only 底座限制传播
- 主验证路径只有 Windows + PS 5.1
- `probe-project` / `stage-gate` / `verify-*` / `setup-links` 内部是 Windows 分隔符，未适配
- `red-line-scan.py` 只覆盖一个脚本；门禁层跨 OS，体检层没有
- 优点：Windows 上跑到"退出码可判定"比 Linux 上做十个脚本难
- 待定：走 Windows 深化还是补跨平台

### A5. 元技能本身的上手摩擦
- 21 个脚本 + 16 篇 reference + 7 条阶段门 + 10 个阶段 + 26 条契约
- "用 harness-bootstrap 搭 harness"的启动成本高
- README 的"60 秒试一下"只覆盖"看它自检通过"，没覆盖"真的用它搭一次"
- 待定：是否做"最小可用档"（3 脚本 + 1 AGENTS.md + 3 技能）

### A6. 平台矩阵落后生态
- 现有：TRAE / Claude Code / Codex / CodeBuddy / 未知
- 缺：DSH / Cursor / Cline / Windsurf / Codex CLI 等
- 探测逻辑按目录名硬编码（`.trae/` `.claude/` …）
- 好消息：三模式降级结构已把问题结构化，加平台主要是加表不改架构

### A7. 契约维护是线性增长的债
- 26 条契约是人手写的规则锁，随内容增长线性增加
- 契约断言的是"五处文本包含某字符串"，不保证语义一致
- 待定：能否从"检查五处一致"升级为"单一真源自动派生其余"

---

## B. 对外形象 / 开源传播（当前讨论中）

### B1. 账号身份没有辨识度
- `fengyale` / King_Feng：无 profile 信息（name/bio/twitter 全空），无头像辨识度
- 账号创建于 2026-07-25，仅 1 个公开仓库，0 follower
- 仓库只有 5 次提交，全在同一天（2026-11-03）——历史看不出持续投入
- 问题：读者第一次点进来时，看不出"这是谁写的、为什么可信"

### B2. README 的"劝退感"
- 结尾："如果你也经历过…这个仓库值得一个 star，也值得一次试用" —— 自我评价式结语，且"值得一次试用"直接降低行动号召
- 通篇克制到近乎疏离；没有"读者画像"、"目标读者是谁"、"为什么现在需要它"
- "30 秒看懂"表格用"你现在的状态 / 装上之后"两栏，起点是"用户很痛"，不是"读者能得到什么"

### B3. 缺 Demo / 缺具象证据
- 仓库内零图片、零截图、零 gif
- 没有"装上去长什么样"的目录树实拍、没有 before/after 对比、没有真实 gate 拦截输出
- README 的"你会看到"只给文本输出，无视觉冲击
- 对一个讲"可预测性"的项目，缺"用之前 vs 用之后"的具象对比

### B4. 缺可信度锚点（social proof）
- 无 star / fork / watch / contributor 数据展示
- 无"谁在用"的场景描述（医保项目在 changelog 里提过，但没写进对外材料）
- 无 demo 链接、无外部引用

### B5. 中英混杂与文件名语言
- README 中英混排（标题中文、表格英文、结尾中文）
- `references/` 15 个文件名全是中文（两周复盘.md、接地协议.md…）
- 影响英文读者 / 搜索引擎 / 跨平台协作
- 注：`templates/.harness/rules/` 下的中文文件名是设计选择（内容本身中文），不算问题

### B6. 仓库结构对陌生读者的可见性差
- `templates/` 26 个技能骨架对首次访问者是一堵墙（但正文标了 slot 骨架）
- 首次访问者难以判断"这里面到底有什么、我要不要用"
- 103 个文件 / 72 个 md，README 定位为"发布包"而非"项目主页"

### B7. 名字与仓库的自我矛盾
- 仓库叫 `harness-bootstrap`，但内容是"完整的 harness 元技能 + 自带门禁 + CI"
- 名字像"启动脚本"，实际是"框架 + 工具链"
- 讨论方向：保留 bootstrap（保留"从零起步"的叙事）还是改名体现"完整体系"

### B8. 缺"为什么现在"的时间锚点
- 无"2024 至今 AI 编码经历了什么变化"这类时代定位
- 仓库创建于 2026-07-25，5 次提交都在 2026-11-03 同一天
- 读者无法建立"这个东西是被真实使用打磨出来的"的感觉

### B9. 缺 CHANGELOG.md / Releases
- changelog 只在 `VERSION` 文件里（298 行，含大量中文）
- GitHub Releases 页是空的
- 对"版本迭代快"的印象（本项目 v1.0 → v1.22 迭代 22 个版本）反而没被利用

### B9b. 缺 ISSUE_TEMPLATE / PR 模板 / Discussions
- `.github/` 只有 `workflows/verify.yml`
- 没有 issue 模板、PR 模板、Discussions 分类
- 降低外部贡献意愿

### B10. 无 Badges
- 零 badge：build 状态、license、version、平台
- CI 已经在跑（windows-latest 跑自检 + 行为测试），badge 化零成本

---

## C. 待用户决策的问题

1. 目标读者是谁？（中文开发者 / 英文开发者 / 两者）
2. 目标读者画像：团队 leader / 独立开发者 / AI 编程重度用户？
3. 仓库名是否保留 `harness-bootstrap`？
4. 是否做英文版（或英文 README）？
5. 账号要不要重新定位（profile / 名字 / 头像 / bio）？
6. README 是否需要中英双版本？
7. 是否做一个可复现的完整落地案例（裸仓库 → A1–A7 全绿全过程日志）？
8. 合并推理（merged PR）类型？上游是 kimi / 适合合并的方案？
9. 账号要不要同时保留个人账号 + 一个组织（org）账号？
10. 是否要在 README 里公开"失败案例 / 踩坑"（"两周复盘"）?

---

## D. 已确认的技术事实（供后续引用）

- DSH 技能加载根目录：`~/.dsh/skills`（当前不存在）、`~/.agents/skills`（已有 13 个）
- DSH 会读 `~/.trae-cn/skills`（TRAE 那套），但语义不对
- TRAE 插件级 skills：`~/.trae-cn/plugins/trae-remote-official/office-plugin/0.1.0/skills/{docx,pdf,pptx,xlsx}`
- 本机 PS 版本 5.1（脚本按此编写）
- GitHub 仓库：5 commits、1 tag (v1.22.0)、1 star、0 fork、0 watcher
- GitHub: 103 files、72 md、19 ps1、2 py
