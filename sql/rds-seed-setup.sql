-- ============================================================
-- RDS 种子角色配方（BYPASSRLS 可得性——2026-11-21 实测三步定案）
--
-- Provider 一次性操作（= 云工单/控制台，仅此一次）：
--   ① 种子必须 CREATEROLE + BYPASSRLS 双属性——
--      仅 BYPASSRLS 会被 CREATE ROLE 的 CREATEROLE 检查拦截（实测）
--   ② 仅授成员资格不够（has_bypassrls_privilege 认属性不认 membership，实测）——
--      使用时须 SET ROLE 变身（current_user 带上属性）
--   ③ 安全面：NOLOGIN 不可直连；仅授权成员可变身；变身窗口内才有属性
-- ============================================================

CREATE ROLE svc_seed NOLOGIN CREATEROLE BYPASSRLS;
GRANT svc_seed TO root;

-- ============================================================
-- 平台供给管道（root 执行，每个项目自动化）
-- ============================================================
-- SET ROLE svc_seed;
--   CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
--   GRANT service_role TO authenticator;
--   GRANT SELECT ON ... TO service_role;
-- RESET ROLE;
--
-- 实测效果：service_role 绕 RLS 见全表（2 行）；对照 authenticated 0 行
-- REPLICATION 属性同配方可用（user.c L333 同款检查，需 REPLICATION+CREATEROLE）
-- ============================================================
