# CLAUDE.md

<!-- 平台入口文件。真源是 AGENTS.md，这里不要重写第二份规则，只导入。 -->
@AGENTS.md

## 技能加载

- 技能正文：`.harness/skills/<类>/<技能>/SKILL.md`
- 本平台的自动发现目录：`.claude/skills/`（安装时由 `scripts/setup-links.ps1 -Dest .claude\skills` 建立链接）
- 如果该目录不存在或为空：**先读 `.harness/skills/INDEX.md`**，按任务类别定位 1–2 个技能，再开始动手
- 技能没有命中时：不要凭记忆做，回到 `.harness/rules/开发流程规范.md` 的降级表

## 子智能体

本平台的子智能体入口在 `.claude/agents/`，内容与 `.trae/agents/` 同源；没有就按 `开发流程规范.md` 的自检清单替代。
