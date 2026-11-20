-- 测试清理：删除攻击/演示 schema，名单复位为种子值
-- 注意：最后一行的复位值应改成你自己的种子（本仓库示例为 public, graphql_public）
DROP SCHEMA IF EXISTS "tenant_evil, secret" CASCADE;
DROP SCHEMA IF EXISTS "tenant_x'; DROP SCHEMA public CASCADE; --" CASCADE;
DROP SCHEMA IF EXISTS myapp CASCADE;
DROP SCHEMA IF EXISTS tenant_ok CASCADE;
ALTER ROLE authenticator SET pgrst.db_schemas = 'public, graphql_public';
NOTIFY pgrst, 'reload schema';
