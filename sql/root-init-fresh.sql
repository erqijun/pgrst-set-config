-- ============================================================
-- 从零部署版 root 初始化（db 首启后、组件启动前，以 supabase_admin 执行）
-- 用法：psql -U supabase_admin -v root_pw='<POSTGRES_PASSWORD>' -f root-init-fresh.sql
-- 与在用版的差异：组件尚未启动——它们的对象将由首启时的 root 原生创建，无需事后易主
-- ============================================================

-- ① root：非超管 + 三属性
CREATE ROLE root LOGIN PASSWORD :'root_pw' CREATEROLE REPLICATION BYPASSRLS;

-- ② 回填 memberships（supabase_privileged_role=可改保留角色设置）
GRANT supabase_privileged_role TO root;
GRANT pg_monitor TO root;
-- 组件 admin：平台 init 只建 auth/storage/functions 三个；supabase_realtime_admin 由
-- realtime 首启自建——存在才授（\gexec 条件执行），避免全新库上此句报错把后面截断
GRANT supabase_auth_admin, supabase_storage_admin, supabase_functions_admin TO root;
SELECT 'GRANT supabase_realtime_admin TO root'
 WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname='supabase_realtime_admin') \gexec

-- ③ 库级 CREATE（realtime 首启要在 postgres 库建对象）
GRANT CREATE ON DATABASE postgres TO root;

-- ④ 平台 init 已建对象 → root（此后组件首启即以 root 建/用）
ALTER SCHEMA realtime OWNER TO root;
ALTER SCHEMA _realtime OWNER TO root;
ALTER DATABASE _supabase OWNER TO root;
-- 【实战修订 ①】init 还预建了 _supabase 库内的 _supavisor / _analytics schema
--   ——漏了这步 pooler 首启会 42501 crash-loop（Ecto 无建表权限）
\c _supabase
ALTER SCHEMA _supavisor OWNER TO root;
SELECT 'ALTER SCHEMA _analytics OWNER TO root'
 WHERE EXISTS (SELECT 1 FROM pg_namespace WHERE nspname='_analytics') \gexec
\c postgres
SELECT 'ALTER PUBLICATION supabase_realtime OWNER TO root'
 WHERE EXISTS (SELECT 1 FROM pg_publication WHERE pubname='supabase_realtime') \gexec

-- 【实战修订 ②】supabase_realtime_admin 不由 init 建（realtime 首启自建），
--   但 supautils 保留角色保护会挡住非超管的 CREATE ROLE → 该角色缺席；
--   realtime 仅跳过 migrations dump（migrations_ran=0），功能无碍——已知边界，无需处理
