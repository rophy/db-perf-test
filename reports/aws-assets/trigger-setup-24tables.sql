-- cleanup_duplicate_k trigger — extended to 24 tables for AWS runs.
-- Same semantics as reports/20260327_2224/trigger-setup.sql.

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
BEGIN
    FOR i IN 1..24 LOOP
        EXECUTE format(
            'CREATE OR REPLACE TRIGGER trg_cleanup_sbtest%s
             AFTER INSERT OR UPDATE ON sbtest%s
             FOR EACH ROW
             EXECUTE FUNCTION cleanup_duplicate_k()',
            i, i
        );
    END LOOP;
END;
$$;
