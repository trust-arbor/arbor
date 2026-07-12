-- EventLog protocol epoch 3 maintenance cutover.
--
-- ACCESS EXCLUSIVE drains writers that already touched the events or fence
-- tables. Once this transaction commits, the trigger makes old EventStore
-- binaries participate in the operation lock and rejects marker-free writes.

-- arbor:statement
LOCK TABLE __SCHEMA__.streams,
           __SCHEMA__.events,
           __SCHEMA__.stream_events,
           __SCHEMA__.arbor_event_log_operations
  IN ACCESS EXCLUSIVE MODE

-- arbor:statement
CREATE TABLE __SCHEMA__.arbor_event_log_protocol (
  singleton boolean PRIMARY KEY DEFAULT TRUE,
  protocol_version bigint NOT NULL,
  cutover_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT arbor_event_log_protocol_singleton_true CHECK (singleton),
  CONSTRAINT arbor_event_log_protocol_version CHECK (protocol_version = 3)
)

-- arbor:statement
CREATE FUNCTION __SCHEMA__.arbor_event_log_enforce_operation_fence()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  metadata_json jsonb;
  operation_id_value text;
  fingerprint_value text;
  event_id_value text;
  fence_status text;
BEGIN
  metadata_json := __NEW_METADATA_JSON__;

  IF metadata_json IS NULL
     OR jsonb_typeof(metadata_json -> 'arbor_append_operation_id') <> 'string'
     OR jsonb_typeof(metadata_json -> 'arbor_append_fingerprint') <> 'string'
     OR jsonb_typeof(metadata_json -> 'event_id') <> 'string' THEN
    RAISE EXCEPTION 'EventLog operation identity is required after protocol cutover'
      USING ERRCODE = '23514';
  END IF;

  operation_id_value := metadata_json ->> 'arbor_append_operation_id';
  fingerprint_value := metadata_json ->> 'arbor_append_fingerprint';
  event_id_value := metadata_json ->> 'event_id';

  IF octet_length(operation_id_value) NOT BETWEEN 1 AND 255
     OR fingerprint_value !~ '^[0-9a-f]{64}$'
     OR octet_length(event_id_value) NOT BETWEEN 1 AND 255 THEN
    RAISE EXCEPTION 'EventLog operation identity is malformed'
      USING ERRCODE = '23514';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(operation_id_value, 1));

  SELECT status
  INTO fence_status
  FROM __SCHEMA__.arbor_event_log_operations
  WHERE operation_id = operation_id_value;

  IF FOUND THEN
    RAISE EXCEPTION 'EventLog operation % is terminal (%)', operation_id_value, fence_status
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END
$$

-- arbor:statement
CREATE TRIGGER arbor_event_log_operation_fence_insert
BEFORE INSERT ON __SCHEMA__.events
FOR EACH ROW
EXECUTE FUNCTION __SCHEMA__.arbor_event_log_enforce_operation_fence()

-- arbor:statement
INSERT INTO __SCHEMA__.arbor_event_log_protocol (protocol_version)
VALUES (3)
