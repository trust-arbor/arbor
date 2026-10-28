-- Arbor EventLog's EventStore-specific schema. This migration is intentionally
-- separate from EventStore's upstream migrations and is run by
-- `mix arbor.event_log.migrate` after `mix event_store.init`.

-- arbor:statement
LOCK TABLE __SCHEMA__.streams, __SCHEMA__.events, __SCHEMA__.stream_events
  IN ACCESS EXCLUSIVE MODE

-- arbor:statement
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM __SCHEMA__.streams
    WHERE stream_version < 0 OR stream_version > 2147483647
  ) THEN
    RAISE EXCEPTION 'EventStore contains stream positions outside Arbor EventLog capacity';
  END IF;

  IF EXISTS (
    SELECT 1 FROM __SCHEMA__.stream_events
    WHERE stream_version < 1 OR stream_version > 2147483647
  ) THEN
    RAISE EXCEPTION 'EventStore contains event positions outside Arbor EventLog capacity';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM __SCHEMA__.events AS events
    WHERE events.metadata IS NOT NULL
      AND (
        __METADATA_JSON__ ? 'arbor_append_operation_id'
        OR __METADATA_JSON__ ? 'arbor_append_fingerprint'
        OR __METADATA_JSON__ ? 'event_id'
      )
      AND NOT (
        jsonb_typeof(__METADATA_JSON__ -> 'arbor_append_operation_id') = 'string'
        AND octet_length(__METADATA_JSON__ ->> 'arbor_append_operation_id') BETWEEN 1 AND 255
        AND jsonb_typeof(__METADATA_JSON__ -> 'arbor_append_fingerprint') = 'string'
        AND (__METADATA_JSON__ ->> 'arbor_append_fingerprint') ~ '^[0-9a-f]{64}$'
        AND jsonb_typeof(__METADATA_JSON__ -> 'event_id') = 'string'
        AND octet_length(__METADATA_JSON__ ->> 'event_id') BETWEEN 1 AND 255
      )
  ) THEN
    RAISE EXCEPTION 'EventStore contains malformed Arbor append identity metadata';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM __SCHEMA__.events AS events
    INNER JOIN __SCHEMA__.stream_events AS source
      ON source.event_id = events.event_id
     AND source.stream_id = source.original_stream_id
    INNER JOIN __SCHEMA__.streams AS streams
      ON streams.stream_id = source.stream_id
    WHERE __METADATA_JSON__ ? 'arbor_append_operation_id'
      AND (
        octet_length(streams.stream_uuid) NOT BETWEEN 1 AND 255
        OR octet_length(events.event_type) NOT BETWEEN 1 AND 255
        OR (
          __METADATA_JSON__ ? 'arbor_agent_id'
          AND __METADATA_JSON__ -> 'arbor_agent_id' <> 'null'::jsonb
          AND (
            jsonb_typeof(__METADATA_JSON__ -> 'arbor_agent_id') <> 'string'
            OR octet_length(__METADATA_JSON__ ->> 'arbor_agent_id') NOT BETWEEN 1 AND 255
          )
        )
        OR (
          __METADATA_JSON__ ? 'causation_id'
          AND __METADATA_JSON__ -> 'causation_id' <> 'null'::jsonb
          AND (
            jsonb_typeof(__METADATA_JSON__ -> 'causation_id') <> 'string'
            OR octet_length(__METADATA_JSON__ ->> 'causation_id') NOT BETWEEN 1 AND 255
          )
        )
        OR (
          __METADATA_JSON__ ? 'correlation_id'
          AND __METADATA_JSON__ -> 'correlation_id' <> 'null'::jsonb
          AND (
            jsonb_typeof(__METADATA_JSON__ -> 'correlation_id') <> 'string'
            OR octet_length(__METADATA_JSON__ ->> 'correlation_id') NOT BETWEEN 1 AND 255
          )
        )
      )
  ) THEN
    RAISE EXCEPTION 'EventStore contains Arbor events outside the public string contract';
  END IF;

  IF EXISTS (
    SELECT __METADATA_JSON__ ->> 'arbor_append_operation_id'
    FROM __SCHEMA__.events AS events
    INNER JOIN __SCHEMA__.stream_events AS source
      ON source.event_id = events.event_id
     AND source.stream_id = source.original_stream_id
    INNER JOIN __SCHEMA__.streams AS streams
      ON streams.stream_id = source.stream_id
    WHERE __METADATA_JSON__ ? 'arbor_append_operation_id'
    GROUP BY __METADATA_JSON__ ->> 'arbor_append_operation_id'
    HAVING count(DISTINCT streams.stream_uuid) <> 1
       OR count(*) <> count(DISTINCT __METADATA_JSON__ ->> 'event_id')
  ) THEN
    RAISE EXCEPTION 'EventStore contains conflicting Arbor append operation metadata';
  END IF;
END
$$

-- arbor:statement
CREATE TABLE __SCHEMA__.arbor_event_log_operations (
  operation_id text PRIMARY KEY,
  stream_id text NOT NULL,
  event_ids text[] NOT NULL,
  fingerprints text[] NOT NULL,
  status text NOT NULL,
  reason text,
  inserted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT arbor_event_log_operations_terminal_status
    CHECK (status IN ('committed', 'aborted', 'conflict')),
  CONSTRAINT arbor_event_log_operations_identity_shape
    CHECK (
      cardinality(event_ids) > 0
      AND cardinality(event_ids) = cardinality(fingerprints)
      AND array_position(event_ids, NULL) IS NULL
      AND array_position(fingerprints, NULL) IS NULL
    )
)

-- arbor:statement
CREATE INDEX arbor_event_log_operations_status_inserted_at_idx
  ON __SCHEMA__.arbor_event_log_operations (status, inserted_at)

-- arbor:statement
COMMENT ON TABLE __SCHEMA__.arbor_event_log_operations IS
  'Permanent terminal EventLog operation fences; deleting rows reopens operation outcomes'

-- arbor:statement
INSERT INTO __SCHEMA__.arbor_event_log_operations (
  operation_id,
  stream_id,
  event_ids,
  fingerprints,
  status,
  reason,
  inserted_at,
  updated_at
)
SELECT __METADATA_JSON__ ->> 'arbor_append_operation_id',
       streams.stream_uuid,
       array_agg(__METADATA_JSON__ ->> 'event_id' ORDER BY source.original_stream_version),
       array_agg(
         __METADATA_JSON__ ->> 'arbor_append_fingerprint'
         ORDER BY source.original_stream_version
       ),
       'committed',
       'migration_backfill',
       min(events.created_at),
       clock_timestamp()
FROM __SCHEMA__.events AS events
INNER JOIN __SCHEMA__.stream_events AS source
  ON source.event_id = events.event_id
 AND source.stream_id = source.original_stream_id
INNER JOIN __SCHEMA__.streams AS streams
  ON streams.stream_id = source.stream_id
WHERE __METADATA_JSON__ ? 'arbor_append_operation_id'
GROUP BY __METADATA_JSON__ ->> 'arbor_append_operation_id', streams.stream_uuid

-- arbor:statement
ALTER TABLE __SCHEMA__.streams
  DROP CONSTRAINT IF EXISTS arbor_eventlog_stream_position_capacity,
  DROP CONSTRAINT IF EXISTS arbor_eventlog_global_position_capacity

-- arbor:statement
ALTER TABLE __SCHEMA__.streams
  ADD CONSTRAINT arbor_eventlog_stream_position_capacity
    CHECK (stream_id = 0 OR (stream_version >= 0 AND stream_version <= 2147483647)),
  ADD CONSTRAINT arbor_eventlog_global_position_capacity
    CHECK (stream_id <> 0 OR (stream_version >= 0 AND stream_version <= 2147483647))
