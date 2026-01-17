package com.yugabytetest.debezium;

import net.datafaker.Faker;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Instant;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Generates Debezium-format CDC events simulating Oracle database changes.
 * Simulates customers and orders tables.
 */
public class OracleChangeEvent {

    private static final Faker faker = new Faker();
    private static final AtomicLong scnCounter = new AtomicLong(System.currentTimeMillis());
    private static final String CONNECTOR_NAME = "oracle-source";
    private static final String DB_NAME = "ORCL";
    private static final String SCHEMA_NAME = "TESTDB";

    public static DebeziumEnvelope createCustomerEvent(long customerId, String operation) {
        Map<String, Object> after = new HashMap<>();
        after.put("id", customerId);
        after.put("name", faker.name().fullName());
        after.put("email", faker.internet().emailAddress());
        after.put("created_at", Instant.now().toEpochMilli());

        return buildEnvelope("CUSTOMERS", after, operation);
    }

    public static DebeziumEnvelope createOrderEvent(long orderId, long customerId, String operation) {
        Map<String, Object> after = new HashMap<>();
        after.put("id", orderId);
        after.put("customer_id", customerId);
        after.put("total_amount", BigDecimal.valueOf(faker.number().randomDouble(2, 10, 10000))
                .setScale(2, RoundingMode.HALF_UP));
        after.put("status", faker.options().option("pending", "confirmed", "shipped", "delivered"));
        after.put("created_at", Instant.now().toEpochMilli());

        return buildEnvelope("ORDERS", after, operation);
    }

    private static DebeziumEnvelope buildEnvelope(String table, Map<String, Object> after, String operation) {
        long now = System.currentTimeMillis();

        DebeziumEnvelope.Source source = DebeziumEnvelope.Source.builder()
                .version("2.4.0.Final")
                .connector("oracle")
                .name(CONNECTOR_NAME)
                .tsMs(now)
                .snapshot("false")
                .db(DB_NAME)
                .schema(SCHEMA_NAME)
                .table(table)
                .txId("tx-" + faker.random().hex(8))
                .scn(scnCounter.incrementAndGet())
                .build();

        Map<String, Object> before = null;
        if ("u".equals(operation) || "d".equals(operation)) {
            before = new HashMap<>(after);
            if ("u".equals(operation)) {
                // Simulate a changed value
                before.put("status", "pending");
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
