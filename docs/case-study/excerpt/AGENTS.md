# 医保质控系统（后端） AI 编码约束

> 唯一常驻文件，只放「每轮必须」的内容：技术栈、必跑命令、红线、索引与纪律。
> 权威约束见 `.trae/rules/project_rules.md`；项目知识（业务模型 / 数据模型 / 接口协议 / 环境工具）见 `.harness/wiki/`。
> 前端是独立工程 `insurance-web`（同工作区），其上下文见该工程的 `AGENTS.md`。

## 1. 定位

医保质控后端：与 HIS 对接做医嘱 / 费用的实时合规校验，违规进入 预审 → 内审 → 复审 → 申诉。完整架构与模块清单见 `项目介绍文档.md`。
接口：WebService（SOAP / XML，对 HIS）+ RESTful `/api`（`{code, msg, data}`，成功码 0）；同步接口前缀 `/syncApi`。

## 2. 技术栈

| 层级 | 技术 |
| --- | --- |
| 语言 / 运行时 | Java / JDK 1.8 |
| 后端框架 | Spring Boot 2.0.6 + Spring Cloud Finchley.SR2 + **JFinal ORM（非 MyBatis / JPA）** + EasyRules + Quartz |
| 数据库 / 缓存 | Oracle（主库 / 病历库）+ MSSQL（HIS）+ Redis + Druid；消息中间件 TODO(待确认) |
| 前端 | 独立工程 `insurance-web`：layui 2.x + jQuery 3.2.1（无构建工具） |
| 构建 | Maven 多模块（12 个 module） |

## 3. 必跑命令（每次改完必须验证）

| 用途 | 命令 |
| --- | --- |
| 编译 / 打包 | `mvn -q -pl <module> -am -DskipTests compile`；全量 `mvn clean package -DskipTests` |
| 测试 | 全量 `mvn -q test`（现存仅 2 个 `*Test.java`）；单个 `mvn -q test -Dtest=<XxxTest>` |
| Lint / 格式化 | TODO(待确认)：项目暂未配置静态检查 |
| 本地启动 | `app-main` 的 `cn.com.example.BasicInfoApplication`，端口 **8082** |
| 红线（增量） | `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\red-line-scan.ps1 -Files <改动文件>` |
| 自检 | `verify-harness.ps1`（结构）· `verify-grounding.ps1`（证据与路径）· `metrics.ps1`（度量） |

- 环境：`app-main/src/main/resources/application.properties` → `spring.profiles.active`（当前 `dev`）
- `mvn` 命令来自原有文档，首次实际执行后把输出补进 `.harness/changes/`

## 4. 🔴 红线（不可违反）

> 图例：🔴 红线（零容忍）｜🟡 强烈建议。每条必须能脚本判定，否则只是口号。
> 编号与 `scripts/red-line-rules.json`、`.harness/rules/编码规范.md` 一一对应。

| # | 红线 | 检查方法（可执行） |
| --- | --- | --- |
| R3 | 异常必须走统一异常体系 | `-Rules R3`；或搜 `throw new (RuntimeException\|IllegalStateException\|IllegalArgumentException\|Exception)` |
| R4 | 禁止字段注入 | `-Rules R4`；或搜 `@Autowired` 后紧跟 `private` |
| R5 | 事务必须声明回滚范围 | `-Rules R5`；或搜 `@Transactional(` 无 `rollbackFor` |
| R6 | 禁止敏感信息入日志 | `-Rules R6`；或搜日志语句含 `password\|token\|mobile` |

- **R1 / R2 / R7 不启用**：本项目 0 个 XML 映射文件（JFinal），缓存 Key 统一封装在 `RedisUtils`，启用只会误报
- **冲突处理**：立即停止 → 修复 → 从受影响阶段重验；禁止"先合入后续再改"

## 5. 数据源

用 `com.example.datasource.constant.DatasourceConstant` 的 key 配 `Db.use(key)`：`oracle`（主库）· `dzblOracle`（病历）· `mssql`（HIS）。连接见 `application-dev.properties`；查表与核对数据用 MCP。详见 `.harness/wiki/数据模型.md`。

## 6. 环境与工具

MCP 工具链、安装路径与凭据位置、文档索引 → `.harness/wiki/环境与工具.md`（改环境先改那份 wiki）。

## 7. 文件索引

**规则**（`.harness/rules/`）：`编码规范.md`（红线证据）· `工程结构.md`（12 module / 分层）· `开发流程规范.md`（10 阶段 / L1–L3 链路 / 质量门 / 自查清单）；权威约束 `.trae/rules/project_rules.md`

**技能**（`.harness/skills/`）：`main-dev/request-analysis` · `main-dev/coding-skill` · `main-dev/expert-reviewer` · `main-dev/soap-endpoint-verify`（接口实测） · `biz-dev/rule-engine`（改规则先读） · `biz-dev/03-redis-cache` · `biz-dev/04-sql-review` · `biz-dev/05-transaction-consistency` · `trouble-shooting/01-slow-sql`；索引 `README.md`

**项目事实**（`.harness/wiki/`）：`领域术语.md`（术语映射）· `业务模型.md`（规则入口 / EasyRules / 业务流）· `数据模型.md`（数据源 key）· `接口协议.md`（`/api`、`/syncApi`、WebService）· `环境与工具.md`（MCP / 文档索引）

**模块卡**（`.harness/modules/`）：`<module>.md`（重点 / 难点 / 坑点）；索引 `README.md`

**变更与门禁**：`.harness/changes/<特性>/summary.md`（改什么 / 为什么 / 影响面 / 怎么验 + 度量字段）· `.trae/agents/*.md`（评审 / 审计子智能体）· `.git/hooks/pre-commit`（只扫新增行）· `scripts/red-line-scan.ps1`

## 8. AI 编码纪律

- **加载范围**：默认只读「本任务涉及的模块卡 + 直接相关的 1–2 份 wiki / 规则」；**技能与模块卡不占此额度**，按流程必上
- **超限例外**：跨模块改造、数据迁移、上线评审可多读，在 summary 写一行「额外读取：… ｜ 原因：…」
- **单次变更 ≤ 文件总量 40%**，超过必须拆分；改完必过第 3 节命令
- **必上技能**：收到需求先加载 `request-analysis`；动代码先加载 `coding-skill`；合并前加载 `expert-reviewer`
- **涉及 SQL 必评审（必上技能）**：新增/修改 SQL、加索引、改分页或批量写入时**必须**加载 `04-sql-review`，按步骤评估后写 `sql_review:`（pre-commit 校验，缺则拒提交）
- **涉及规则链必读**：加规则、改拦截口径、改退费/放行时先加载 `biz-dev/rule-engine`，确认走门诊/住院/上传哪条链，并按"抓放成对"同步 `SyncHandleDelayService`
- **改完接口/规则必实测**：用 `main-dev/soap-endpoint-verify` 打真实报文，以返回报文证明命中，不许"只看代码就说好了"
- **未加载技能不许凭印象编码**；`.harness/skills/README.md` 里没有的技能，按“技能缺失”处理并说明
- **每任务留痕**：`.harness/changes/<特性>/summary.md` 必须含 `corrections:` 与 `loaded_skills:`