-- ============================================================
-- pre_config 路线验证（v2）：RDS 兼容的"表驱动热配置"
-- v1 教训：public schema 的 CREATE 被平台收紧（root 有库级 CREATE，
--          但 public 是 pg_database_owner 的——不影响正确性，换专用 schema）
-- 部署差异：本栈挂钩经 ALTER ROLE（有 supautils）；RDS 上同一挂钩走
--          PGRST_DB_PRE_CONFIG env——效果完全相同。
-- ============================================================

-- ① 专用 schema + 配置表（普通表：无参数 ACL、无保留角色、无超管依赖）
CREATE SCHEMA app_config;
GRANT USAGE ON SCHEMA app_config TO authenticator;
CREATE TABLE app_config.pgrst_config (name text PRIMARY KEY, value text NOT NULL);
GRANT SELECT ON app_config.pgrst_config TO authenticator;

-- ② pre_config 函数：rest 读配置时把表值 set_config 进会话（USERSET，无墙）
CREATE OR REPLACE FUNCTION app_config.pre_config() RETURNS void
  LANGUAGE plpgsql
AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT name, value FROM app_config.pgrst_config
  LOOP
    PERFORM set_config('pgrst.' || r.name, r.value, false);
  END LOOP;
END $$;
GRANT EXECUTE ON FUNCTION app_config.pre_config() TO authenticator;

-- ③ 挂钩 + 腾位置（RDS 上③改用 PGRST_DB_PRE_CONFIG=app_config.pre_config）
ALTER ROLE authenticator SET pgrst.db_pre_config = 'app_config.pre_config';
ALTER ROLE authenticator RESET pgrst.db_schemas;

-- ④ 表接管 db_schemas（基线）
INSERT INTO app_config.pgrst_config VALUES ('db_schemas', 'public, graphql_public');
NOTIFY pgrst, 'reload schema';
