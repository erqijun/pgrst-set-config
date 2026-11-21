-- ============================================================
-- RDS 扩展开关控制器——三种级别
--
-- 前提：非受信扩展由超管预装（init 一次性）→  PG 进程里 .so 已加载
-- 问题：如何让 root（非超管）控制扩展的"开关"？
--
-- 级别 A：GRANT/REVOKE（开关"使用权"——最安全，零超管依赖）
-- 级别 B：SECURITY DEFINER 开关函数（开关"存在性"——代理超管做 CREATE/DROP）
-- 级别 C：supautils privileged_extensions（最接近 Studio 原生体验——需控制 conf）
--
-- 实测验证：级别 A 在原生 PG 上完全可行
-- ============================================================

-- ============================================================
-- 级别 A：使用权开关（推荐——任何管理员都能干）
-- ============================================================
-- "开" = 授权角色可以调用扩展的函数
-- "关" = 撤销授权（扩展还在，但没人能调用 → 功能面 = 0）

CREATE OR REPLACE FUNCTION extensions.toggle_access(
  p_ext_schema text,
  p_grant_to   text,
  p_on         boolean
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  -- 白名单：只允许已知的扩展 schema
  IF p_ext_schema NOT IN ('pg_net', 'cron', 'graphql', 'pgsodium', 'vault', 'extensions') THEN
    RAISE EXCEPTION 'Schema % not in toggle whitelist', p_ext_schema;
  END IF;

  -- 【防注入】角色名用 format %I 转义
  IF p_on THEN
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', p_ext_schema, p_grant_to);
    EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO %I', p_ext_schema, p_grant_to);
    RETURN format('ENABLED: %I -> %I', p_ext_schema, p_grant_to);
  ELSE
    EXECUTE format('REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA %I FROM %I', p_ext_schema, p_grant_to);
    EXECUTE format('REVOKE USAGE ON SCHEMA %I FROM %I', p_ext_schema, p_grant_to);
    RETURN format('DISABLED: %I -X %I', p_ext_schema, p_grant_to);
  END IF;
END $$;

ALTER FUNCTION extensions.toggle_access(text, text, boolean) OWNER TO root;
REVOKE ALL ON FUNCTION extensions.toggle_access(text, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION extensions.toggle_access(text, text, boolean) TO root;
