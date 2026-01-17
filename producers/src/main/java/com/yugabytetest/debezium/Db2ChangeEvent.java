package com.yugabytetest.debezium;

import net.datafaker.Faker;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Instant;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Generates Debezium-format CDC events simulating DB2 database changes.
 * Simulates products and inventory tables.
 */
public class Db2ChangeEvent {

    private static final Faker faker = new Faker();
    private static final AtomicLong lsnCounter = new AtomicLong(System.currentTimeMillis());
    private static final String CONNECTOR_NAME = "db2-source";
    private static final String DB_NAME = "TESTDB";
    private static final String SCHEMA_NAME = "DB2INST1";

    private static final String[] CATEGORIES = {
            "Electronics", "Clothing", "Home & Garden", "Sports", "Books",
            "Toys", "Automotive", "Health", "Food", "Office"
    };

    private static final String[] WAREHOUSES = {
            "WH-EAST-01", "WH-EAST-02", "WH-WEST-01", "WH-WEST-02",
            "WH-CENTRAL-01", "WH-SOUTH-01", "WH-NORTH-01"
    };

    public static DebeziumEnvelope createProductEvent(long productId, String operation) {
        Map<String, Object> after = new HashMap<>();
        after.put("id", productId);
        after.put("name", faker.commerce().productName());
        after.put("category", faker.options().option(CATEGORIES));
        after.put("price", BigDecimal.valueOf(faker.number().randomDouble(2, 5, 500))
                .setScale(2, RoundingMode.HALF_UP));

        return buildEnvelope("PRODUCTS", after, operation);
    }

    public static DebeziumEnvelope createInventoryEvent(long inventoryId, long productId, String operation) {
        Map<String, Object> after = new HashMap<>();
        after.put("id", inventoryId);
        after.put("product_id", productId);
        after.put("warehouse", faker.options().option(WAREHOUSES));
        after.put("quantity", faker.number().numberBetween(0, 10000));
        after.put("updated_at", Instant.now().toEpochMilli());

        return buildEnvelope("INVENTORY", after, operation);
    }

    private static DebeziumEnvelope buildEnvelope(String table, Map<String, Object> after, String operation) {
        long now = System.currentTimeMillis();

        DebeziumEnvelope.Source source = DebeziumEnvelope.Source.builder()
                .version("2.4.0.Final")
                .connector("db2")
                .name(CONNECTOR_NAME)
                .tsMs(now)
                .snapshot("false")
                .db(DB_NAME)
                .schema(SCHEMA_NAME)
                .table(table)
                .lsn(String.format("%016X", lsnCounter.incrementAndGet()))
                .build();

        Map<String, Object> before = null;
        if ("u".equals(operation) || "d".equals(operation)) {
            before = new HashMap<>(after);
            if ("u".equals(operation)) {
                before.put("quantity", 0);
            }
        }

        return DebeziumEnvelope.builder()
                .before(before)
                .after("d".equals(operation) ? null : after)
                .source(source)
                .op(operation)
                .tsMs(now)
                .build();
    }
}
