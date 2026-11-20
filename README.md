# PostgREST DB 驱动配置（SET pgrst.*）：结论清单

> 2026-11-18~19 在自部署 Supabase 栈（PG 17.6 / PostgREST v14.18）上逐条实测 + PG / PostgREST 源码级核验。

## 一句话

PostgREST 的配置可以存进数据库：`ALTER ROLE authenticator SET pgrst.键 = 值`——env 只是初始值。改配置**不碰 .env、不重建容器、零重启**，两条 SQL 秒级热生效。

## 三层回落链

```
① ALTER ROLE authenticator SET pgrst.键   ← DB 内（最高优先级，存 pg_db_role_setting）
② 环境变量 PGRST_*                        ← env（初始值/种子）
③ PostgREST 内置默认                       ← 兜底（db_schemas → "public"）
```

DB 里没设 → 用 env；env 也没设 → 用内置默认。分工：env 放不动的基础（URI、端口），DB 放会动的名单。

## 免重启配方（实测证据链）

```sql
ALTER ROLE authenticator SET pgrst.db_schemas = 'public, tenant_x';
NOTIFY pgrst, 'reload schema';   -- 秒级热生效
```

实测：设 `tenant_a` → `Accept-Profile` 查询 **200**；改回 `public` + 任意白名单 DDL → 日志 "Config reloaded" → **406**（热生效，未重启）；`RESET` → **404**（回落 env，一切如初）。

## GUC 占位符机制：为什么"查不到"也能 SET

`pgrst.*` 不是 PG 注册的参数，而是**自定义 GUC 占位符**（guc.c，REL_17_STABLE）：

| 环节 | 代码位置 | 行为 |
|---|---|---|
| 名字规则 | `valid_custom_variable_name()` L1078 | 注释原文 "It must be two or more identifiers separated by dots"——带点 = 占位符通道；**无点的未知名直接拒**（`SET nosuchparam` → unrecognized）|
| 写入路径 | `set_config_with_handle()` L3442 → `find_option(create_placeholders=true)` L1265 → `assignable_custom_variable_name()` L1123 → **"OK to create it"** L1162 → `add_placeholder_variable()` L1178 | SET / ALTER ROLE 时**现造一个占位符记录**：PGC_USERSET / GUC_CUSTOM_PLACEHOLDER，官方描述就叫 "GUC placeholder variable"（L1200）|
| 读取路径 | `GetConfigOption()` L4363 → `find_option(create_placeholders=false)` → L1276 直接报错 | SHOW **不造占位符** → 没设过就 unrecognized |
| 防伪保护 | `reserved_class_prefix` L1144-1160 | 占位符前缀不能撞已注册扩展的命名空间 |

**读写不对称 = "写入不需要登记、读取需要现场有值"**：SET 后占位符进 guc_hashtab，所以同会话 `SHOW` 能查到；新会话没设过则报错。

## PostgREST 侧的读取机制

- 只认 `pgrst.` 前缀（Config/Database.hs L42-43 `prefix = "pgrst."`）
- **白名单 23 键**（`dbSettingsNames` L46-72）：db_schemas、db_anon_role、db_max_rows、db_extra_search_path、jwt_secret、jwt_aud、jwt_role_claim_key、openapi_mode、server_cors_allowed_origins 等
- `queryDbSettings` L99-120 直读 `pg_db_role_setting`：`WHERE setrole = authenticator`，且**库级设置压角色级**（`DISTINCT ON key ORDER BY database DESC`）
- 读取时机：启动 + 每次 reload（NOTIFY pgrst 触发）——所以 ALTER ROLE 后要补一刀 NOTIFY

## 五个注意点（实测/源码）

1. **必须 `ALTER ROLE authenticator`**——`ALTER DATABASE` 无效（源码只查 setrole = authenticator 的行）
2. **ALTER ROLE 不自动触发重载**（不在 pgrst_ddl_watch 事件触发器白名单）——改完手动 `NOTIFY pgrst, 'reload schema'` 或搭一次任意白名单 DDL
3. **pg_dump 不备份它**——设置存于 pg_authid / pg_db_role_setting（集群级全局对象），普通 `pg_dump` 不含角色设置，恢复后丢失；把 ALTER 语句存档进迁移/运维脚本，或 `pg_dumpall --roles-only`
4. **拼错不报错**（如 `pgrst.db_schema` 少个 s）：存得进去、读不到，表现为"设了没反应"——改完必须验证 `rolconfig` + rest 日志出现 "Config reloaded"
5. **多实例一次生效**——多个 rest 指向同一 PG 时 pg_authid 共享，一次 ALTER ROLE 全体 reload 即一致；物理主备随 WAL 复制。比 .env 逐台改更优

## 为什么"DB 优先于 env"是设计而非缺陷

DB 是单一事实源：ALTER ROLE 一次 → 所有实例一致；env 是"每台机器各一份"的种子值。会动的配置放 DB、不动的基础放 env，正是官方期望的分工。真正的毛边在文档（备份丢失易踩）和触发联动（要手动 NOTIFY），不在优先级方向。

## 平台自己在用的同通道例子

```
ALTER DATABASE postgres SET app.settings.jwt_exp = 3600
```

同为从未"注册"过的占位符，Supabase 平台一直用它给 rest 传 JWT 过期时间——`app.settings.*` 是 app-settings 通道，`pgrst.*` 是配置通道，同一占位符机制的两次应用。

## 验证命令速查

```sql
SELECT rolconfig FROM pg_roles WHERE rolname = 'authenticator';   -- 查看当前设置
ALTER ROLE authenticator SET pgrst.db_schemas = 'public, tenant_x';
NOTIFY pgrst, 'reload schema';                                    -- 热生效
ALTER ROLE authenticator RESET pgrst.db_schemas;                  -- 删除（回到 env 控制）
```

```powershell
docker logs --since 1m supabase-rest   # 找 "Config reloaded" 行
```

## 配套实现

| 文件 | 用途 |
|---|---|
| [docs/auto-register.md](docs/auto-register.md) | **自动注册触发器落地指南**（建 tenant_* schema 自动进名单+热加载，含防注入三层与验证步骤）|
| [sql/auto_register_schema.sql](sql/auto_register_schema.sql) | 触发器实现（含防注入注释与卸载命令）|
| [sql/attack_test.sql](sql/attack_test.sql) | 注入验证载荷（逗号语义注入 + SQL 注入）|
| [sql/attack_cleanup.sql](sql/attack_cleanup.sql) | 验证后清理脚本 |

---
材料与出处：本部署 = docker-compose（postgrest/postgrest:v14.18 + PG 17.6）。**引用的全部源码快照随仓库提供（`evidence/` 目录，行号可直接核对）**——guc.c、user.c（PostgreSQL REL_17_STABLE，PostgreSQL License）、Database.hs（PostgREST v14.18，MIT），出处与许可证见 [evidence/SOURCES.md](evidence/SOURCES.md)。全部结论先实测后入档。
