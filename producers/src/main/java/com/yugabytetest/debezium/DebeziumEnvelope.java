package com.yugabytetest.debezium;

import com.fasterxml.jackson.annotation.JsonProperty;
import lombok.Builder;
import lombok.Data;

import java.util.Map;

/**
 * Debezium CDC envelope format.
 * This is the standard structure that Debezium uses for change events.
 */
@Data
@Builder
public class DebeziumEnvelope {

    private Map<String, Object> before;
    private Map<String, Object> after;
    private Source source;
    private String op;  // c=create, u=update, d=delete, r=read (snapshot)

    @JsonProperty("ts_ms")
    private long tsMs;

    @Data
    @Builder
    public static class Source {
        private String version;
        private String connector;
        private String name;

        @JsonProperty("ts_ms")
        private long tsMs;

        private String snapshot;
        private String db;
        private String schema;
        private String table;

        // Oracle-specific
        private String txId;
        private Long scn;

        // DB2-specific
        private String lsn;
    }
}
