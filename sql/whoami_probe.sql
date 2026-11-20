-- 一次性探针：SECURITY DEFINER 内外身份对比（跑完即删）
CREATE OR REPLACE FUNCTION public._whoami() RETURNS text
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog
AS $$ SELECT '函数内: current_user=' || current_user || '（= 函数owner）' $$;
