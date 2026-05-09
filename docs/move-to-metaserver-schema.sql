-- Run this as the database owner or another role with CREATE privilege on dbrobert
-- and ownership/alter privileges on the public objects.

BEGIN;

CREATE SCHEMA IF NOT EXISTS metaserver AUTHORIZATION robert;

COMMENT ON SCHEMA metaserver IS
    'MetaServer application schema for auth, member management, broker linkage, trading, and audit data.';

DO $$
DECLARE
    obj record;
BEGIN
    FOR obj IN
        SELECT tablename
        FROM pg_tables
        WHERE schemaname = 'public'
        ORDER BY tablename
    LOOP
        EXECUTE format('ALTER TABLE public.%I SET SCHEMA metaserver', obj.tablename);
    END LOOP;

    FOR obj IN
        SELECT t.typname
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public'
          AND t.typtype = 'e'
        ORDER BY t.typname
    LOOP
        EXECUTE format('ALTER TYPE public.%I SET SCHEMA metaserver', obj.typname);
    END LOOP;

    FOR obj IN
        SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'ms_generate_uuid'
    LOOP
        EXECUTE format('ALTER FUNCTION public.%I(%s) SET SCHEMA metaserver', obj.proname, obj.args);
    END LOOP;
END $$;

ALTER ROLE robert IN DATABASE dbrobert SET search_path = metaserver, public;

COMMIT;
