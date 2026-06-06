defmodule Arbor.Scheduler.CapsFile do
  @moduledoc """
  Loader for signed `.caps.json` files that ride alongside scheduler pipeline
  DOTs.

  Phase 3 of the scheduler-privesc redesign (Option 2-signed). A `.caps.json`
  file declares the capabilities a pipeline needs. The file is signed by
  its author (an enrolled issuer in `Arbor.Security.IssuerRegistry`). At
  pipeline run time, `PipelineRunner` calls `load/1`; on success, the
  returned descriptors are minted as actual capabilities for the per-run
  ephemeral identity.

  ## File format

  ```json
  {
    "version": 1,
    "issuer_id": "agent_<hex>",
    "capabilities": [
      { "resource_uri": "arbor://...", "constraints": {} }
    ],
    "signature": "<base64 ed25519 signature>"
  }
  ```

  Each capability declares a `resource_uri` (required) and optional
  `constraints`. The `signature` covers a canonical payload computed from
  the version, issuer_id, and capabilities (sorted by URI for determinism)
  — same length-prefix scheme as `Arbor.Contracts.Security.Capability.
  signing_payload/1` to prevent field-boundary attacks.

  ## Trust chain

  ```
  operator enrolls issuer X with envelope Y  →  IssuerRegistry.register
       │
       ▼
  issuer X signs caps.json declaring caps {Z₁, Z₂, …}
       │
       ▼
  CapsFile.load verifies: signature valid, each Zᵢ ⊆ Y
       │
       ▼
  PipelineRunner mints Zᵢ as caps for the per-run ephemeral principal
  ```

  Each step fails closed: bad signature → reject; cap outside envelope →
  reject; revoked issuer → reject. Capability-declaring authority never
  escapes the issuer's enrolled bound.

  ## Failure modes

  The loader returns one of these specific errors so callers can distinguish:

    - `{:error, {:read_failed, reason}}` — file missing, permission denied
    - `{:error, {:invalid_json, reason}}` — JSON syntax error
    - `{:error, {:invalid_schema, reason}}` — missing field, wrong type
    - `{:error, :issuer_not_found}` — issuer not enrolled
    - `{:error, :issuer_revoked}` — issuer was revoked post-signing
    - `{:error, :identity_unavailable}` — issuer identity suspended/revoked
    - `{:error, :invalid_signature}` — signature doesn't verify
    - `{:error, {:cap_exceeds_envelope, cap_uri}}` — declared cap outside
      issuer's enrolled envelope

  Each one is fail-closed; there is no fallback that accepts an unverified
  declaration.
  """

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.Crypto
  alias Arbor.Security.IssuerRegistry

  @current_version 1

  @type cap_descriptor :: %{
          required(:resource_uri) => String.t(),
          required(:constraints) => map(),
          required(:issuer_id) => String.t()
        }

  @doc """
  Load and verify a `.caps.json` file. Returns descriptors ready for the
  caller to mint as capabilities.

  Verification chain (in order, each step fails closed):
    1. File readable
    2. JSON parseable
    3. Schema valid (version, issuer_id, capabilities, signature present)
    4. Issuer enrolled in IssuerRegistry (active, identity available)
    5. Signature verifies against issuer's public key
    6. Each declared cap is `envelope_subset?` of issuer's max envelope
  """
  @spec load(Path.t()) ::
          {:ok, [cap_descriptor()]}
          | {:error,
             {:read_failed, term()}
             | {:invalid_json, term()}
             | {:invalid_schema, term()}
             | :issuer_not_found
             | :issuer_revoked
             | :identity_unavailable
             | :invalid_signature
             | {:cap_exceeds_envelope, String.t()}}
  def load(path) do
    with {:ok, content} <- read_file(path),
         {:ok, raw} <- parse_json(content),
         {:ok, parsed} <- validate_schema(raw),
         {:ok, %{public_key: pk, max_envelope_caps: envelopes}} <-
           lookup_issuer(parsed.issuer_id),
         :ok <- verify_signature(parsed, pk),
         :ok <- verify_all_caps_in_envelope(parsed.capabilities, envelopes, parsed.issuer_id) do
      # Tag each descriptor with the verified issuer. RunIdentity carries
      # this forward into capability metadata as provenance, which
      # AuthDecision uses to bypass ceiling :ask for bounded, signed grants.
      {:ok, Enum.map(parsed.capabilities, &Map.put(&1, :issuer_id, parsed.issuer_id))}
    end
  end

  @doc """
  Compute the canonical signing payload for a parsed caps file.

  Exposed so signing tooling (Phase 4 mix task) can produce the exact
  bytes that load/1 will verify against. Length-prefixed fields:

    - version (string)
    - issuer_id
    - canonical capabilities JSON (sorted by resource_uri)

  This mirrors `Capability.signing_payload/1` semantics.
  """
  @spec signing_payload(map()) :: binary()
  def signing_payload(%{version: version, issuer_id: issuer_id, capabilities: caps}) do
    sorted_caps = Enum.sort_by(caps, & &1.resource_uri)

    caps_json =
      sorted_caps
      |> Enum.map(fn %{resource_uri: uri, constraints: c} ->
        %{"resource_uri" => uri, "constraints" => c}
      end)
      |> Jason.encode!()

    length_prefix(Integer.to_string(version)) <>
      length_prefix(issuer_id) <>
      length_prefix(caps_json)
  end

  @doc """
  Build the in-memory representation of a caps file payload from constituent
  parts. Used by signing tooling (Phase 4) before serialization.
  """
  @spec build(String.t(), [cap_descriptor()]) :: map()
  def build(issuer_id, capabilities) when is_binary(issuer_id) and is_list(capabilities) do
    %{
      version: @current_version,
      issuer_id: issuer_id,
      capabilities: capabilities
    }
  end

  # ===========================================================================
  # Internal: load pipeline steps
  # ===========================================================================

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp parse_json(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp validate_schema(raw) when is_map(raw) do
    with {:ok, version} <- fetch_int(raw, "version"),
         :ok <- check_version(version),
         {:ok, issuer_id} <- fetch_string(raw, "issuer_id"),
         {:ok, caps_raw} <- fetch_list(raw, "capabilities"),
         {:ok, capabilities} <- validate_capabilities(caps_raw),
         {:ok, signature_b64} <- fetch_string(raw, "signature"),
         {:ok, signature} <- decode_signature(signature_b64) do
      {:ok,
       %{
         version: version,
         issuer_id: issuer_id,
         capabilities: capabilities,
         signature: signature
       }}
    end
  end

  defp validate_schema(_), do: {:error, {:invalid_schema, :not_a_map}}

  # An empty capabilities list is a valid declaration meaning "this
  # pipeline does not need any granted caps." Shell-only pipelines (no
  # `exec` action nodes) fit this shape — shell stdout doesn't go through
  # the action-layer capability check, so no caps are needed for the run
  # to function. The empty declaration is the explicit, reviewable form
  # of "this pipeline runs without resource access" — distinct from "no
  # caps file at all" which Phase 5's PipelineRunner refuses.
  defp validate_capabilities([]), do: {:ok, []}

  defp validate_capabilities(caps) when is_list(caps) do
    caps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw_cap, idx}, {:ok, acc} ->
      case validate_capability(raw_cap, idx) do
        {:ok, descriptor} -> {:cont, {:ok, [descriptor | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, descriptors} -> {:ok, Enum.reverse(descriptors)}
      err -> err
    end
  end

  defp validate_capabilities(_), do: {:error, {:invalid_schema, :capabilities_not_list}}

  defp validate_capability(%{"resource_uri" => uri} = raw, _idx) when is_binary(uri) do
    constraints =
      case Map.get(raw, "constraints", %{}) do
        m when is_map(m) -> atomize_known_constraint_keys(m)
        _ -> %{}
      end

    {:ok, %{resource_uri: uri, constraints: constraints}}
  end

  defp validate_capability(_, idx),
    do: {:error, {:invalid_schema, {:capability_missing_resource_uri, idx}}}

  defp atomize_known_constraint_keys(map) do
    # Reuse the same known keys as Capability.atomize_known_constraint_keys/1.
    # Atom keys make envelope_subset? consistent with caps minted via
    # Capability.new/1.
    known = [:time_window, :allowed_paths, :rate_limit, :requires_approval, :taint_policy]

    Enum.reduce(known, map, fn key, acc ->
      string_key = Atom.to_string(key)

      case Map.pop(acc, string_key) do
        {nil, _} -> acc
        {value, rest} -> Map.put(rest, key, value)
      end
    end)
  end

  defp check_version(v) when v == @current_version, do: :ok
  defp check_version(v), do: {:error, {:invalid_schema, {:unsupported_version, v}}}

  defp fetch_int(map, key) do
    case Map.get(map, key) do
      v when is_integer(v) -> {:ok, v}
      _ -> {:error, {:invalid_schema, {:missing_or_invalid, key}}}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:invalid_schema, {:missing_or_invalid, key}}}
    end
  end

  defp fetch_list(map, key) do
    case Map.get(map, key) do
      v when is_list(v) -> {:ok, v}
      _ -> {:error, {:invalid_schema, {:missing_or_invalid, key}}}
    end
  end

  defp decode_signature(b64) do
    case Base.decode64(b64) do
      {:ok, sig} when byte_size(sig) > 0 -> {:ok, sig}
      _ -> {:error, {:invalid_schema, :invalid_signature_encoding}}
    end
  end

  defp lookup_issuer(issuer_id) do
    case IssuerRegistry.lookup(issuer_id) do
      {:ok, _} = ok -> ok
      {:error, :not_found} -> {:error, :issuer_not_found}
      {:error, :revoked} -> {:error, :issuer_revoked}
      {:error, :identity_unavailable} -> {:error, :identity_unavailable}
      {:error, other} -> {:error, other}
    end
  end

  defp verify_signature(parsed, public_key) do
    payload = signing_payload(parsed)

    if Crypto.verify(payload, parsed.signature, public_key) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp verify_all_caps_in_envelope(capabilities, envelopes, issuer_id) do
    Enum.reduce_while(capabilities, :ok, fn descriptor, :ok ->
      case build_transient_cap(descriptor, issuer_id) do
        {:ok, cap} ->
          # Multi-envelope: a declared cap is acceptable if it fits within
          # AT LEAST ONE of the issuer's enrolled envelopes. This is how a
          # single issuer can be authorized for non-overlapping resource
          # patterns (e.g. read of subtree X, write of subtree Y) without
          # using a coarse pattern that dilutes the bound.
          if Enum.any?(envelopes, &Capability.envelope_subset?(cap, &1)) do
            {:cont, :ok}
          else
            {:halt, {:error, {:cap_exceeds_envelope, descriptor.resource_uri}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:invalid_schema, reason}}}
      end
    end)
  end

  defp build_transient_cap(%{resource_uri: uri, constraints: constraints}, issuer_id) do
    # Build a transient Capability for the envelope-subset check. The
    # principal_id is a placeholder ("<issuer>_pending_run") — the real
    # ephemeral principal is assigned at Phase 5 PipelineRunner integration.
    Capability.new(
      resource_uri: uri,
      principal_id: "#{issuer_id}_pending_run",
      constraints: constraints
    )
  end

  defp length_prefix(field) when is_binary(field) do
    <<byte_size(field)::32, field::binary>>
  end
end
