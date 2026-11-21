-- ============================================================
-- RDS 自动化管道：schema 注册/注销（替代事件触发器的手动等效）
-- 原理：事件触发器在 RDS 上建不了（超管专属）→ 退化为管道显式调用
-- 安全：写普通表（无参数 ACL / 无保留角色 / 无超管依赖）
-- 白名单校验 + 幂等 + format 防护——与触发器版同等安全标准
-- ============================================================

-- 注册：管道在 CREATE SCHEMA 后调用
CREATE OR REPLACE FUNCTION app_config.register_schema(p_schema text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, app_config
AS $$
DECLARE
  v_current text;
  v_new text;
BEGIN
  -- 【防注入①】白名单：与触发器版同标准
  IF p_schema IS NULL OR p_schema !~ '^tenant_[a-z0-9_]{0,58}$' THEN
    RAISE WARNING 'register_schema: 跳过 %（不在白名单）', p_schema;
    RETURN 'SKIPPED';
  END IF;

  SELECT value INTO v_current FROM app_config.pgrst_config WHERE name = 'db_schemas';
  IF v_current IS NULL THEN
    RAISE WARNING 'register_schema: 无 db_schemas 配置行，先 INSERT 初始值';
    RETURN 'NO_CONFIG';
  END IF;

  -- 幂等
  IF EXISTS (SELECT 1 FROM unnest(string_to_array(v_current, ',')) t WHERE btrim(t) = p_schema) THEN
    RETURN 'ALREADY_REGISTERED';
  END IF;

  v_new := v_current || ', ' || p_schema;
  UPDATE app_config.pgrst_config SET value = v_new WHERE name = 'db_schemas';
  PERFORM pg_notify('pgrst', 'reload schema');
  RETURN v_new;
END $$;

-- 注销：管道在 DROP SCHEMA 后调用（清理死名）
CREATE OR REPLACE FUNCTION app_config.unregister_schema(p_schema text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, app_config
AS $$
DECLARE
  v_current text;
  v_parts text[];
  v_new text;
BEGIN
  SELECT value INTO v_current FROM app_config.pgrst_config WHERE name = 'db_schemas';
  IF v_current IS NULL THEN RETURN 'NO_CONFIG'; END IF;

  SELECT string_agg(btrim(t), ', ') INTO v_new
  FROM unnest(string_to_array(v_current, ',')) t
  WHERE btrim(t) <> p_schema;

  UPDATE app_config.pgrst_config SET value = v_new WHERE name = 'db_schemas';
  PERFORM pg_notify('pgrst', 'reload schema');
  RETURN v_new;
END $$;

-- 授权：管道（root）使用；不给 PUBLIC
REVOKE ALL ON FUNCTION app_config.register_schema(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app_config.unregister_schema(text) FROM PUBLIC;
