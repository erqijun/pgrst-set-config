-- ============================================================
-- 自动注册触发器：新建 tenant_* schema 时自动追加进 pgrst.db_schemas
--                    并通知 PostgREST 热加载
--
-- 前置种子（一次性，与 .env 名单保持一致；此后 DB 成为名单唯一事实源）：
--   ALTER ROLE authenticator SET pgrst.db_schemas = 'public, graphql_public';
--
-- 防注入三层：
--   ① 白名单正则 ^tenant_[a-z0-9_]{0,58}$
--      逗号被挡 = 防语义注入（rest 按逗号拆名单，名字带逗号会偷渡别的 schema）
--      引号/分号被挡 = 防 SQL 注入
--   ② format %L：值按 SQL 字面量规则转义，语句不可能被拼接逃逸
--   ③ SECURITY DEFINER + 固定 search_path=pg_catalog + 对象全限定
--      防定义者函数经典劫持（search_path 劫持 / 恶意对象替换）
--
-- 卸载：
--   DROP EVENT TRIGGER pgrst_auto_schema_register;
--   DROP FUNCTION extensions.auto_register_schema();
--   ALTER ROLE authenticator RESET pgrst.db_schemas;  -- 名单交还 env
-- ============================================================

CREATE OR REPLACE FUNCTION extensions.auto_register_schema()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER                      -- 以 owner（超管）身份执行；普通建表用户触发的 DDL 也能完成注册
SET search_path = pg_catalog          -- 【第 3 层】固定搜索路径，防劫持
AS $$
DECLARE
  cmd         record;
  schema_name text;
  entries     text[];
  cur_val     text;
  new_val     text;
  per_db      boolean := false;
BEGIN
  FOR cmd IN SELECT * FROM pg_event_trigger_ddl_commands()
  LOOP
    BEGIN  -- 每条命令独立兜底：事件触发器抛错会中止用户的 DDL，绝不能连带
      IF cmd.command_tag <> 'CREATE SCHEMA' THEN
        CONTINUE;
      END IF;

      -- 从 objid 直取原始 schema 名（不经 object_identity 的引号格式化）
      SELECT n.nspname INTO schema_name
      FROM pg_catalog.pg_namespace n
      WHERE n.oid = cmd.objid;

      -- 【第 1 层：白名单】只收 tenant_ 前缀 + 小写字母/数字/下划线
      IF schema_name IS NULL
         OR schema_name !~ '^tenant_[a-z0-9_]{0,58}$' THEN
        RAISE WARNING 'auto_register: 跳过 schema %（不在白名单）', schema_name;
        CONTINUE;
      END IF;

      -- 并发防护：读-改-写期间只允许一个注册在跑（事务级咨询锁）
      PERFORM pg_advisory_xact_lock(hashtext('pgrst_auto_schema_register'));

      -- 读当前生效值（per-database 设置优先，与 PostgREST queryDbSettings 优先级一致）
      SELECT s.setconfig INTO entries
      FROM pg_catalog.pg_db_role_setting s
      WHERE s.setrole = 'authenticator'::regrole
        AND s.setdatabase = (SELECT oid FROM pg_catalog.pg_database
                             WHERE datname = current_database());
      IF entries IS NOT NULL THEN
        per_db := true;
      ELSE
        SELECT s.setconfig INTO entries
        FROM pg_catalog.pg_db_role_setting s
        WHERE s.setrole = 'authenticator'::regrole
          AND s.setdatabase = 0;
      END IF;

      SELECT regexp_replace(e, '^pgrst\.db_schemas=', '')
        INTO cur_val
      FROM unnest(entries) e
      WHERE e LIKE 'pgrst.db_schemas=%'
      LIMIT 1;

      -- 没有种过子就不猜值（避免悄悄遮蔽 env 名单），提示先初始化
      IF cur_val IS NULL THEN
        RAISE WARNING 'auto_register: authenticator 无 pgrst.db_schemas 存储值，先执行种子初始化';
        CONTINUE;
      END IF;

      -- 幂等：已在名单则跳过
      IF EXISTS (SELECT 1
                 FROM unnest(string_to_array(cur_val, ',')) p
                 WHERE btrim(p) = schema_name) THEN
        CONTINUE;
      END IF;

      new_val := cur_val || ', ' || schema_name;

      -- 【第 2 层：format %L】值整体按字面量转义进语句
      IF per_db THEN
        EXECUTE format('ALTER ROLE authenticator IN DATABASE %I SET pgrst.db_schemas = %L',
                       current_database(), new_val);
      ELSE
        EXECUTE format('ALTER ROLE authenticator SET pgrst.db_schemas = %L', new_val);
      END IF;

      -- 兜底通知（平台 pgrst_ddl_watch 对 CREATE SCHEMA 也会发；重复一次成本毫秒级）
      PERFORM pg_catalog.pg_notify('pgrst', 'reload schema');

      RAISE NOTICE 'auto_register: % 已注册进 pgrst.db_schemas（%）', schema_name, new_val;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'auto_register: 处理 % 时出错（已忽略，不影响你的 DDL）: %', schema_name, SQLERRM;
    END;
  END LOOP;
END;
$$;

ALTER FUNCTION extensions.auto_register_schema() OWNER TO supabase_admin;

-- 事件触发器（创建需要超管——与平台的 pgrst_ddl_watch 同理）
CREATE EVENT TRIGGER pgrst_auto_schema_register
ON ddl_command_end
EXECUTE FUNCTION extensions.auto_register_schema();
