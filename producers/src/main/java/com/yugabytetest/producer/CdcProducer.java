package com.yugabytetest.producer;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.yugabytetest.debezium.Db2ChangeEvent;
import com.yugabytetest.debezium.DebeziumEnvelope;
import com.yugabytetest.debezium.OracleChangeEvent;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import jakarta.annotation.PostConstruct;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

@Slf4j
@Component
public class CdcProducer {

    private final KafkaTemplate<String, String> kafkaTemplate;
    private final ObjectMapper objectMapper;
    private final MeterRegistry meterRegistry;

    @Value("${producer.enabled:true}")
    private boolean enabled;

    @Value("${producer.mode:both}")
    private String mode; // oracle, db2, or both

    @Value("${producer.events-per-second:1000}")
    private int eventsPerSecond;

    @Value("${producer.threads:4}")
    private int threads;

    @Value("${producer.topic.oracle.customers:oracle-cdc-customers}")
    private String oracleCustomersTopic;

    @Value("${producer.topic.oracle.orders:oracle-cdc-orders}")
    private String oracleOrdersTopic;

    @Value("${producer.topic.db2.products:db2-cdc-products}")
    private String db2ProductsTopic;

    @Value("${producer.topic.db2.inventory:db2-cdc-inventory}")
    private String db2InventoryTopic;

    private final AtomicLong customerIdSequence = new AtomicLong(1);
    private final AtomicLong orderIdSequence = new AtomicLong(1);
    private final AtomicLong productIdSequence = new AtomicLong(1);
    private final AtomicLong inventoryIdSequence = new AtomicLong(1);

    private final AtomicBoolean running = new AtomicBoolean(false);
    private ExecutorService executorService;

    private Counter eventsSentCounter;
    private Counter errorsCounter;
    private Timer sendLatencyTimer;

    public CdcProducer(KafkaTemplate<String, String> kafkaTemplate,
                       ObjectMapper objectMapper,
                       MeterRegistry meterRegistry) {
        this.kafkaTemplate = kafkaTemplate;
        this.objectMapper = objectMapper;
        this.meterRegistry = meterRegistry;
    }

    @PostConstruct
    public void init() {
        eventsSentCounter = Counter.builder("cdc.events.sent")
                .description("Number of CDC events sent to Kafka")
                .tag("producer", "cdc-producer")
                .register(meterRegistry);

        errorsCounter = Counter.builder("cdc.events.errors")
                .description("Number of errors sending CDC events")
                .tag("producer", "cdc-producer")
                .register(meterRegistry);

        sendLatencyTimer = Timer.builder("cdc.events.latency")
                .description("Latency of sending CDC events")
                .tag("producer", "cdc-producer")
                .register(meterRegistry);

        if (enabled) {
            start();
        }
    }

    public void start() {
        if (running.compareAndSet(false, true)) {
            log.info("Starting CDC producer with {} events/sec across {} threads (mode: {})",
                    eventsPerSecond, threads, mode);

            executorService = Executors.newFixedThreadPool(threads);
            int eventsPerThread = eventsPerSecond / threads;

            for (int i = 0; i < threads; i++) {
                final int threadId = i;
                executorService.submit(() -> runProducerLoop(threadId, eventsPerThread));
            }
        }
    }

    public void stop() {
        if (running.compareAndSet(true, false)) {
            log.info("Stopping CDC producer");
            if (executorService != null) {
                executorService.shutdown();
            }
        }
    }

    private void runProducerLoop(int threadId, int targetEventsPerSecond) {
        log.info("Producer thread {} started, target: {} events/sec", threadId, targetEventsPerSecond);

        long intervalNanos = 1_000_000_000L / targetEventsPerSecond;
        long nextEventTime = System.nanoTime();

        while (running.get()) {
            try {
                long now = System.nanoTime();
                if (now >= nextEventTime) {
                    produceEvent(threadId);
                    nextEventTime += intervalNanos;

                    // Prevent falling too far behind
                    if (nextEventTime < now - 1_000_000_000L) {
                        nextEventTime = now;
                    }
                } else {
                    // Spin wait for short intervals
                    Thread.onSpinWait();
                }
            } catch (Exception e) {
                log.error("Error in producer thread {}", threadId, e);
                errorsCounter.increment();
            }
        }

        log.info("Producer thread {} stopped", threadId);
    }

    private void produceEvent(int threadId) throws JsonProcessingException {
        Timer.Sample sample = Timer.start(meterRegistry);

        boolean produceOracle = "oracle".equals(mode) || "both".equals(mode);
        boolean produceDb2 = "db2".equals(mode) || "both".equals(mode);

        // Alternate between event types based on thread ID
        int eventType = (int) ((threadId + customerIdSequence.get()) % 4);

        String topic;
        String key;
        DebeziumEnvelope envelope;

        if (produceOracle && eventType < 2) {
            if (eventType == 0) {
                long customerId = customerIdSequence.incrementAndGet();
                envelope = OracleChangeEvent.createCustomerEvent(customerId, "c");
                topic = oracleCustomersTopic;
                key = String.valueOf(customerId);
            } else {
                long orderId = orderIdSequence.incrementAndGet();
                long customerId = (orderId % 100000) + 1; // Reference existing customers
                envelope = OracleChangeEvent.createOrderEvent(orderId, customerId, "c");
                topic = oracleOrdersTopic;
                key = String.valueOf(orderId);
            }
        } else if (produceDb2) {
            if (eventType == 2 || !produceOracle) {
                long productId = productIdSequence.incrementAndGet();
                envelope = Db2ChangeEvent.createProductEvent(productId, "c");
                topic = db2ProductsTopic;
                key = String.valueOf(productId);
            } else {
                long inventoryId = inventoryIdSequence.incrementAndGet();
                long productId = (inventoryId % 50000) + 1; // Reference existing products
                envelope = Db2ChangeEvent.createInventoryEvent(inventoryId, productId, "c");
                topic = db2InventoryTopic;
                key = String.valueOf(inventoryId);
            }
        } else {
            return;
        }

        String value = objectMapper.writeValueAsString(envelope);
        kafkaTemplate.send(topic, key, value);
        eventsSentCounter.increment();
        sample.stop(sendLatencyTimer);
    }

    @Scheduled(fixedRate = 10000)
    public void logStats() {
        if (running.get()) {
            log.info("CDC Producer stats - Customers: {}, Orders: {}, Products: {}, Inventory: {}",
                    customerIdSequence.get(),
                    orderIdSequence.get(),
                    productIdSequence.get(),
                    inventoryIdSequence.get());
        }
    }
}
