-- ============================================================
-- RDS 模式 Supabase-lite 部署（以 root = RDS admin 执行，appdb）
-- 前提：Phase 1 已建角色（authenticator/anon/authenticated/service_role）
-- 产出：auth 函数 + 业务表 RLS + 表驱动配置（pre_config 路线）
-- ============================================================

-- ① auth schema + JWT 辅助函数（源：GoTrue 迁移 20220531120530 原文）
CREATE SCHEMA auth;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql stable AS
$$ SELECT COALESCE(
     NULLIF(current_setting('request.jwt.claim', true), ''),
     NULLIF(current_setting('request.jwt.claims', true), '')
   )::jsonb $$;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql stable AS
$$ SELECT NULLIF(auth.jwt()->>'sub', '')::uuid $$;
GRANT EXECUTE ON FUNCTION auth.jwt() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;

-- ② 业务表 + RLS 租户隔离（模式①）
CREATE TABLE public.orders (id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, tenant_id text NOT NULL, amt int NOT NULL);
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.orders TO anon, authenticated;
CREATE POLICY tenant_isolation ON public.orders TO authenticated
  USING (tenant_id = (auth.jwt()->'app_metadata'->>'tenant_id'));
INSERT INTO public.orders (tenant_id, amt) VALUES ('a', 100), ('b', 200);

-- ③ 表驱动配置（RDS 路线：普通表 + set_config，绕开参数 ACL 高墙）
CREATE SCHEMA app_config;
GRANT USAGE ON SCHEMA app_config TO authenticator;
CREATE TABLE app_config.pgrst_config (name text PRIMARY KEY, value text NOT NULL);
GRANT SELECT ON app_config.pgrst_config TO authenticator;
CREATE OR REPLACE FUNCTION app_config.pre_config() RETURNS void LANGUAGE plpgsql AS
$$ DECLARE r record; BEGIN
  FOR r IN SELECT name, value FROM app_config.pgrst_config LOOP
    PERFORM set_config('pgrst.' || r.name, r.value, false);
  END LOOP; END $$;
GRANT EXECUTE ON FUNCTION app_config.pre_config() TO authenticator;
INSERT INTO app_config.pgrst_config VALUES ('db_schemas', 'public');
