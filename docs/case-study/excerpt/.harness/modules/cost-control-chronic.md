# cost-control-chronic（模块卡片）

> 按需加载。最近更新：2026-10-27

## 职责

慢病相关业务实现；也是**全仓库唯一使用 `@Transactional` 的模块**，事务写法以它为准。

## 关键入口

| 类 | 作用 |
| --- | --- |
| `MenTeService` | 慢病业务实现（含唯一的事务注解） |

## 依赖与数据

- 主库 `oracle`；写入方式为 JFinal
- 药占比相关字段在 `MED_PATIENT_INFO.DRUG_FEE_RATE`

## 重点

- 多表写入前**先看 `MenTeService` 的事务写法**，沿用同一种，不新造第三种
- 药占比计算需剔除诊断为 **Z51** 开头的病例
- 离院方式剔除仅在特定 HIS + 字典开关下生效（默认关闭）

## 难点

- 事务只标了一半写入 → 半提交
- 药占比剔除规则依赖字典开关 `DRUG_EXCLUDE_LEAVEWAY_FLAG`，不能硬编码
- 离院方式数据源填充率极低，命中与否要写进验证记录

## 坑点

- 新增 `@Transactional` 不写 `rollbackFor` → 受检异常不回滚（R5）
- 认为剔除逻辑一定生效 → 实际字典开关默认 '0'（关闭）
- 改药占比口径只改 SQL、不同步文档 → 下次对账对不上

## 验证方式

```powershell
mvn -q -pl cost-control-chronic -am -DskipTests compile
# 药占比接口与手工 SQL 对账，确认 Z51 剔除与离院方式开关
```

## 证据锚点

- [E2] cost-control-chronic/src/main/java/com/example/mi/chronic/service/mente/MenTeService.java :: 唯一 @Transactional 与慢病实现
- [E2] .trae/rules/project_rules.md :: 药占比与离院方式剔除约束

## 待确认

- `TODO(待确认)`：慢病申请状态机与状态码