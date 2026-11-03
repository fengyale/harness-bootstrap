# datasource（模块卡片）

> 按需加载。最近更新：2026-10-27

## 职责

多数据源接入（JFinal `Db.use`）+ **Redis 统一入口**。

## 关键入口

| 类 | 作用 |
| --- | --- |
| `DatasourceConstant` | 数据源 key 常量 |
| `RedisUtils` | 唯一缓存入口（业务层不直接操作缓存客户端） |

## 依赖与数据

- 数据源：`oracle`（主库）/ `dzblOracle`（病历）/ `mssql`（HIS）+ intersysCache / mysql / postgresql / thirdOracle
- 连接信息在 `application-dev.properties`，**不写进 wiki**
- Redis key 由调用方拼好后传入，没有全局前缀校验

## 重点

- 一律 `Db.use(DatasourceConstant.xxx)`，key 不能写字符串字面量
- 缓存读写只走 `RedisUtils`
- 高频 INSERT：`MED_MEDICAL_MZ_INFO` 用 `Db.save` **两参**重载

## 难点

- 跨库查询/连接切换没有统一封装，写错 key 不会编译报错
- `Db.save` 三参会生成 `RETURNING INTO`，高频调用导致子游标暴涨、CPU 100%
- 分库分表的 key 与普通 key 混用

## 坑点

- 业务代码里直接 `redisTemplate.opsForValue()` → 绕过统一封装，key/TTL 失控
- 新增数据源只改 properties、没登记 `DatasourceConstant` → 运行期才报错
- 在循环里逐条 `Db.save` → 子游标与性能双爆

## 验证方式

```powershell
mvn -q -pl datasource -am -DskipTests compile
# 检查改动里没有直接操作缓存客户端
Select-String -Path <改动文件> -Pattern 'redisTemplate|Jedis'
```

## 证据锚点

- [E2] datasource/src/main/java/com/example/datasource/redis/RedisUtils.java :: 缓存唯一入口
- [E2] datasource/src/main/java/com/example/datasource/constant/DatasourceConstant.java :: 数据源 key
- [E2] .trae/rules/project_rules.md :: 高频 INSERT / RETURNING INTO 约束