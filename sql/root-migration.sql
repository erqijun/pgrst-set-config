-- ============================================================
-- root 迁移脚本（以 supabase_admin 执行——它的最后一班岗）
-- 目标：root 接替 supabase_admin 的日常职责，但【不是超管】
-- ============================================================

-- ① 复制槽现状（检查用）
SELECT slot_name, slot_type, active FROM pg_replication_slots;

-- ② root 降权 + 属性（CREATEROLE 管角色 / REPLICATION 管 WAL / BYPASSRLS 管查询）
ALTER ROLE root NOSUPERUSER CREATEROLE REPLICATION BYPASSRLS;

-- ③ 回填 memberships（对齐官方降权模式）
--    supabase_privileged_role = 可改保留角色（authenticator 等）的设置——pgrst.db_schemas 管理必需
GRANT supabase_privileged_role TO root;
GRANT pg_monitor TO root;
--    组件 admin 角色（NOINHERIT——按需 SET ROLE 进入，不自动生效）
GRANT supabase_auth_admin, supabase_storage_admin, supabase_functions_admin, supabase_realtime_admin TO root;

-- ④ 库级 CREATE（postgres 库的 owner 是 postgres 角色，显式授给 root）
GRANT CREATE ON DATABASE postgres TO root;

-- ⑤ realtime 全部对象 → root（postgres 库内）
ALTER SCHEMA realtime OWNER TO root;
ALTER SCHEMA _realtime OWNER TO root;
ALTER PUBLICATION supabase_realtime OWNER TO root;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT c.oid, c.relkind, c.relname, n.nspname
           FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
           WHERE n.nspname IN ('realtime','_realtime') AND c.relkind IN ('r','p','S','v','m')
  LOOP
    IF r.relkind = 'S' THEN
      EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO root', r.nspname, r.relname);
    ELSE
      EXECUTE format('ALTER TABLE %I.%I OWNER TO root', r.nspname, r.relname);
    END IF;
  END LOOP;
END $$;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
           WHERE n.nspname IN ('realtime','_realtime')
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO root', r.oid::regprocedure);
  END LOOP;
END $$;

-- ⑥ supavisor 全部对象 → root（_supabase 库内）
ALTER DATABASE _supabase OWNER TO root;
\c _supabase
ALTER SCHEMA _supavisor OWNER TO root;
ALTER SCHEMA _analytics OWNER TO root;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT c.oid, c.relkind, c.relname, n.nspname
           FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
           WHERE n.nspname IN ('_supavisor','_analytics') AND c.relkind IN ('r','p','S','v','m')
  LOOP
    IF r.relkind = 'S' THEN
      EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO root', r.nspname, r.relname);
    ELSE
      EXECUTE format('ALTER TABLE %I.%I OWNER TO root', r.nspname, r.relname);
    END IF;
  END LOOP;
END $$;
\c postgres

-- ⑦ 自动注册触发器函数 → root（此后 definer=root：非超管但持 privileged_role，可改 authenticator 设置）
ALTER FUNCTION extensions.auto_register_schema() OWNER TO root;
