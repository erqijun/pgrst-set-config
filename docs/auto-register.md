# 自动注册触发器：落地指南

> 目标：新建 `tenant_*` schema 时，自动追加进 `pgrst.db_schemas` 并通知 PostgREST 热加载——全程零重启、零人工。
> 全部步骤已在真实部署上实测（PG 17.6 / PostgREST v14.18，2026-11-20）。

## 0. 你会得到什么

```
CREATE SCHEMA tenant_x;
-- → NOTICE: auto_register: tenant_x 已注册进 pgrst.db_schemas
-- → rest 几秒内热加载，Accept-Profile: tenant_x 即刻可用
```

不匹配 `tenant_*` 前缀或名字带特殊字符的 schema 会被白名单拒收（WARNING 提示），绝不进 API 名单。

## 1. 前提条件

| 条件 | 为什么 |
|---|---|
| superuser（自部署即 supabase_admin）| `CREATE EVENT TRIGGER` 仅超管（与平台自带 pgrst_ddl_watch 同理）；`ALTER ROLE authenticator` 也需要 |
| 一次性种子 | 名单从 env 移交 DB 管理；**无种子时触发器只警告不猜值**（防止用猜测值悄悄遮蔽 env 名单）|
| 不依赖平台触发器 | 本方案自带 NOTIFY——pgrst_ddl_watch 在不在都能工作 |

## 2. 第一步：种子初始化（一次性）

```sql
-- 值必须与你当前 .env 的 PGRST_DB_SCHEMAS 一致（此后 DB 是名单唯一事实源）
ALTER ROLE authenticator SET pgrst.db_schemas = 'public, graphql_public';

-- 验证
SELECT rolconfig FROM pg_roles WHERE rolname = 'authenticator';
-- 预期含 "pgrst.db_schemas=public, graphql_public"
```

## 3. 第二步：安装触发器

把 [sql/auto_register_schema.sql](../sql/auto_register_schema.sql) 全文复制执行（psql / Studio SQL 编辑器均可），它做三件事：

```sql
-- ① CREATE FUNCTION extensions.auto_register_schema()  —— SECURITY DEFINER + 固定 search_path=pg_catalog
-- ② ALTER FUNCTION ... OWNER TO supabase_admin
-- ③ CREATE EVENT TRIGGER pgrst_auto_schema_register ON ddl_command_end
```

## 4. 第三步：验证（四组）

### 4.1 正常注册

```sql
CREATE SCHEMA tenant_ok;
-- 预期 NOTICE: auto_register: tenant_ok 已注册进 pgrst.db_schemas（public, graphql_public, tenant_ok）

SELECT split_part(unn, '=', 2) FROM (
  SELECT unnest(rolconfig) unn FROM pg_roles WHERE rolname = 'authenticator'
) s WHERE unn LIKE 'pgrst.db_schemas=%';
-- 预期: public, graphql_public, tenant_ok
```

### 4.2 幂等（删了重建不重复）

```sql
DROP SCHEMA tenant_ok;
CREATE SCHEMA tenant_ok;
-- 名单保持单条 tenant_ok，无重复
```

### 4.3 注入攻击（应全部被拒）

执行 [sql/attack_test.sql](../sql/attack_test.sql)：

```sql
CREATE SCHEMA "tenant_evil, secret";                          -- 语义注入：想偷渡 secret 进名单
CREATE SCHEMA "tenant_x'; DROP SCHEMA public CASCADE; --";    -- SQL 注入载荷
```

预期：两条 WARNING（不在白名单）；schema 会建出来（证明载荷真实到达）但**名单原封不动**。
再验证 API 侧拒收：

```bash
curl 'https://<你的host>/rest/v1/anything' -H "apikey: <anon_key>" \
     -H "Accept-Profile: tenant_evil, secret"     # 预期 406
```

验证完用 [sql/attack_cleanup.sql](../sql/attack_cleanup.sql) 清理（注意把其中复位值改成你的种子）。

### 4.4 端到端

```sql
CREATE TABLE tenant_ok.invoices (id int, tenant_id text, amount int);
GRANT USAGE ON SCHEMA tenant_ok TO anon, authenticated;
GRANT SELECT ON tenant_ok.invoices TO anon, authenticated;
```

```bash
curl 'https://<你的host>/rest/v1/invoices?select=*' -H "apikey: <anon_key>" \
     -H "Accept-Profile: tenant_ok"    # 预期 200
docker logs --since 1m supabase-rest   # 预期出现 Config reloaded
```

## 5. 防注入：为什么"能保证"

| 层 | 挡什么 | 机制 |
|---|---|---|
| ① 白名单 `^tenant_[a-z0-9_]{0,58}$` | **语义注入**（逗号名偷渡——rest 按逗号拆名单，转义挡不住这类）+ **SQL 注入**（引号/分号）| 数据唯一入口 |
| ② `format %L` | SQL 注入 | 值整体按字面量转义，语句不可能拼接逃逸 |
| ③ SECURITY DEFINER 加固 | 定义者函数劫持 | 固定 `search_path=pg_catalog`、对象全限定、event_trigger 返回类型天然不可 SELECT 直调 |

改白名单只改正则一行——建议保持"前缀 + 小写字母数字下划线"形态，**永不放开逗号**。

## 6. 日常使用：开一个新租户（完整五步）

```sql
CREATE SCHEMA tenant_x;                                    -- ① 自动注册（本指南的全部意义）
-- 以下四步与普通 schema-per-tenant 相同
GRANT USAGE ON SCHEMA tenant_x TO anon, authenticated;     -- ② 开大门
CREATE TABLE tenant_x.invoices (...);                      -- ③ 建表
GRANT SELECT ON tenant_x.invoices TO anon, authenticated;  -- ④ 开房门
ALTER TABLE tenant_x.invoices ENABLE ROW LEVEL SECURITY;   -- ⑤ 上 RLS 锁（+ 策略，每租户 schema 仍必须）
```

## 7. 卸载

```sql
DROP EVENT TRIGGER pgrst_auto_schema_register;
DROP FUNCTION extensions.auto_register_schema();
ALTER ROLE authenticator RESET pgrst.db_schemas;   -- 名单交还 env
NOTIFY pgrst, 'reload schema';
```

## 8. 边界与注意事项

| 事项 | 说明 |
|---|---|
| DROP SCHEMA 不摘名 | 名单留死名无害（rest 容忍不存在的 schema）；要自动摘需另加 sql_drop 事件触发器 |
| ALTER SCHEMA RENAME 不跟踪 | 改名后旧名留在名单 |
| 触发器抛错会中止你的 DDL | 函数内每命令有 EXCEPTION 兜底——只 WARNING、不影响建表 |
| 并发建 schema | `pg_advisory_xact_lock` 串行化读-改-写，无丢更新 |
| 扩展安装的 schema | 不会误注册（command_tag 为 CREATE EXTENSION，且白名单把关）|
| 别放开白名单到"所有 schema" | 扩展/内部 schema 会涌进 API 面，表名经 OpenAPI 泄露 |
| Windows 测试注入的坑 | PowerShell→docker exec 传引号载荷会被拆碎——注入测试走文件（docker cp + psql -f）字节保真 |

## 9. 实测记录

2026-11-20，自部署 Supabase（PG 17.6 / PostgREST v14.18）：正常注册 ✅、幂等 ✅、逗号语义注入拒收 ✅、SQL 注入载荷拒收 ✅、无前缀拒收 ✅、API 侧 406 ✅、端到端 200 + Config reloaded ✅。完整分析见作者主文档《整体架构与源码导读》§14.9。
