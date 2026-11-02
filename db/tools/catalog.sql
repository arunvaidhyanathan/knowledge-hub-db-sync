-- Structured, deterministic schema catalog as one JSON document.
-- Usage: psql -X -At -v ON_ERROR_STOP=1 -v schemas='app,entitlement' -f db/tools/catalog.sql
-- Read-only: queries pg_catalog only. Output keys are sorted by jsonb; arrays are ORDER BY name.
WITH target AS (
  SELECT n.oid, n.nspname
  FROM pg_namespace n
  WHERE n.nspname = ANY (string_to_array(:'schemas', ','))
),
rels AS (
  SELECT c.oid, t.nspname AS schema, c.relname AS name, c.relkind, c.relrowsecurity
  FROM pg_class c
  JOIN target t ON t.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
    AND NOT c.relispartition
    AND NOT EXISTS (SELECT 1 FROM pg_depend d
                    WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
),
cols AS (
  SELECT a.attrelid AS relid,
         jsonb_agg(jsonb_build_object(
           'name', a.attname,
           'type', format_type(a.atttypid, a.atttypmod),
           'notNull', a.attnotnull,
           'default', pg_get_expr(d.adbin, d.adrelid),
           'identity', NULLIF(a.attidentity::text, ''),
           'generated', NULLIF(a.attgenerated::text, ''),
           'comment', col_description(a.attrelid, a.attnum)
         ) ORDER BY a.attnum) AS columns
  FROM pg_attribute a
  JOIN rels r ON r.oid = a.attrelid
  LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
  WHERE a.attnum > 0 AND NOT a.attisdropped
  GROUP BY a.attrelid
),
cons AS (
  SELECT con.conrelid AS relid,
         jsonb_agg(jsonb_build_object(
           'name', con.conname,
           'type', con.contype::text,
           'definition', pg_get_constraintdef(con.oid, true)
         ) ORDER BY con.conname) AS constraints
  FROM pg_constraint con
  JOIN rels r ON r.oid = con.conrelid
  GROUP BY con.conrelid
),
idx AS (
  SELECT i.indrelid AS relid,
         jsonb_agg(jsonb_build_object(
           'name', ic.relname,
           'unique', i.indisunique,
           'definition', pg_get_indexdef(i.indexrelid)
         ) ORDER BY ic.relname) AS indexes
  FROM pg_index i
  JOIN rels r ON r.oid = i.indrelid
  JOIN pg_class ic ON ic.oid = i.indexrelid
  WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c
                    WHERE c.conindid = i.indexrelid AND c.contype IN ('p', 'u', 'x'))
  GROUP BY i.indrelid
),
trg AS (
  SELECT tg.tgrelid AS relid,
         jsonb_agg(jsonb_build_object(
           'name', tg.tgname,
           'definition', pg_get_triggerdef(tg.oid, true)
         ) ORDER BY tg.tgname) AS triggers
  FROM pg_trigger tg
  JOIN rels r ON r.oid = tg.tgrelid
  WHERE NOT tg.tgisinternal
  GROUP BY tg.tgrelid
),
pol AS (
  SELECT p.polrelid AS relid,
         jsonb_agg(jsonb_build_object(
           'name', p.polname,
           'command', p.polcmd::text,
           'using', pg_get_expr(p.polqual, p.polrelid),
           'check', pg_get_expr(p.polwithcheck, p.polrelid)
         ) ORDER BY p.polname) AS policies
  FROM pg_policy p
  JOIN rels r ON r.oid = p.polrelid
  GROUP BY p.polrelid
),
tables AS (
  SELECT jsonb_agg(jsonb_build_object(
           'schema', r.schema,
           'name', r.name,
           'kind', CASE r.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned_table'
                                  WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized_view'
                                  WHEN 'f' THEN 'foreign_table' END,
           'comment', obj_description(r.oid, 'pg_class'),
           'rowSecurity', r.relrowsecurity,
           'columns', COALESCE(c.columns, '[]'::jsonb),
           'constraints', COALESCE(k.constraints, '[]'::jsonb),
           'indexes', COALESCE(i.indexes, '[]'::jsonb),
           'triggers', COALESCE(t.triggers, '[]'::jsonb),
           'policies', COALESCE(p.policies, '[]'::jsonb),
           'viewDefinitionMd5', CASE WHEN r.relkind IN ('v', 'm') THEN md5(pg_get_viewdef(r.oid, true)) END
         ) ORDER BY r.schema, r.name) AS v
  FROM rels r
  LEFT JOIN cols c ON c.relid = r.oid
  LEFT JOIN cons k ON k.relid = r.oid
  LEFT JOIN idx i ON i.relid = r.oid
  LEFT JOIN trg t ON t.relid = r.oid
  LEFT JOIN pol p ON p.relid = r.oid
),
enums AS (
  SELECT jsonb_agg(jsonb_build_object('schema', x.schema, 'name', x.name, 'values', x.vals)
                   ORDER BY x.schema, x.name) AS v
  FROM (
    SELECT t.nspname AS schema, ty.typname AS name,
           jsonb_agg(e.enumlabel ORDER BY e.enumsortorder) AS vals
    FROM pg_type ty
    JOIN target t ON t.oid = ty.typnamespace
    JOIN pg_enum e ON e.enumtypid = ty.oid
    GROUP BY t.nspname, ty.typname
  ) x
),
seqs AS (
  SELECT jsonb_agg(jsonb_build_object(
           'schema', s.schemaname, 'name', s.sequencename, 'type', s.data_type::text,
           'start', s.start_value, 'increment', s.increment_by, 'cycle', s.cycle
         ) ORDER BY s.schemaname, s.sequencename) AS v
  FROM pg_sequences s
  WHERE s.schemaname = ANY (string_to_array(:'schemas', ','))
),
funcs AS (
  SELECT jsonb_agg(jsonb_build_object(
           'schema', t.nspname,
           'name', p.proname,
           'kind', p.prokind::text,
           'arguments', pg_get_function_identity_arguments(p.oid),
           'returns', pg_get_function_result(p.oid),
           'definitionMd5', md5(pg_get_functiondef(p.oid))
         ) ORDER BY t.nspname, p.proname, pg_get_function_identity_arguments(p.oid)) AS v
  FROM pg_proc p
  JOIN target t ON t.oid = p.pronamespace
  WHERE p.prokind IN ('f', 'p')
    AND NOT EXISTS (SELECT 1 FROM pg_depend d
                    WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
),
exts AS (
  SELECT jsonb_agg(jsonb_build_object('name', e.extname, 'version', e.extversion, 'schema', n.nspname)
                   ORDER BY e.extname) AS v
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
)
SELECT jsonb_build_object(
  'formatVersion', 1,
  'serverMajorVersion', current_setting('server_version_num')::int / 10000,
  'schemas', (SELECT COALESCE(jsonb_agg(nspname ORDER BY nspname), '[]'::jsonb) FROM target),
  'extensions', COALESCE((SELECT v FROM exts), '[]'::jsonb),
  'tables', COALESCE((SELECT v FROM tables), '[]'::jsonb),
  'enums', COALESCE((SELECT v FROM enums), '[]'::jsonb),
  'sequences', COALESCE((SELECT v FROM seqs), '[]'::jsonb),
  'functions', COALESCE((SELECT v FROM funcs), '[]'::jsonb)
)::text;
