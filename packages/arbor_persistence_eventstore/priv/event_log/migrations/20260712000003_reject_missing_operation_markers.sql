-- EventLog protocol epoch 3 trigger hardening.
--
-- ACCESS EXCLUSIVE drains inserts that could still be executing the R3
-- function before replacing it. The protocol remains epoch 3; this migration
-- corrects the marker predicate without changing the wire protocol.

-- arbor:statement
LOCK TABLE __SCHEMA__.events IN ACCESS EXCLUSIVE MODE

-- arbor:statement
CREATE OR REPLACE FUNCTION __SCHEMA__.arbor_event_log_enforce_operation_fence()
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
     OR NOT (metadata_json ? 'arbor_append_operation_id')
     OR jsonb_typeof(metadata_json -> 'arbor_append_operation_id') IS DISTINCT FROM 'string'
     OR NOT (metadata_json ? 'arbor_append_fingerprint')
     OR jsonb_typeof(metadata_json -> 'arbor_append_fingerprint') IS DISTINCT FROM 'string'
     OR NOT (metadata_json ? 'event_id')
     OR jsonb_typeof(metadata_json -> 'event_id') IS DISTINCT FROM 'string' THEN
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
