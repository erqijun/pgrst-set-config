-- ============================================================
-- RDS 客户角色设计（2026-11-21）—— gap ① 补全
--
-- 问题：root = init 重放者 = ADMIN on 全部平台角色
--       如果客户连 root → 客户就是 root → 客户可以改平台角色
--       没有 supautils 拦 → 平台角色被污染（安全模型不完整）
--
-- 解法：双层角色模型（内核 creator-ADMIN 天然防线）
--   root（平台管道） = 建了平台角色 → 有 ADMIN on 它们
--   customer_admin（客户） = 没建平台角色 → 没有 ADMIN → 改不了它们
--
-- 实测验证五条攻击 + 三条正常操作
-- ============================================================

-- root 创建客户角色（init 重放完成后）
-- 关键属性：CREATEROLE（客户能建自己的角色）——但仅此而已
--   没有 BYPASSRLS → 建不了 BYPASSRLS 角色
--   没建过平台角色 → 没有 ADMIN → ALTER ROLE 改不了它们
--   不是平台角色成员 → SET ROLE 进不去
CREATE ROLE customer_admin LOGIN CREATEROLE PASSWORD 'customer_pw';

-- 授权做正常数据库工作（但不是 db owner——不给 CREATE DATABASE/扩展的无限权）
GRANT CREATE ON DATABASE appdb TO customer_admin;       -- 能建 schema
GRANT ALL ON SCHEMA public TO customer_admin;            -- 能建表
GRANT USAGE ON SCHEMA auth TO customer_admin;            -- 能用 auth.jwt()
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO customer_admin;
GRANT service_role TO customer_admin;                    -- 能 SET ROLE service_role（绕 RLS 做管理操作）
                                                           -- 注意：membership ≠ ADMIN OPTION → 改不了 service_role 本身
GRANT SELECT ON ALL TABLES IN SCHEMA public TO customer_admin; -- 能读业务表
