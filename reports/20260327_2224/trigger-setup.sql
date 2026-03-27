-- Trigger + Stored Procedure for sysbench write amplification test
-- Applied to: sbtest1 through sbtest10
-- Fires on: INSERT, UPDATE (per row)
--
-- Logic: After each INSERT or UPDATE, look up an older row with the same
-- `k` value. If found, delete it. Simulates a "keep only the latest per key"
-- cleanup pattern, adding 1 indexed read + up to 1 delete per write.
--
-- Cluster spec when tested:
--   3 tservers, 2 vCPU (1 pinned P-core), 8 GB RAM each
--   dm-delay=5ms, IOPS cap=80
--   Workload: write-heavy (2 point_selects, 20 index_updates, 20 non_index_updates)

-- Step 1: Create the trigger function
CREATE OR REPLACE FUNCTION cleanup_duplicate_k()
RETURNS TRIGGER AS $$
DECLARE
    old_id INTEGER;
BEGIN
    -- Point select: find an older row with the same k value
    EXECUTE format('SELECT id FROM %I WHERE k = $1 AND id < $2 LIMIT 1', TG_TABLE_NAME)
    INTO old_id
    USING NEW.k, NEW.id;

    -- Conditional delete: remove the older duplicate
    IF old_id IS NOT NULL THEN
        EXECUTE format('DELETE FROM %I WHERE id = $1', TG_TABLE_NAME)
        USING old_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Step 2: Attach trigger to all 10 sysbench tables
DO $$
BEGIN
    FOR i IN 1..10 LOOP
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

-- To remove triggers:
-- DO $$
-- BEGIN
--     FOR i IN 1..10 LOOP
--         EXECUTE format('DROP TRIGGER IF EXISTS trg_cleanup_sbtest%s ON sbtest%s', i, i);
--     END LOOP;
-- END;
-- $$;
-- DROP FUNCTION IF EXISTS cleanup_duplicate_k();
