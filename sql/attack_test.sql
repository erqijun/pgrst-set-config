-- 注入攻击载荷（真实到达 PG，看触发器挡不挡）
-- 载荷一：逗号语义注入——rest 按逗号拆名单，若注册成功会偷渡 secret 进 API 名单
CREATE SCHEMA "tenant_evil, secret";
-- 载荷二：经典 SQL 注入——引号+分号，若拼接语句会执行 DROP SCHEMA public CASCADE
CREATE SCHEMA "tenant_x'; DROP SCHEMA public CASCADE; --";
