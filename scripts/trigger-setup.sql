-- Trigger for sysbench write amplification test
-- Dynamically attaches to ALL sbtest* tables found in the database.
-- Fires on: INSERT, UPDATE (per row)
--
-- Logic: After each INSERT or UPDATE, look up an older row with the same
-- `k` value. If found, delete it. Simulates a "keep only the latest per key"
-- cleanup pattern, adding 1 indexed read + up to 1 delete per write.

CREATE OR REPLACE FUNCTION cleanup_duplicate_k()
RETURNS TRIGGER AS $$
DECLARE
    old_id INTEGER;
BEGIN
    EXECUTE format('SELECT id FROM %I WHERE k = $1 AND id < $2 LIMIT 1', TG_TABLE_NAME)
    INTO old_id
    USING NEW.k, NEW.id;

    IF old_id IS NOT NULL THEN
        EXECUTE format('DELETE FROM %I WHERE id = $1', TG_TABLE_NAME)
        USING old_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    tbl TEXT;
BEGIN
    FOR tbl IN
        SELECT tablename FROM pg_tables
        WHERE schemaname = 'public' AND tablename LIKE 'sbtest%'
        ORDER BY tablename
    LOOP
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER trg_cleanup_%s
             AFTER INSERT OR UPDATE ON %I
             FOR EACH ROW
             EXECUTE FUNCTION cleanup_duplicate_k()',
            tbl, tbl
        );
        RAISE NOTICE 'Trigger installed on %', tbl;
    END LOOP;
END;
$$;
