defmodule Arbor.Contracts.Extension.Envelope do
  @moduledoc """
  Closed v1 JSON envelopes for extension activation and invocation.

  These are the E0C transport forms. Local facades may hold richer structs,
  but every signed or persisted envelope normalizes to the exact string-keyed
  maps defined here. Unknown fields, mixed keys, invalid UTF-8, duplicate
  identifiers, and exceeded `canonical_json_v1` ceilings fail closed.

  Receipts and authorizations are not bearer tokens for a later activation
  or call. Kernel Runtime consumes an authorization against one transaction
  or request digest and generation.

  Boot-profile manifests and detached installer signatures are additional APIs
  on this module (`boot_profile_*`); they are not E0C kinds.
  """

  alias Arbor.Contracts.Security.TaintEnvelope

  @version 1
  @payload_encoding "canonical_json_v1"
  @signed_schema "arbor.extension.signed_envelope.v1"
  @max_list 32
  @max_id_bytes 128
  @sha256_re ~r/\A[0-9a-f]{64}\z/
  @nonce_re ~r/\A[0-9a-f]{32}\z/
  @signature_re ~r/\A[0-9a-f]{128}\z/
  @id_re ~r/\A[a-z0-9][a-z0-9._:-]{0,127}\z/
  @time_re ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
  @agent_re ~r/\Aagent_[0-9a-f]{64}\z/
  @resource_re ~r/\Aarbor:\/\/[a-z0-9][a-z0-9._\/:-]{0,247}\z/

  @kinds [
    :artifact_manifest,
    :provider_handle,
    :activation_transaction,
    :activation_authorization,
    :activation_receipt,
    :invocation_authorization,
    :invocation_request,
    :invocation_result
  ]

  @schemas %{
    artifact_manifest: "arbor.extension.artifact_manifest.v1",
    provider_handle: "arbor.extension.provider_handle.v1",
    activation_transaction: "arbor.extension.activation_transaction.v1",
    activation_authorization: "arbor.extension.activation_authorization.v1",
    activation_receipt: "arbor.extension.activation_receipt.v1",
    invocation_authorization: "arbor.extension.invocation_authorization.v1",
    invocation_request: "arbor.extension.invocation_request.v1",
    invocation_result: "arbor.extension.invocation_result.v1"
  }

  @signed_keys [
    "domain",
    "issuer_id",
    "key_id",
    "payload",
    "payload_encoding",
    "payload_sha256",
    "schema",
    "signature",
    "version"
  ]

  @artifact_keys [
    "artifact_id",
    "artifact_version",
    "author_id",
    "compatibility",
    "contribution_set_sha256",
    "kind",
    "payload_set_sha256",
    "provenance_sha256",
    "provided_protocols",
    "requested_isolation",
    "required_protocols",
    "schema",
    "version"
  ]

  @handle_keys [
    "activation_principal",
    "artifact_sha256",
    "generation",
    "handle_id",
    "health_epoch",
    "lease_expires_at",
    "lease_id",
    "protocol_id",
    "protocol_version",
    "schema",
    "transport_class",
    "version"
  ]

  @transaction_keys [
    "admitted_isolation",
    "artifact_sha256",
    "boot_profile_id",
    "boot_profile_sha256",
    "deadline",
    "generation",
    "payload_set_sha256",
    "principal_id",
    "requested_grants",
    "schema",
    "staged_effects",
    "transaction_id",
    "version"
  ]

  @activation_authorization_keys [
    "audience_host_id",
    "audience_install_id",
    "boot_epoch",
    "boot_profile_sha256",
    "expires_at",
    "issued_at",
    "issuer_id",
    "key_id",
    "nonce",
    "schema",
    "transaction_sha256",
    "version"
  ]

  @receipt_keys [
    "artifact_sha256",
    "cleanup_disposition",
    "effects",
    "generation",
    "intent_sha256",
    "principal_id",
    "schema",
    "state",
    "transaction_id",
    "transaction_sha256",
    "version"
  ]

  @invocation_authorization_keys [
    "action",
    "audience",
    "caller_principal",
    "capability_id",
    "deadline",
    "egress_mode",
    "generation",
    "handle_id",
    "lease_id",
    "nonce",
    "operation",
    "protocol_id",
    "request_sha256",
    "resource",
    "resource_constraints",
    "schema",
    "session_id",
    "task_id",
    "taint_sha256",
    "trust_decision_id",
    "correlation_id",
    "version"
  ]

  @invocation_request_keys [
    "generation",
    "payload",
    "payload_sha256",
    "protocol_id",
    "protocol_schema",
    "request_sha256",
    "schema",
    "version"
  ]

  @invocation_result_keys [
    "effect_disposition",
    "error_code",
    "generation",
    "metering",
    "payload_sha256",
    "protocol_id",
    "protocol_schema",
    "request_sha256",
    "result_sha256",
    "schema",
    "status",
    "taint_sha256",
    "version"
  ]

  @protocol_keys ["id", "version"]
  @compatibility_keys ["max_host_version", "min_host_version"]
  @grant_keys ["action", "resource"]
  @staged_effect_keys ["class", "id", "kind"]
  @receipt_effect_keys ["class", "id", "state"]
  @constraint_keys ["max_bytes", "max_ms"]
  @metering_keys ["bytes", "ms", "tokens"]

  @artifact_kinds MapSet.new(["embedded", "isolated"])
  @isolations MapSet.new(["external", "in_vm"])
  @transports MapSet.new(["external", "local_module"])
  @effect_classes MapSet.new(["compensable", "irreversible_audited", "reversible"])
  @receipt_states MapSet.new(["committed", "quarantined", "rolled_back"])
  @effect_states MapSet.new(["applied", "quarantined", "rolled_back"])
  @cleanup MapSet.new(["none", "pending", "quarantined"])
  @egress_modes MapSet.new(["allow", "ask", "auto", "block"])
  @result_statuses MapSet.new(["error", "ok"])
  @dispositions MapSet.new(["applied", "none", "unknown"])

  @error_codes %{
    artifact:
      MapSet.new([
        "digest_mismatch",
        "incompatible",
        "malformed",
        "payload_unavailable",
        "provenance_mismatch",
        "revoked",
        "signature_mismatch",
        "unsupported"
      ]),
    activation:
      MapSet.new([
        "authorization_absent",
        "authorization_expired",
        "authorization_invalid",
        "authorization_replayed",
        "authorization_revoked",
        "boot_mismatch",
        "cleanup_pending",
        "commit_conflict",
        "generation_mismatch",
        "grant_denied",
        "isolation_denied",
        "not_ready",
        "principal_denied",
        "quarantined",
        "staging_failed",
        "transaction_mismatch"
      ]),
    resolution:
      MapSet.new([
        "expired_lease",
        "no_compatible_provider",
        "stale_generation",
        "unauthorized",
        "unhealthy"
      ]),
    invocation:
      MapSet.new([
        "deadline_exceeded",
        "denied",
        "digest_mismatch",
        "effect_disposition_unknown",
        "expired",
        "invalid_result",
        "malformed",
        "protocol_failure",
        "provider_failure",
        "provider_unavailable",
        "replayed",
        "revoked_during_use"
      ])
  }

  @fixture_digest String.duplicate("ab", 32)
  @fixture_nonce String.duplicate("cd", 16)
  @fixture_signature String.duplicate("ef", 64)
  @fixture_agent "agent_" <> String.duplicate("11", 32)
  @fixture_time "2026-08-17T00:00:00Z"

  @boot_profile_schema "arbor.platform.boot_profile_manifest.v1"
  @boot_profile_signature_schema "arbor.platform.boot_profile_signature.v1"
  @boot_profile_max_bytes 16_384
  @boot_profile_platform_public_key "46adc9536b563c36a777199fd7a6c8dc82c4c0e9e7952f123a23d27bf0e74170"
  @boot_profile_platform_key_id "e50fe65c9e59cfefce8bea959c8aac98e31d25922b172f9e60acd43cf5b804bb"
  @boot_profile_installer_key_id "37eb0623867f14c690e51a9e24c55fd98ae4b353a00cd3a37ec953330ddda395"
  @boot_profile_manifest_sha256 "374dabaf63c89a46a92b87bbf0f2e871330ecfe01eb9a230560137b1a7a18268"
  @boot_profile_signature_hex "a61753ee7ca4ffc281f54432fff57dc574c754ae53f6623f67d2cff8a96eed79148c2752a028fc9296b85099dcc4f6ac97d501d8c949951de05627138791330e"

  @boot_profile_manifest_keys [
    "boot_epoch",
    "payload_digests",
    "platform_key_id",
    "platform_public_key",
    "profile_id",
    "release_id",
    "revocation_input_id",
    "schema",
    "valid_from",
    "valid_until",
    "version"
  ]

  @boot_profile_signature_keys [
    "domain",
    "key_id",
    "manifest_encoding",
    "manifest_sha256",
    "schema",
    "signature",
    "signer_id",
    "version"
  ]

  @boot_profile_verifier_keys [
    "expected_payload_digests",
    "expected_profile_id",
    "expected_release_id",
    "expected_revocation_input_id",
    "min_boot_epoch",
    "now",
    "revoked_platform_key_ids",
    "revoked_signer_key_ids",
    "trusted_signers"
  ]

  @boot_profile_payload_digest_keys ["id", "sha256"]
  @boot_profile_trusted_signer_keys ["key_id", "public_key", "signer_id"]

  @type kind ::
          :artifact_manifest
          | :provider_handle
          | :activation_transaction
          | :activation_authorization
          | :activation_receipt
          | :invocation_authorization
          | :invocation_request
          | :invocation_result

  @doc "Returns the closed payload kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Returns the exact v1 schema id for a payload kind."
  @spec schema(kind()) :: String.t()
  def schema(kind) when kind in @kinds, do: Map.fetch!(@schemas, kind)

  @doc "Returns the signed-envelope schema id."
  @spec signed_schema() :: String.t()
  def signed_schema, do: @signed_schema

  @doc "Returns the public error-code groups."
  @spec error_codes() :: %{atom() => MapSet.t(String.t())}
  def error_codes, do: @error_codes

  @doc "Returns whether `code` is a public error code in `group`."
  @spec error_code?(atom(), String.t()) :: boolean()
  def error_code?(group, code)
      when is_atom(group) and is_binary(code) and is_map_key(@error_codes, group) do
    MapSet.member?(Map.fetch!(@error_codes, group), code)
  end

  def error_code?(_group, _code), do: false

  @doc "Validates an exact string-keyed payload of `kind`."
  @spec validate(kind(), term()) :: {:ok, map()} | {:error, atom()}
  def validate(kind, document) when kind in @kinds do
    with :ok <- exact_keys(document, keys_for(kind)),
         :ok <- validate_kind(kind, document) do
      {:ok, document}
    end
  end

  def validate(_kind, _document), do: {:error, :unknown_kind}

  @doc "Validates a signed envelope and its nested payload."
  @spec validate_signed(term()) :: {:ok, map()} | {:error, atom()}
  def validate_signed(document) do
    with :ok <- exact_keys(document, @signed_keys),
         :ok <- exact(document["schema"], @signed_schema),
         :ok <- exact(document["version"], @version),
         :ok <- exact(document["payload_encoding"], @payload_encoding),
         :ok <- digest(document["payload_sha256"]),
         :ok <- agent_id(document["issuer_id"]),
         :ok <- digest(document["key_id"]),
         :ok <- signature(document["signature"]),
         {:ok, kind} <- kind_from_domain(document["domain"]),
         {:ok, payload} <- validate(kind, document["payload"]),
         {:ok, expected} <- digest_of(payload),
         true <- secure_equal?(expected, document["payload_sha256"]) do
      {:ok, document}
    else
      false -> {:error, :digest_mismatch}
      {:error, reason} -> {:error, reason}
      :error -> {:error, :invalid_envelope}
    end
  end

  @doc "Returns the lowercase SHA-256 of the canonical payload."
  @spec digest_of(term()) :: {:ok, String.t()} | {:error, atom()}
  def digest_of(document), do: TaintEnvelope.payload_sha256(document)

  @doc "Returns canonical JSON bytes for a JSON-shaped document."
  @spec canonical_json(term()) :: {:ok, binary()} | {:error, atom()}
  def canonical_json(document), do: TaintEnvelope.canonical_json(document)

  @doc """
  Detached-signature input for a signed envelope.

  Domain, schema, and payload digest are joined with NUL so a signature
  cannot be replayed across kinds.
  """
  @spec signing_message(map()) :: {:ok, binary()} | {:error, atom()}
  def signing_message(%{"domain" => domain, "schema" => schema, "payload_sha256" => digest})
      when is_binary(domain) and is_binary(schema) and is_binary(digest) do
    with :ok <- digest(digest) do
      {:ok, Enum.join([domain, schema, digest], "\0")}
    end
  end

  def signing_message(_document), do: {:error, :invalid_envelope}

  @doc "Resolves a signed-envelope domain to a payload kind."
  @spec kind_from_domain(term()) :: {:ok, kind()} | :error
  def kind_from_domain(domain) do
    Enum.find_value(@schemas, :error, fn {kind, schema} ->
      if schema == domain, do: {:ok, kind}
    end)
  end

  @doc "Returns a closed, byte-stable fixture for `kind`."
  @spec fixture(kind()) :: map()
  def fixture(:artifact_manifest) do
    %{
      "schema" => schema(:artifact_manifest),
      "version" => @version,
      "artifact_id" => "artifact.vector",
      "artifact_version" => "1.0.0",
      "kind" => "embedded",
      "author_id" => @fixture_agent,
      "payload_set_sha256" => @fixture_digest,
      "required_protocols" => [%{"id" => "vector.store", "version" => "1"}],
      "provided_protocols" => [%{"id" => "vector.store", "version" => "1"}],
      "contribution_set_sha256" => @fixture_digest,
      "requested_isolation" => "in_vm",
      "compatibility" => %{
        "min_host_version" => "1",
        "max_host_version" => "1"
      },
      "provenance_sha256" => @fixture_digest
    }
  end

  def fixture(:provider_handle) do
    %{
      "schema" => schema(:provider_handle),
      "version" => @version,
      "handle_id" => "handle.vector.1",
      "protocol_id" => "vector.store",
      "protocol_version" => "1",
      "transport_class" => "local_module",
      "artifact_sha256" => @fixture_digest,
      "activation_principal" => @fixture_agent,
      "generation" => 1,
      "lease_id" => "lease.vector.1",
      "lease_expires_at" => @fixture_time,
      "health_epoch" => 1
    }
  end

  def fixture(:activation_transaction) do
    %{
      "schema" => schema(:activation_transaction),
      "version" => @version,
      "transaction_id" => "txn.vector.1",
      "boot_profile_id" => "safe_recovery",
      "boot_profile_sha256" => @fixture_digest,
      "artifact_sha256" => @fixture_digest,
      "payload_set_sha256" => @fixture_digest,
      "principal_id" => @fixture_agent,
      "generation" => 1,
      "requested_grants" => [
        %{"resource" => "arbor://extension/vector/store", "action" => "execute"}
      ],
      "admitted_isolation" => "in_vm",
      "staged_effects" => [
        %{"id" => "effect.register", "class" => "reversible", "kind" => "register_handle"}
      ],
      "deadline" => @fixture_time
    }
  end

  def fixture(:activation_authorization) do
    %{
      "schema" => schema(:activation_authorization),
      "version" => @version,
      "transaction_sha256" => @fixture_digest,
      "issuer_id" => @fixture_agent,
      "key_id" => @fixture_digest,
      "audience_host_id" => "host.local",
      "audience_install_id" => "install.local",
      "boot_epoch" => 1,
      "boot_profile_sha256" => @fixture_digest,
      "issued_at" => @fixture_time,
      "expires_at" => @fixture_time,
      "nonce" => @fixture_nonce
    }
  end

  def fixture(:activation_receipt) do
    %{
      "schema" => schema(:activation_receipt),
      "version" => @version,
      "transaction_id" => "txn.vector.1",
      "transaction_sha256" => @fixture_digest,
      "artifact_sha256" => @fixture_digest,
      "principal_id" => @fixture_agent,
      "generation" => 1,
      "effects" => [
        %{"id" => "effect.register", "class" => "reversible", "state" => "applied"}
      ],
      "state" => "committed",
      "intent_sha256" => @fixture_digest,
      "cleanup_disposition" => "none"
    }
  end

  def fixture(:invocation_authorization) do
    %{
      "schema" => schema(:invocation_authorization),
      "version" => @version,
      "caller_principal" => @fixture_agent,
      "resource" => "arbor://extension/vector/store",
      "action" => "execute",
      "capability_id" => "cap.vector.1",
      "trust_decision_id" => "trust.vector.1",
      "handle_id" => "handle.vector.1",
      "generation" => 1,
      "lease_id" => "lease.vector.1",
      "protocol_id" => "vector.store",
      "operation" => "upsert",
      "request_sha256" => @fixture_digest,
      "deadline" => @fixture_time,
      "task_id" => "task.vector.1",
      "session_id" => "session.vector.1",
      "correlation_id" => "corr.vector.1",
      "taint_sha256" => @fixture_digest,
      "egress_mode" => "allow",
      "resource_constraints" => %{"max_bytes" => 4096, "max_ms" => 1000},
      "audience" => "host.local",
      "nonce" => @fixture_nonce
    }
  end

  def fixture(:invocation_request) do
    payload = %{"items" => [%{"id" => "doc.1", "text" => "hello"}]}

    %{
      "schema" => schema(:invocation_request),
      "version" => @version,
      "protocol_id" => "vector.store",
      "protocol_schema" => "vector.store.upsert.v1",
      "generation" => 1,
      "request_sha256" => @fixture_digest,
      "payload_sha256" => fixture_digest!(payload),
      "payload" => payload
    }
  end

  def fixture(:invocation_result) do
    %{
      "schema" => schema(:invocation_result),
      "version" => @version,
      "protocol_id" => "vector.store",
      "protocol_schema" => "vector.store.upsert.v1",
      "generation" => 1,
      "request_sha256" => @fixture_digest,
      "payload_sha256" => @fixture_digest,
      "status" => "ok",
      "error_code" => nil,
      "result_sha256" => @fixture_digest,
      "taint_sha256" => @fixture_digest,
      "metering" => %{"tokens" => 0, "bytes" => 8, "ms" => 1},
      "effect_disposition" => "applied"
    }
  end

  @doc "Wraps a fixture payload in the signed-envelope shape."
  @spec signed_fixture(kind()) :: map()
  def signed_fixture(kind) when kind in @kinds do
    payload = fixture(kind)

    %{
      "schema" => @signed_schema,
      "version" => @version,
      "domain" => schema(kind),
      "payload_encoding" => @payload_encoding,
      "payload_sha256" => fixture_digest!(payload),
      "issuer_id" => @fixture_agent,
      "key_id" => @fixture_digest,
      "signature" => @fixture_signature,
      "payload" => payload
    }
  end

  @doc "Returns the closed v1 boot-profile manifest schema id."
  @spec boot_profile_schema() :: String.t()
  def boot_profile_schema, do: @boot_profile_schema

  @doc "Returns the closed v1 detached boot-profile signature schema id."
  @spec boot_profile_signature_schema() :: String.t()
  def boot_profile_signature_schema, do: @boot_profile_signature_schema

  @doc "Returns the closed boot-profile contract version."
  @spec boot_profile_version() :: pos_integer()
  def boot_profile_version, do: @version

  @doc "Returns the boot-profile canonical payload encoding name."
  @spec boot_profile_payload_encoding() :: String.t()
  def boot_profile_payload_encoding, do: @payload_encoding

  @doc "Decodes canonical boot-profile manifest bytes and validates the closed schema."
  @spec decode_boot_profile_manifest_bytes(term()) :: {:ok, map()} | {:error, atom()}
  def decode_boot_profile_manifest_bytes(bytes) do
    decode_boot_profile_bytes(bytes, &validate_boot_profile_manifest/1)
  end

  @doc "Decodes canonical detached boot-profile signature bytes and validates the closed schema."
  @spec decode_boot_profile_signature_bytes(term()) :: {:ok, map()} | {:error, atom()}
  def decode_boot_profile_signature_bytes(bytes) do
    decode_boot_profile_bytes(bytes, &validate_boot_profile_signature/1)
  end

  @doc "Validates a closed boot-profile manifest map."
  @spec validate_boot_profile_manifest(term()) :: {:ok, map()} | {:error, atom()}
  def validate_boot_profile_manifest(document) do
    with :ok <- exact_keys(document, @boot_profile_manifest_keys),
         :ok <- exact(document["schema"], @boot_profile_schema),
         :ok <- boot_profile_version_field(document["version"]),
         :ok <- id(document["release_id"]),
         :ok <- id(document["profile_id"]),
         :ok <- id(document["revocation_input_id"]),
         :ok <- boot_profile_epoch(document["boot_epoch"]),
         :ok <- digest(document["platform_key_id"]),
         :ok <- boot_profile_public_key(document["platform_public_key"]),
         :ok <- boot_profile_payload_digests(document["payload_digests"]),
         {:ok, valid_from} <- boot_profile_instant(document["valid_from"]),
         {:ok, valid_until} <- boot_profile_instant(document["valid_until"]),
         :ok <- boot_profile_validity_window(valid_from, valid_until) do
      {:ok, document}
    end
  end

  @doc "Validates a closed detached boot-profile signature map."
  @spec validate_boot_profile_signature(term()) :: {:ok, map()} | {:error, atom()}
  def validate_boot_profile_signature(document) do
    with :ok <- exact_keys(document, @boot_profile_signature_keys),
         :ok <- exact(document["schema"], @boot_profile_signature_schema),
         :ok <- boot_profile_version_field(document["version"]),
         :ok <- exact(document["domain"], @boot_profile_schema),
         :ok <- boot_profile_encoding_field(document["manifest_encoding"]),
         :ok <- digest(document["manifest_sha256"]),
         :ok <- id(document["signer_id"]),
         :ok <- digest(document["key_id"]),
         :ok <- signature(document["signature"]) do
      {:ok, document}
    end
  end

  @doc "Validates injected boot-profile verifier input."
  @spec validate_boot_profile_verifier_input(term()) :: {:ok, map()} | {:error, atom()}
  def validate_boot_profile_verifier_input(document) do
    with :ok <- boot_profile_verifier_keys(document),
         :ok <- id(document["expected_release_id"]),
         :ok <- id(document["expected_profile_id"]),
         :ok <- id(document["expected_revocation_input_id"]),
         :ok <- boot_profile_payload_digests(document["expected_payload_digests"]),
         :ok <- boot_profile_epoch(document["min_boot_epoch"]),
         {:ok, _now} <- boot_profile_instant(document["now"]),
         :ok <- boot_profile_key_id_list(document["revoked_platform_key_ids"]),
         :ok <- boot_profile_key_id_list(document["revoked_signer_key_ids"]),
         :ok <- boot_profile_trusted_signers(document["trusted_signers"]) do
      {:ok, document}
    else
      {:error, reason} -> {:error, boot_profile_verifier_shape(reason)}
    end
  end

  @doc """
  Returns canonical JSON bytes for a closed boot-profile manifest.

  Full schema validation runs before `canonical_json_v1` encoding.
  """
  @spec boot_profile_canonical_json(term()) :: {:ok, binary()} | {:error, atom()}
  def boot_profile_canonical_json(document) do
    encode_validated_boot_profile(document, &validate_boot_profile_manifest/1)
  end

  @doc """
  Returns the lowercase SHA-256 digest of a closed boot-profile manifest.

  Full schema validation runs before digesting.
  """
  @spec boot_profile_digest_of(term()) :: {:ok, String.t()} | {:error, atom()}
  def boot_profile_digest_of(document) do
    digest_validated_boot_profile(document, &validate_boot_profile_manifest/1)
  end

  @doc """
  Returns canonical JSON bytes for a closed detached boot-profile signature.

  Full schema validation runs before `canonical_json_v1` encoding.
  """
  @spec boot_profile_signature_canonical_json(term()) :: {:ok, binary()} | {:error, atom()}
  def boot_profile_signature_canonical_json(document) do
    encode_validated_boot_profile(document, &validate_boot_profile_signature/1)
  end

  @doc """
  Returns the lowercase SHA-256 digest of a closed detached boot-profile signature.

  Full schema validation runs before digesting.
  """
  @spec boot_profile_signature_digest_of(term()) :: {:ok, String.t()} | {:error, atom()}
  def boot_profile_signature_digest_of(document) do
    digest_validated_boot_profile(document, &validate_boot_profile_signature/1)
  end

  @doc """
  Detached-signature input for a boot-profile manifest.

  Domain, signature schema, signer id, signer key id, and manifest digest are
  joined with NUL so a signature cannot be replayed across kinds or signers.
  """
  @spec boot_profile_signing_message(map()) :: {:ok, binary()} | {:error, atom()}
  def boot_profile_signing_message(%{
        "domain" => domain,
        "schema" => schema,
        "signer_id" => signer_id,
        "key_id" => key_id,
        "manifest_sha256" => digest
      })
      when is_binary(domain) and is_binary(schema) and is_binary(signer_id) and
             is_binary(key_id) and is_binary(digest) do
    with :ok <- digest(digest) do
      {:ok, Enum.join([domain, schema, signer_id, key_id, digest], <<0>>)}
    end
  end

  def boot_profile_signing_message(_document), do: {:error, :invalid_envelope}

  @doc """
  Verifies canonical boot-profile manifest bytes against a detached signature.

  Trusted signer key material is injected. Manifest-carried Platform key
  material is authenticated output and is never used to verify the manifest.
  """
  @spec verify_boot_profile(term(), term(), term()) :: {:ok, map()} | {:error, atom()}
  def verify_boot_profile(manifest_bytes, signature_bytes, verifier_input)
      when is_binary(manifest_bytes) and is_binary(signature_bytes) do
    with {:ok, manifest} <- decode_boot_profile_manifest_bytes(manifest_bytes),
         {:ok, signature} <- decode_boot_profile_signature_bytes(signature_bytes),
         {:ok, verifier} <- validate_boot_profile_verifier_input(verifier_input),
         {:ok, digest} <- boot_profile_digest_of(manifest),
         true <- secure_equal?(digest, signature["manifest_sha256"]),
         {:ok, trusted} <- boot_profile_resolve_signer(signature, verifier),
         {:ok, trusted_pub} <- boot_profile_decode_key(trusted["public_key"]),
         :ok <-
           boot_profile_match_key_id(
             signature["key_id"],
             trusted_pub,
             :signer_key_id_mismatch
           ),
         {:ok, message} <- boot_profile_signing_message(signature),
         {:ok, signature_raw} <- boot_profile_decode_signature(signature["signature"]),
         :ok <- boot_profile_verify_ed25519(message, signature_raw, trusted_pub),
         {:ok, platform_pub} <- boot_profile_decode_key(manifest["platform_public_key"]),
         :ok <-
           boot_profile_match_key_id(
             manifest["platform_key_id"],
             platform_pub,
             :platform_key_id_mismatch
           ),
         :ok <-
           boot_profile_check_window(
             verifier["now"],
             manifest["valid_from"],
             manifest["valid_until"]
           ),
         :ok <- boot_profile_check_epoch(manifest["boot_epoch"], verifier["min_boot_epoch"]),
         :ok <-
           boot_profile_check_revoked(
             signature["key_id"],
             verifier["revoked_signer_key_ids"],
             :signer_revoked
           ),
         :ok <-
           boot_profile_check_revoked(
             manifest["platform_key_id"],
             verifier["revoked_platform_key_ids"],
             :platform_key_revoked
           ),
         :ok <-
           boot_profile_match_text(
             manifest["release_id"],
             verifier["expected_release_id"],
             :release_mismatch
           ),
         :ok <-
           boot_profile_match_text(
             manifest["profile_id"],
             verifier["expected_profile_id"],
             :profile_mismatch
           ),
         :ok <-
           boot_profile_match_text(
             manifest["revocation_input_id"],
             verifier["expected_revocation_input_id"],
             :revocation_input_mismatch
           ),
         :ok <-
           boot_profile_match_payloads(
             manifest["payload_digests"],
             verifier["expected_payload_digests"]
           ) do
      {:ok,
       %{
         "manifest" => manifest,
         "manifest_sha256" => digest,
         "signer_id" => signature["signer_id"],
         "signer_key_id" => signature["key_id"]
       }}
    else
      false -> {:error, :digest_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_boot_profile(manifest_bytes, signature_bytes, _verifier_input)
      when not is_binary(manifest_bytes) or not is_binary(signature_bytes) do
    {:error, :malformed_encoding}
  end

  @doc "Returns a closed, byte-stable unsigned boot-profile fixture."
  @spec boot_profile_fixture() :: map()
  def boot_profile_fixture do
    %{
      "schema" => @boot_profile_schema,
      "version" => @version,
      "release_id" => "arbor.platform.release.1",
      "profile_id" => "safe_recovery",
      "boot_epoch" => 1,
      "platform_key_id" => @boot_profile_platform_key_id,
      "platform_public_key" => @boot_profile_platform_public_key,
      "payload_digests" => [
        %{
          "id" => "payload.kernel",
          "sha256" => String.duplicate("11", 32)
        },
        %{
          "id" => "payload.kernel_runtime",
          "sha256" => String.duplicate("22", 32)
        }
      ],
      "valid_from" => @fixture_time,
      "valid_until" => "2027-08-17T00:00:00Z",
      "revocation_input_id" => "revocation.platform.1"
    }
  end

  @doc "Returns a closed, byte-stable detached boot-profile signature fixture."
  @spec boot_profile_signature_fixture() :: map()
  def boot_profile_signature_fixture do
    %{
      "schema" => @boot_profile_signature_schema,
      "version" => @version,
      "domain" => @boot_profile_schema,
      "manifest_encoding" => @payload_encoding,
      "manifest_sha256" => @boot_profile_manifest_sha256,
      "signer_id" => "installer.arbor",
      "key_id" => @boot_profile_installer_key_id,
      "signature" => @boot_profile_signature_hex
    }
  end

  defp keys_for(:artifact_manifest), do: @artifact_keys
  defp keys_for(:provider_handle), do: @handle_keys
  defp keys_for(:activation_transaction), do: @transaction_keys
  defp keys_for(:activation_authorization), do: @activation_authorization_keys
  defp keys_for(:activation_receipt), do: @receipt_keys
  defp keys_for(:invocation_authorization), do: @invocation_authorization_keys
  defp keys_for(:invocation_request), do: @invocation_request_keys
  defp keys_for(:invocation_result), do: @invocation_result_keys

  defp validate_kind(:artifact_manifest, doc) do
    with :ok <- exact(doc["schema"], schema(:artifact_manifest)),
         :ok <- exact(doc["version"], @version),
         :ok <- id(doc["artifact_id"]),
         :ok <- id(doc["artifact_version"]),
         :ok <- member(doc["kind"], @artifact_kinds),
         :ok <- agent_id(doc["author_id"]),
         :ok <- digest(doc["payload_set_sha256"]),
         :ok <- protocol_list(doc["required_protocols"]),
         :ok <- protocol_list(doc["provided_protocols"]),
         :ok <- digest(doc["contribution_set_sha256"]),
         :ok <- member(doc["requested_isolation"], @isolations),
         :ok <- compatibility(doc["compatibility"]) do
      digest(doc["provenance_sha256"])
    end
  end

  defp validate_kind(:provider_handle, doc) do
    with :ok <- exact(doc["schema"], schema(:provider_handle)),
         :ok <- exact(doc["version"], @version),
         :ok <- id(doc["handle_id"]),
         :ok <- id(doc["protocol_id"]),
         :ok <- id(doc["protocol_version"]),
         :ok <- member(doc["transport_class"], @transports),
         :ok <- digest(doc["artifact_sha256"]),
         :ok <- agent_id(doc["activation_principal"]),
         :ok <- generation(doc["generation"]),
         :ok <- id(doc["lease_id"]),
         :ok <- timestamp(doc["lease_expires_at"]) do
      generation(doc["health_epoch"])
    end
  end

  defp validate_kind(:activation_transaction, doc) do
    with :ok <- exact(doc["schema"], schema(:activation_transaction)),
         :ok <- exact(doc["version"], @version),
         :ok <- id(doc["transaction_id"]),
         :ok <- id(doc["boot_profile_id"]),
         :ok <- digest(doc["boot_profile_sha256"]),
         :ok <- digest(doc["artifact_sha256"]),
         :ok <- digest(doc["payload_set_sha256"]),
         :ok <- agent_id(doc["principal_id"]),
         :ok <- generation(doc["generation"]),
         :ok <- grant_list(doc["requested_grants"]),
         :ok <- member(doc["admitted_isolation"], @isolations),
         :ok <- staged_effects(doc["staged_effects"]) do
      timestamp(doc["deadline"])
    end
  end

  defp validate_kind(:activation_authorization, doc) do
    with :ok <- exact(doc["schema"], schema(:activation_authorization)),
         :ok <- exact(doc["version"], @version),
         :ok <- digest(doc["transaction_sha256"]),
         :ok <- agent_id(doc["issuer_id"]),
         :ok <- digest(doc["key_id"]),
         :ok <- id(doc["audience_host_id"]),
         :ok <- id(doc["audience_install_id"]),
         :ok <- generation(doc["boot_epoch"]),
         :ok <- digest(doc["boot_profile_sha256"]),
         :ok <- timestamp(doc["issued_at"]),
         :ok <- timestamp(doc["expires_at"]) do
      nonce(doc["nonce"])
    end
  end

  defp validate_kind(:activation_receipt, doc) do
    with :ok <- exact(doc["schema"], schema(:activation_receipt)),
         :ok <- exact(doc["version"], @version),
         :ok <- id(doc["transaction_id"]),
         :ok <- digest(doc["transaction_sha256"]),
         :ok <- digest(doc["artifact_sha256"]),
         :ok <- agent_id(doc["principal_id"]),
         :ok <- generation(doc["generation"]),
         :ok <- receipt_effects(doc["effects"]),
         :ok <- member(doc["state"], @receipt_states),
         :ok <- digest(doc["intent_sha256"]) do
      member(doc["cleanup_disposition"], @cleanup)
    end
  end

  defp validate_kind(:invocation_authorization, doc) do
    with :ok <- exact(doc["schema"], schema(:invocation_authorization)),
         :ok <- exact(doc["version"], @version),
         :ok <- agent_id(doc["caller_principal"]),
         :ok <- resource(doc["resource"]),
         :ok <- id(doc["action"]),
         :ok <- id(doc["capability_id"]),
         :ok <- id(doc["trust_decision_id"]),
         :ok <- id(doc["handle_id"]),
         :ok <- generation(doc["generation"]),
         :ok <- id(doc["lease_id"]),
         :ok <- id(doc["protocol_id"]),
         :ok <- id(doc["operation"]),
         :ok <- digest(doc["request_sha256"]),
         :ok <- timestamp(doc["deadline"]),
         :ok <- id(doc["task_id"]),
         :ok <- id(doc["session_id"]),
         :ok <- id(doc["correlation_id"]),
         :ok <- digest(doc["taint_sha256"]),
         :ok <- member(doc["egress_mode"], @egress_modes),
         :ok <- constraints(doc["resource_constraints"]),
         :ok <- id(doc["audience"]) do
      nonce(doc["nonce"])
    end
  end

  defp validate_kind(:invocation_request, doc) do
    with :ok <- exact(doc["schema"], schema(:invocation_request)),
         :ok <- exact(doc["version"], @version),
         :ok <- id(doc["protocol_id"]),
         :ok <- id(doc["protocol_schema"]),
         :ok <- generation(doc["generation"]),
         :ok <- digest(doc["request_sha256"]),
         :ok <- digest(doc["payload_sha256"]),
         :ok <- payload_map(doc["payload"]),
         {:ok, digest} <- digest_of(doc["payload"]),
         true <- secure_equal?(digest, doc["payload_sha256"]) do
      :ok
    else
      false -> {:error, :digest_mismatch}
      other -> other
    end
  end

  defp validate_kind(:invocation_result, doc) do
    with :ok <- exact(doc["schema"], schema(:invocation_result)),
         :ok <- exact(doc["version"], @version),
         :ok <- id(doc["protocol_id"]),
         :ok <- id(doc["protocol_schema"]),
         :ok <- generation(doc["generation"]),
         :ok <- digest(doc["request_sha256"]),
         :ok <- digest(doc["payload_sha256"]),
         :ok <- member(doc["status"], @result_statuses),
         :ok <- result_error(doc["status"], doc["error_code"]),
         :ok <- digest(doc["result_sha256"]),
         :ok <- digest(doc["taint_sha256"]),
         :ok <- metering(doc["metering"]) do
      member(doc["effect_disposition"], @dispositions)
    end
  end

  defp exact_keys(value, keys) when is_map(value) and not is_struct(value) do
    actual = Map.keys(value)

    cond do
      Enum.any?(actual, &(not is_binary(&1))) ->
        {:error, :mixed_keys}

      map_size(value) != length(keys) ->
        {:error, :invalid_envelope_shape}

      Enum.sort(actual) != Enum.sort(keys) ->
        {:error, :invalid_envelope_shape}

      true ->
        :ok
    end
  end

  defp exact_keys(_value, _keys), do: {:error, :invalid_envelope}

  defp exact(value, value), do: :ok
  defp exact(_value, _expected), do: {:error, :invalid_field}

  defp member(value, allowed) when is_binary(value) do
    if MapSet.member?(allowed, value), do: :ok, else: {:error, :invalid_field}
  end

  defp member(_value, _allowed), do: {:error, :invalid_field}

  defp digest(value) when is_binary(value) do
    if String.valid?(value) and Regex.match?(@sha256_re, value),
      do: :ok,
      else: {:error, :invalid_hash}
  end

  defp digest(_value), do: {:error, :invalid_hash}

  defp nonce(value) when is_binary(value) do
    if String.valid?(value) and Regex.match?(@nonce_re, value),
      do: :ok,
      else: {:error, :invalid_nonce}
  end

  defp nonce(_value), do: {:error, :invalid_nonce}

  defp signature(value) when is_binary(value) do
    if String.valid?(value) and Regex.match?(@signature_re, value),
      do: :ok,
      else: {:error, :invalid_signature}
  end

  defp signature(_value), do: {:error, :invalid_signature}

  defp id(value) when is_binary(value) do
    cond do
      not String.valid?(value) -> {:error, :invalid_id}
      byte_size(value) > @max_id_bytes -> {:error, :invalid_id}
      Regex.match?(@id_re, value) -> :ok
      true -> {:error, :invalid_id}
    end
  end

  defp id(_value), do: {:error, :invalid_id}

  defp agent_id(value) when is_binary(value) do
    if String.valid?(value) and Regex.match?(@agent_re, value),
      do: :ok,
      else: {:error, :invalid_principal}
  end

  defp agent_id(_value), do: {:error, :invalid_principal}

  defp resource(value) when is_binary(value) do
    if String.valid?(value) and Regex.match?(@resource_re, value),
      do: :ok,
      else: {:error, :invalid_resource}
  end

  defp resource(_value), do: {:error, :invalid_resource}

  defp timestamp(value) when is_binary(value) do
    if String.valid?(value) and Regex.match?(@time_re, value),
      do: :ok,
      else: {:error, :invalid_timestamp}
  end

  defp timestamp(_value), do: {:error, :invalid_timestamp}

  defp generation(value) when is_integer(value) and value >= 1 and value <= 1_000_000_000,
    do: :ok

  defp generation(_value), do: {:error, :invalid_generation}

  defp non_neg(value) when is_integer(value) and value >= 0 and value <= 1_000_000_000, do: :ok
  defp non_neg(_value), do: {:error, :invalid_bound}

  defp protocol_list(list) when is_list(list) and length(list) <= @max_list do
    reduce_unique(list, MapSet.new(), fn item, seen ->
      with :ok <- exact_keys(item, @protocol_keys),
           :ok <- id(item["id"]),
           :ok <- id(item["version"]),
           false <- MapSet.member?(seen, item["id"]) do
        {:ok, MapSet.put(seen, item["id"])}
      else
        true -> {:error, :duplicate_identifier}
        other -> other
      end
    end)
  end

  defp protocol_list(_list), do: {:error, :invalid_field}

  defp compatibility(value) do
    with :ok <- exact_keys(value, @compatibility_keys),
         :ok <- id(value["min_host_version"]) do
      id(value["max_host_version"])
    end
  end

  defp grant_list(list) when is_list(list) and length(list) <= @max_list do
    reduce_unique(list, MapSet.new(), fn item, seen ->
      with :ok <- exact_keys(item, @grant_keys),
           :ok <- resource(item["resource"]),
           :ok <- id(item["action"]),
           false <- MapSet.member?(seen, item["resource"]) do
        {:ok, MapSet.put(seen, item["resource"])}
      else
        true -> {:error, :duplicate_identifier}
        other -> other
      end
    end)
  end

  defp grant_list(_list), do: {:error, :invalid_field}

  defp staged_effects(list) when is_list(list) and list != [] and length(list) <= @max_list do
    reduce_unique(list, MapSet.new(), fn item, seen ->
      with :ok <- exact_keys(item, @staged_effect_keys),
           :ok <- id(item["id"]),
           :ok <- member(item["class"], @effect_classes),
           :ok <- id(item["kind"]),
           false <- MapSet.member?(seen, item["id"]) do
        {:ok, MapSet.put(seen, item["id"])}
      else
        true -> {:error, :duplicate_identifier}
        other -> other
      end
    end)
  end

  defp staged_effects(_list), do: {:error, :invalid_field}

  defp receipt_effects(list) when is_list(list) and list != [] and length(list) <= @max_list do
    reduce_unique(list, MapSet.new(), fn item, seen ->
      with :ok <- exact_keys(item, @receipt_effect_keys),
           :ok <- id(item["id"]),
           :ok <- member(item["class"], @effect_classes),
           :ok <- member(item["state"], @effect_states),
           false <- MapSet.member?(seen, item["id"]) do
        {:ok, MapSet.put(seen, item["id"])}
      else
        true -> {:error, :duplicate_identifier}
        other -> other
      end
    end)
  end

  defp receipt_effects(_list), do: {:error, :invalid_field}

  defp constraints(value) do
    with :ok <- exact_keys(value, @constraint_keys),
         :ok <- non_neg(value["max_bytes"]) do
      non_neg(value["max_ms"])
    end
  end

  defp metering(value) do
    with :ok <- exact_keys(value, @metering_keys),
         :ok <- non_neg(value["tokens"]),
         :ok <- non_neg(value["bytes"]) do
      non_neg(value["ms"])
    end
  end

  defp payload_map(value) when is_map(value) and not is_struct(value) do
    if Enum.any?(Map.keys(value), &(not is_binary(&1))) do
      {:error, :mixed_keys}
    else
      case TaintEnvelope.canonical_json(value) do
        {:ok, _bytes} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp payload_map(_value), do: {:error, :invalid_payload}

  defp result_error("ok", nil), do: :ok
  defp result_error("ok", _code), do: {:error, :invalid_error_code}

  defp result_error("error", code) when is_binary(code) do
    if Enum.any?(@error_codes, fn {_group, codes} -> MapSet.member?(codes, code) end),
      do: :ok,
      else: {:error, :invalid_error_code}
  end

  defp result_error(_status, _code), do: {:error, :invalid_error_code}

  defp reduce_unique([], _seen, _fun), do: :ok

  defp reduce_unique([item | rest], seen, fun) do
    case fun.(item, seen) do
      {:ok, next} -> reduce_unique(rest, next, fun)
      {:error, _} = error -> error
    end
  end

  defp fixture_digest!(payload) do
    {:ok, digest} = digest_of(payload)
    digest
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  rescue
    _ -> false
  end

  defp secure_equal?(_left, _right), do: false

  defp encode_validated_boot_profile(document, validator) do
    with {:ok, validated} <- validator.(document),
         {:ok, bytes} <- TaintEnvelope.canonical_json(validated),
         :ok <- boot_profile_bounded(bytes) do
      {:ok, bytes}
    end
  end

  defp digest_validated_boot_profile(document, validator) do
    with {:ok, validated} <- validator.(document),
         {:ok, digest} <- TaintEnvelope.payload_sha256(validated) do
      {:ok, digest}
    end
  end

  defp decode_boot_profile_bytes(bytes, validator) when is_binary(bytes) do
    cond do
      not String.valid?(bytes) ->
        {:error, :malformed_encoding}

      byte_size(bytes) > @boot_profile_max_bytes ->
        {:error, :payload_byte_limit}

      true ->
        case Jason.decode(bytes, objects: :ordered_objects) do
          {:ok, %Jason.OrderedObject{} = object} ->
            with :ok <- boot_profile_reject_duplicate_keys(object),
                 {:ok, map} <- boot_profile_materialize(object),
                 {:ok, validated} <- validator.(map),
                 {:ok, canonical} <- TaintEnvelope.canonical_json(validated),
                 :ok <- boot_profile_bounded(canonical),
                 true <- secure_equal?(canonical, bytes) do
              {:ok, validated}
            else
              false -> {:error, :non_canonical_bytes}
              {:error, reason} -> {:error, reason}
            end

          {:ok, _other} ->
            {:error, :malformed_encoding}

          {:error, _reason} ->
            {:error, :malformed_encoding}
        end
    end
  end

  defp decode_boot_profile_bytes(_bytes, _validator), do: {:error, :malformed_encoding}

  defp boot_profile_bounded(bytes) when byte_size(bytes) <= @boot_profile_max_bytes, do: :ok
  defp boot_profile_bounded(_bytes), do: {:error, :payload_byte_limit}

  defp boot_profile_reject_duplicate_keys(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, &elem(&1, 0))

    if length(keys) != MapSet.size(MapSet.new(keys)) do
      {:error, :duplicate_json_key}
    else
      Enum.reduce_while(values, :ok, fn {_key, value}, :ok ->
        case boot_profile_reject_duplicate_keys(value) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp boot_profile_reject_duplicate_keys(values) when is_list(values) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case boot_profile_reject_duplicate_keys(value) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp boot_profile_reject_duplicate_keys(_value), do: :ok

  defp boot_profile_materialize(%Jason.OrderedObject{values: values}) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      if is_binary(key) do
        case boot_profile_materialize(value) do
          {:ok, materialized} -> {:cont, {:ok, Map.put(acc, key, materialized)}}
          {:error, _} = error -> {:halt, error}
        end
      else
        {:halt, {:error, :mixed_keys}}
      end
    end)
  end

  defp boot_profile_materialize(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case boot_profile_materialize(value) do
        {:ok, materialized} -> {:cont, {:ok, [materialized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  defp boot_profile_materialize(value), do: {:ok, value}

  defp boot_profile_verifier_keys(value) when is_map(value) and not is_struct(value) do
    exact_keys(value, @boot_profile_verifier_keys)
  end

  defp boot_profile_verifier_keys(_value), do: {:error, :invalid_verifier_input}

  defp boot_profile_verifier_shape(:mixed_keys), do: :invalid_verifier_input
  defp boot_profile_verifier_shape(:invalid_envelope_shape), do: :invalid_verifier_input
  defp boot_profile_verifier_shape(:invalid_envelope), do: :invalid_verifier_input
  defp boot_profile_verifier_shape(reason), do: reason

  defp boot_profile_version_field(@version), do: :ok
  defp boot_profile_version_field(_value), do: {:error, :unsupported_version}

  defp boot_profile_encoding_field(@payload_encoding), do: :ok
  defp boot_profile_encoding_field(_value), do: {:error, :unsupported_encoding}

  defp boot_profile_epoch(value) when is_integer(value) and value >= 1 and value <= 1_000_000_000,
    do: :ok

  defp boot_profile_epoch(_value), do: {:error, :invalid_epoch}

  defp boot_profile_public_key(value) when is_binary(value) do
    if String.valid?(value) and Regex.match?(@sha256_re, value) do
      case Base.decode16(value, case: :lower) do
        {:ok, bytes} when byte_size(bytes) == 32 -> :ok
        _ -> {:error, :invalid_public_key}
      end
    else
      {:error, :invalid_public_key}
    end
  end

  defp boot_profile_public_key(_value), do: {:error, :invalid_public_key}

  defp boot_profile_instant(value) when is_binary(value) do
    if String.valid?(value) do
      case DateTime.from_iso8601(value) do
        {:ok, %DateTime{} = datetime, 0} ->
          if boot_profile_utc_second?(datetime) and DateTime.to_iso8601(datetime) == value do
            {:ok, datetime}
          else
            {:error, :invalid_timestamp}
          end

        _ ->
          {:error, :invalid_timestamp}
      end
    else
      {:error, :invalid_timestamp}
    end
  end

  defp boot_profile_instant(_value), do: {:error, :invalid_timestamp}

  defp boot_profile_utc_second?(%DateTime{} = datetime) do
    datetime.calendar == Calendar.ISO and datetime.time_zone in ["Etc/UTC", "UTC"] and
      datetime.utc_offset == 0 and datetime.std_offset == 0 and datetime.microsecond == {0, 0}
  end

  defp boot_profile_validity_window(valid_from, valid_until) do
    if DateTime.compare(valid_from, valid_until) == :gt do
      {:error, :invalid_validity_window}
    else
      :ok
    end
  end

  defp boot_profile_payload_digests(list)
       when is_list(list) and list != [] and length(list) <= @max_list do
    list
    |> Enum.reduce_while({:ok, nil}, fn item, {:ok, previous_id} ->
      with :ok <- exact_keys(item, @boot_profile_payload_digest_keys),
           :ok <- id(item["id"]),
           :ok <- digest(item["sha256"]),
           :ok <- boot_profile_sorted_id(previous_id, item["id"]) do
        {:cont, {:ok, item["id"]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _last_id} -> :ok
      {:error, _} = error -> error
    end
  end

  defp boot_profile_payload_digests(_list), do: {:error, :invalid_field}

  defp boot_profile_sorted_id(nil, _id), do: :ok
  defp boot_profile_sorted_id(previous, id) when previous < id, do: :ok
  defp boot_profile_sorted_id(previous, id) when previous == id, do: {:error, :duplicate_identifier}
  defp boot_profile_sorted_id(_previous, _id), do: {:error, :invalid_field}

  defp boot_profile_key_id_list(list) when is_list(list) and length(list) <= @max_list do
    reduce_unique(list, MapSet.new(), fn item, seen ->
      with :ok <- digest(item),
           false <- MapSet.member?(seen, item) do
        {:ok, MapSet.put(seen, item)}
      else
        true -> {:error, :duplicate_identifier}
        other -> other
      end
    end)
  end

  defp boot_profile_key_id_list(_list), do: {:error, :invalid_field}

  defp boot_profile_trusted_signers(list) when is_list(list) and length(list) <= @max_list do
    reduce_unique(list, MapSet.new(), fn item, seen ->
      with :ok <- exact_keys(item, @boot_profile_trusted_signer_keys),
           :ok <- id(item["signer_id"]),
           :ok <- digest(item["key_id"]),
           :ok <- boot_profile_public_key(item["public_key"]) do
        identity = {item["signer_id"], item["key_id"]}

        if MapSet.member?(seen, identity) do
          {:error, :duplicate_identifier}
        else
          {:ok, MapSet.put(seen, identity)}
        end
      end
    end)
  end

  defp boot_profile_trusted_signers(_list), do: {:error, :invalid_field}

  defp boot_profile_resolve_signer(signature, verifier) do
    matches =
      Enum.filter(verifier["trusted_signers"], fn signer ->
        signer["signer_id"] == signature["signer_id"] and signer["key_id"] == signature["key_id"]
      end)

    case matches do
      [trusted] -> {:ok, trusted}
      _ -> {:error, :untrusted_signer}
    end
  end

  defp boot_profile_decode_key(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, bytes} when byte_size(bytes) == 32 -> {:ok, bytes}
      _ -> {:error, :invalid_public_key}
    end
  end

  defp boot_profile_decode_key(_hex), do: {:error, :invalid_public_key}

  defp boot_profile_decode_signature(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, bytes} when byte_size(bytes) == 64 -> {:ok, bytes}
      _ -> {:error, :invalid_signature}
    end
  end

  defp boot_profile_decode_signature(_hex), do: {:error, :invalid_signature}

  defp boot_profile_match_key_id(key_id, public_key_bytes, error) do
    expected = boot_profile_hex_key_id_bytes(public_key_bytes)

    if secure_equal?(key_id, expected), do: :ok, else: {:error, error}
  end

  defp boot_profile_verify_ed25519(message, signature, public_key) do
    if :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519]) do
      :ok
    else
      {:error, :signature_mismatch}
    end
  rescue
    _ -> {:error, :signature_mismatch}
  catch
    _, _ -> {:error, :signature_mismatch}
  end

  defp boot_profile_check_window(now, valid_from, valid_until) do
    with {:ok, now_dt} <- boot_profile_instant(now),
         {:ok, from_dt} <- boot_profile_instant(valid_from),
         {:ok, until_dt} <- boot_profile_instant(valid_until) do
      cond do
        DateTime.compare(now_dt, from_dt) == :lt -> {:error, :not_yet_valid}
        DateTime.compare(now_dt, until_dt) == :gt -> {:error, :expired}
        true -> :ok
      end
    end
  end

  defp boot_profile_check_epoch(boot_epoch, min_boot_epoch) when boot_epoch < min_boot_epoch,
    do: {:error, :stale_epoch}

  defp boot_profile_check_epoch(_boot_epoch, _min_boot_epoch), do: :ok

  defp boot_profile_check_revoked(key_id, revoked_ids, error) do
    if Enum.any?(revoked_ids, &secure_equal?(&1, key_id)), do: {:error, error}, else: :ok
  end

  defp boot_profile_match_text(actual, expected, error) do
    if secure_equal?(actual, expected), do: :ok, else: {:error, error}
  end

  defp boot_profile_match_payloads(actual, expected) do
    with {:ok, left} <- TaintEnvelope.canonical_json(actual),
         {:ok, right} <- TaintEnvelope.canonical_json(expected),
         true <- secure_equal?(left, right) do
      :ok
    else
      false -> {:error, :payload_mismatch}
      {:error, _reason} -> {:error, :payload_mismatch}
    end
  end

  defp boot_profile_hex_key_id_bytes(public_key_bytes) do
    Base.encode16(:crypto.hash(:sha256, public_key_bytes), case: :lower)
  end
end
