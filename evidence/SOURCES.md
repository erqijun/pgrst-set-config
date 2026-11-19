# 代码证据：源码快照与出处

README 中引用的全部行号都可在本目录文件中直接核对（行号与快照逐字节一致）。

| 文件 | 来源 | 版本 | 许可证 | README 引用的行 |
|---|---|---|---|---|
| [guc.c](guc.c) | [PostgreSQL 源码](https://github.com/postgres/postgres/blob/REL_17_STABLE/src/backend/utils/misc/guc.c) | REL_17_STABLE 分支（2026-11-19 快照；本部署为 PG 17.6 同大版本） | [PostgreSQL License](https://www.postgresql.org/about/licence/) | L1073/1078（valid_custom_variable_name）、L1123（assignable_custom_variable_name）、L1162（"OK to create it"）、L1178（add_placeholder_variable）、L1200（"GUC placeholder variable"）、L1237（find_option）、L1276-1281（unrecognized 报错）、L3442（set_config_with_handle，create_placeholders=true）、L4363（GetConfigOption，create_placeholders=false） |
| [user.c](user.c) | [PostgreSQL 源码](https://github.com/postgres/postgres/blob/REL_17_STABLE/src/backend/commands/user.c) | 同上 | 同上 | L1080（`AlterSetting()` —— ALTER ROLE SET 落库 pg_db_role_setting） |
| [Database.hs](Database.hs) | [PostgREST 源码](https://github.com/PostgREST/postgrest/blob/main/src/PostgREST/Config/Database.hs) | v14.18（与本部署镜像 postgrest/postgrest:v14.18 一致） | MIT | L42-43（`prefix = "pgrst."`）、L46-72（dbSettingsNames 白名单 23 键）、L99-120（queryDbSettings：直读 pg_db_role_setting 的 SQL） |

## 关键函数速查

```
guc.c
├── valid_custom_variable_name()        L1078  名字规则：两个以上标识符、点分隔
├── assignable_custom_variable_name()  L1123  未知名可否被 SET（带点=可，"OK to create it"）
├── add_placeholder_variable()          L1178  现造占位符（PGC_USERSET / GUC_CUSTOM_PLACEHOLDER）
├── find_option()                       L1237  create_placeholders 开关决定 SET/SHOW 行为差异
├── set_config_with_handle()            L3408  SET/ALTER ROLE 执行引擎（L3442 传 true）
└── GetConfigOption()                   L4358  SHOW 底层（L4363 传 false）
user.c
└── AlterRoleSet → AlterSetting()       L1080  ALTER ROLE SET 写 pg_db_role_setting
Database.hs
└── queryDbSettings                     L94    SELECT ... FROM pg_db_role_setting WHERE setrole=CURRENT_USER
```

## 快照获取方式（可复现）

```
curl.exe -s https://raw.githubusercontent.com/postgres/postgres/REL_17_STABLE/src/backend/utils/misc/guc.c -o guc.c
curl.exe -s https://raw.githubusercontent.com/postgres/postgres/REL_17_STABLE/src/backend/commands/user.c -o user.c
# Database.hs 取自 postgrest/postgrest v14.18 源码树 src/PostgREST/Config/Database.hs
```

注：guc.c / user.c 文件头部保留 PostgreSQL 版权声明；许可证要求重分发时保留该声明——本快照未做任何改动。
