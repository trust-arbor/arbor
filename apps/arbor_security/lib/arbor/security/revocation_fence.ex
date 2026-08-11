defmodule Arbor.Security.RevocationFence do
  @moduledoc """
  Pure owner of the v1 expected-Record acknowledged-revoke fence schema.

  Owns the closed keyset, JSON-safe bounds, domain-separated capability digest,
  construction, admission, expected-identity derivation, and observed matching.

  Pure only: no IO, store access, GenServer calls, logging, or signals.
  Cryptographic current-authority proof of a caller Capability is the public
  facade's responsibility (`Arbor.Security`); this module admits shape/bounds
  and reduces to a closed expected identity. CapabilityStore re-admits the
  closed identity as defense in depth before its one authoritative read.

  ## Delegation chain boundary

  `delegation_chain` is excluded from `Capability.signing_payload/1` and from
  the closed expected identity. Nested chain constraints/signatures are
  legitimate opaque record state. Nested values are neither traversed,
  serialized, hashed, nor copied across owner mailboxes on the prepare path;
  only top-level list cardinality and entry-map shape are gated. Verification
  copies strip the chain to `[]` so SystemAuthority never receives nested
  chain content.
  """

  alias Arbor.Contracts.Security.Capability

  @kind "acknowledged_revoke_fence"
  @version 1
  @digest_domain "arbor.security.acknowledged_revoke_fence.v1\0"
  @keys MapSet.new([
          "kind",
          "version",
          "capability_id",
          "principal_id",
          "resource_uri",
          "record_id",
          "generation",
          "revision",
          "capability_digest"
        ])
  @max_principal_bytes 256
  @max_resource_bytes 2048
  @max_record_id_bytes 128
  @max_token 9_007_199_254_740_991

  # Expected-Capability pre-admission bounds
  @max_scalar_bytes 2048
  @max_map_keys 64
  @max_depth 6
  @max_nodes 1_024
  @max_list_len 64
  @max_delegatees 64
  @max_signature_bytes 64
  @max_chain_len 64
  @max_chain_entry_keys 16
  @max_zone_bytes 256
  @max_abs_offset_seconds 86_400
  @signed_int_min -9_223_372_036_854_775_808
  @signed_int_max_excl 9_223_372_036_854_775_808

  @expected_identity_keys MapSet.new([
                            :capability_id,
                            :principal_id,
                            :resource_uri,
                            :capability_digest
                          ])
  @expectations_keys MapSet.new([:capability_id, :principal_id, :resource_uri])

  @type fence :: %{
          required(String.t()) => String.t() | pos_integer()
        }

  @type expected_identity :: %{
          required(:capability_id) => String.t(),
          required(:principal_id) => String.t(),
          required(:resource_uri) => String.t(),
          required(:capability_digest) => String.t()
        }

  @type record_tokens :: %{
          required(:record_id) => String.t(),
          required(:generation) => pos_integer(),
          required(:revision) => pos_integer()
        }

  @type expectations :: %{
          required(:capability_id) => String.t(),
          required(:principal_id) => String.t(),
          required(:resource_uri) => String.t()
        }

  @doc """
  Admit a closed v1 fence against a caller capability id.
  """
  @spec admit_fence(String.t(), map()) :: :ok | {:error, :invalid_request}
  def admit_fence(capability_id, fence) do
    with :ok <- admit_fence_map(fence),
         :ok <- admit_fence_fields(capability_id, fence) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
  end

  @doc """
  Build a closed v1 fence from a verified capability and authoritative Record tokens.
  """
  @spec build_fence(Capability.t(), record_tokens()) :: fence()
  def build_fence(%Capability{} = cap, tokens) when is_map(tokens) do
    %{
      "kind" => @kind,
      "version" => @version,
      "capability_id" => cap.id,
      "principal_id" => cap.principal_id,
      "resource_uri" => cap.resource_uri,
      "record_id" => Map.fetch!(tokens, :record_id),
      "generation" => Map.fetch!(tokens, :generation),
      "revision" => Map.fetch!(tokens, :revision),
      "capability_digest" => capability_digest(cap)
    }
  end

  @doc """
  Domain-separated SHA-256 digest of `Capability.signing_payload/1`.
  """
  @spec capability_digest(Capability.t()) :: String.t()
  def capability_digest(%Capability{} = cap) do
    :crypto.hash(:sha256, @digest_domain <> Capability.signing_payload(cap))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Exact match of a fence against a verified capability and Record tokens.
  """
  @spec matches_observed?(fence(), Capability.t(), record_tokens()) :: boolean()
  def matches_observed?(fence, %Capability{} = cap, tokens) when is_map(fence) and is_map(tokens) do
    fence["capability_id"] == cap.id and
      fence["principal_id"] == cap.principal_id and
      fence["resource_uri"] == cap.resource_uri and
      fence["record_id"] == Map.fetch!(tokens, :record_id) and
      fence["generation"] == Map.fetch!(tokens, :generation) and
      fence["revision"] == Map.fetch!(tokens, :revision) and
      fence["capability_digest"] == capability_digest(cap)
  end

  def matches_observed?(_fence, _cap, _tokens), do: false

  @doc """
  Pure primitive admission of a caller Capability for capability-bound prepare.

  Validates shape/bounds (including exact 64-byte signature shape and DateTime
  primitive fields) without crypto, hashing, or owner calls. On success returns
  a verification copy with `delegation_chain` stripped to `[]` so nested chain
  state never crosses into SystemAuthority or CapabilityStore mailboxes.
  """
  @spec admit_expected_for_prepare(term()) ::
          {:ok, Capability.t()} | {:error, :invalid_request}
  def admit_expected_for_prepare(%Capability{} = cap) do
    with :ok <- admit_expected_capability(cap) do
      # Strip chain after top-level shape gate; do not copy nested entries.
      {:ok, %{cap | delegation_chain: []}}
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
  end

  def admit_expected_for_prepare(_), do: {:error, :invalid_request}

  @doc """
  Total-safe validation and reduction of a Capability to a closed expected identity.

  Always re-admits primitive fields before `signing_payload/1` / hashing.
  Does not trust prior admission.
  """
  @spec expected_identity(term()) ::
          {:ok, expected_identity()} | {:error, :invalid_request}
  def expected_identity(%Capability{} = cap) do
    with :ok <- admit_expected_capability(cap) do
      {:ok,
       %{
         capability_id: cap.id,
         principal_id: cap.principal_id,
         resource_uri: cap.resource_uri,
         capability_digest: capability_digest(cap)
       }}
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
  end

  def expected_identity(_), do: {:error, :invalid_request}

  @doc """
  Re-admit a closed expected identity at the store boundary (defense in depth).
  """
  @spec admit_expected_identity(term()) ::
          {:ok, expected_identity()} | {:error, :invalid_request}
  def admit_expected_identity(expected) when is_map(expected) and not is_struct(expected) do
    with :ok <- admit_expected_identity_map(expected),
         :ok <- admit_expected_identity_fields(expected) do
      {:ok,
       %{
         capability_id: expected.capability_id,
         principal_id: expected.principal_id,
         resource_uri: expected.resource_uri,
         capability_digest: expected.capability_digest
       }}
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
  end

  def admit_expected_identity(_), do: {:error, :invalid_request}

  @doc """
  Load-bearing match: exact capability_id, principal_id, resource_uri, and digest.
  """
  @spec match_expected(expected_identity(), Capability.t()) :: boolean()
  def match_expected(expected, %Capability{} = current) when is_map(expected) do
    expected.capability_id == current.id and
      expected.principal_id == current.principal_id and
      expected.resource_uri == current.resource_uri and
      expected.capability_digest == capability_digest(current)
  end

  def match_expected(_expected, _current), do: false

  @doc """
  Admit a fence once and require exact triple expectations. Returns the fence on success.
  """
  @spec admit_with_expectations(map(), term()) ::
          {:ok, fence()} | {:error, :invalid_request}
  def admit_with_expectations(fence, expectations) do
    with {:ok, exp} <- admit_expectations(expectations),
         :ok <- admit_fence(exp.capability_id, fence),
         true <- fence["capability_id"] == exp.capability_id,
         true <- fence["principal_id"] == exp.principal_id,
         true <- fence["resource_uri"] == exp.resource_uri do
      {:ok, fence}
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
  end

  # ---------------------------------------------------------------------------
  # Fence admission
  # ---------------------------------------------------------------------------

  defp admit_fence_map(fence) when is_map(fence) and not is_struct(fence) do
    if map_size(fence) != 9 do
      {:error, :invalid_request}
    else
      keys = Map.keys(fence)

      cond do
        not Enum.all?(keys, &is_binary/1) ->
          {:error, :invalid_request}

        MapSet.new(keys) != @keys ->
          {:error, :invalid_request}

        true ->
          :ok
      end
    end
  end

  defp admit_fence_map(_), do: {:error, :invalid_request}

  defp admit_fence_fields(capability_id, fence) do
    kind = Map.fetch!(fence, "kind")
    version = Map.fetch!(fence, "version")
    fence_cap_id = Map.fetch!(fence, "capability_id")
    principal_id = Map.fetch!(fence, "principal_id")
    resource_uri = Map.fetch!(fence, "resource_uri")
    record_id = Map.fetch!(fence, "record_id")
    generation = Map.fetch!(fence, "generation")
    revision = Map.fetch!(fence, "revision")
    digest = Map.fetch!(fence, "capability_digest")

    cond do
      kind != @kind ->
        {:error, :invalid_request}

      version != @version ->
        {:error, :invalid_request}

      not canonical_capability_id?(fence_cap_id) ->
        {:error, :invalid_request}

      fence_cap_id != capability_id ->
        {:error, :invalid_request}

      not bounded_nonempty_utf8?(principal_id, @max_principal_bytes) ->
        {:error, :invalid_request}

      not bounded_nonempty_utf8?(resource_uri, @max_resource_bytes) ->
        {:error, :invalid_request}

      not bounded_nonempty_utf8?(record_id, @max_record_id_bytes) ->
        {:error, :invalid_request}

      not positive_token?(generation) ->
        {:error, :invalid_request}

      not positive_token?(revision) ->
        {:error, :invalid_request}

      not fence_digest?(digest) ->
        {:error, :invalid_request}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Expected identity admission
  # ---------------------------------------------------------------------------

  defp admit_expected_identity_map(expected) do
    if map_size(expected) != 4 do
      {:error, :invalid_request}
    else
      keys = Map.keys(expected)

      cond do
        not Enum.all?(keys, &is_atom/1) ->
          {:error, :invalid_request}

        MapSet.new(keys) != @expected_identity_keys ->
          {:error, :invalid_request}

        true ->
          :ok
      end
    end
  end

  defp admit_expected_identity_fields(expected) do
    cond do
      not canonical_capability_id?(expected.capability_id) ->
        {:error, :invalid_request}

      not bounded_nonempty_utf8?(expected.principal_id, @max_principal_bytes) ->
        {:error, :invalid_request}

      not bounded_nonempty_utf8?(expected.resource_uri, @max_resource_bytes) ->
        {:error, :invalid_request}

      not fence_digest?(expected.capability_digest) ->
        {:error, :invalid_request}

      true ->
        :ok
    end
  end

  defp admit_expectations(expectations) when is_map(expectations) and not is_struct(expectations) do
    with :ok <- admit_expectations_map(expectations),
         :ok <- admit_expectations_fields(expectations) do
      {:ok,
       %{
         capability_id: expectations.capability_id,
         principal_id: expectations.principal_id,
         resource_uri: expectations.resource_uri
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp admit_expectations(_), do: {:error, :invalid_request}

  defp admit_expectations_map(expectations) do
    if map_size(expectations) != 3 do
      {:error, :invalid_request}
    else
      keys = Map.keys(expectations)

      cond do
        not Enum.all?(keys, &is_atom/1) ->
          {:error, :invalid_request}

        MapSet.new(keys) != @expectations_keys ->
          {:error, :invalid_request}

        true ->
          :ok
      end
    end
  end

  defp admit_expectations_fields(expectations) do
    cond do
      not canonical_capability_id?(expectations.capability_id) ->
        {:error, :invalid_request}

      not bounded_nonempty_utf8?(expectations.principal_id, @max_principal_bytes) ->
        {:error, :invalid_request}

      not bounded_nonempty_utf8?(expectations.resource_uri, @max_resource_bytes) ->
        {:error, :invalid_request}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Expected Capability pre-admission (before signing_payload/1)
  # ---------------------------------------------------------------------------

  defp admit_expected_capability(%Capability{} = cap) do
    with :ok <- admit_cap_id(cap.id),
         :ok <- admit_required_utf8(cap.principal_id, @max_principal_bytes),
         :ok <- admit_required_utf8(cap.resource_uri, @max_resource_bytes),
         :ok <- admit_required_utf8(cap.issuer_id, @max_scalar_bytes),
         :ok <- admit_parent_capability_id(cap.parent_capability_id),
         :ok <- admit_optional_utf8(cap.session_id),
         :ok <- admit_optional_utf8(cap.task_id),
         :ok <- admit_optional_utf8(cap.principal_scope),
         :ok <- admit_required_datetime(cap.granted_at),
         :ok <- admit_optional_datetime(cap.expires_at),
         :ok <- admit_optional_datetime(cap.not_before),
         :ok <- admit_optional_datetime(cap.signed_at),
         :ok <- admit_delegation_depth(cap.delegation_depth),
         :ok <- admit_max_uses(cap.max_uses),
         :ok <- admit_delegatees(cap.allowed_delegatees),
         :ok <- admit_signature(cap.issuer_signature),
         :ok <- admit_delegation_chain(cap.delegation_chain),
         :ok <- admit_signed_maps(cap.constraints, cap.metadata) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp admit_cap_id(id) do
    if canonical_capability_id?(id), do: :ok, else: {:error, :invalid_request}
  end

  defp admit_required_utf8(value, max_bytes) do
    if bounded_nonempty_utf8?(value, max_bytes), do: :ok, else: {:error, :invalid_request}
  end

  defp admit_optional_utf8(nil), do: :ok

  defp admit_optional_utf8(value) when is_binary(value) do
    if byte_size(value) <= @max_scalar_bytes and String.valid?(value) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp admit_optional_utf8(_), do: {:error, :invalid_request}

  # nil or canonical capability id only — empty string is not canonical.
  defp admit_parent_capability_id(nil), do: :ok

  defp admit_parent_capability_id(id) when is_binary(id) do
    cond do
      # Size-first bound before UTF-8 scan so attacker-sized binaries fail cheaply.
      byte_size(id) > @max_scalar_bytes ->
        {:error, :invalid_request}

      byte_size(id) == 0 ->
        {:error, :invalid_request}

      not String.valid?(id) ->
        {:error, :invalid_request}

      not canonical_capability_id?(id) ->
        {:error, :invalid_request}

      true ->
        :ok
    end
  end

  defp admit_parent_capability_id(_), do: {:error, :invalid_request}

  defp admit_required_datetime(dt) do
    if iso_datetime_primitives?(dt), do: :ok, else: {:error, :invalid_request}
  end

  defp admit_optional_datetime(nil), do: :ok

  defp admit_optional_datetime(dt) do
    if iso_datetime_primitives?(dt), do: :ok, else: {:error, :invalid_request}
  end

  # Phase A: raw struct fields only (no DateTime/calendar callbacks on value).
  # Phase B: Calendar.ISO.valid_* only after calendar is exactly Calendar.ISO.
  defp iso_datetime_primitives?(%DateTime{
         calendar: calendar,
         year: year,
         month: month,
         day: day,
         hour: hour,
         minute: minute,
         second: second,
         microsecond: microsecond,
         time_zone: time_zone,
         zone_abbr: zone_abbr,
         utc_offset: utc_offset,
         std_offset: std_offset
       }) do
    calendar == Calendar.ISO and
      int_in_bounds?(year) and year >= 1 and year <= 9999 and
      int_in_bounds?(month) and month >= 1 and month <= 12 and
      int_in_bounds?(day) and day >= 1 and day <= 31 and
      int_in_bounds?(hour) and hour >= 0 and hour <= 23 and
      int_in_bounds?(minute) and minute >= 0 and minute <= 60 and
      int_in_bounds?(second) and second >= 0 and second <= 60 and
      microsecond_shape?(microsecond) and
      offset_in_bounds?(utc_offset) and
      offset_in_bounds?(std_offset) and
      bounded_zone_text?(time_zone) and
      bounded_zone_text?(zone_abbr) and
      iso_date_valid?(year, month, day) and
      iso_time_valid?(hour, minute, second, microsecond)
  end

  defp iso_datetime_primitives?(_), do: false

  defp microsecond_shape?({us, precision})
       when is_integer(us) and is_integer(precision) and us >= 0 and us <= 999_999 and
              precision >= 0 and precision <= 6,
       do: true

  defp microsecond_shape?(_), do: false

  defp offset_in_bounds?(n) when is_integer(n) do
    int_in_bounds?(n) and abs(n) <= @max_abs_offset_seconds
  end

  defp offset_in_bounds?(_), do: false

  defp bounded_zone_text?(value)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_zone_bytes,
       do: String.valid?(value)

  defp bounded_zone_text?(_), do: false

  defp iso_date_valid?(year, month, day) do
    Calendar.ISO.valid_date?(year, month, day)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp iso_time_valid?(hour, minute, second, microsecond) do
    Calendar.ISO.valid_time?(hour, minute, second, microsecond)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp admit_delegation_depth(n) when is_integer(n) and n >= 0 and n < @signed_int_max_excl,
    do: :ok

  defp admit_delegation_depth(_), do: {:error, :invalid_request}

  defp admit_max_uses(nil), do: :ok

  defp admit_max_uses(n) when is_integer(n) and n >= 1 and n < @signed_int_max_excl, do: :ok

  defp admit_max_uses(_), do: {:error, :invalid_request}

  defp admit_delegatees(nil), do: :ok

  defp admit_delegatees(list) when is_list(list), do: admit_delegatees_walk(list, 0)

  defp admit_delegatees(_), do: {:error, :invalid_request}

  defp admit_delegatees_walk([], _n), do: :ok

  defp admit_delegatees_walk([elem | rest], n) when n < @max_delegatees do
    if bounded_nonempty_utf8?(elem, @max_scalar_bytes) do
      admit_delegatees_walk(rest, n + 1)
    else
      {:error, :invalid_request}
    end
  end

  defp admit_delegatees_walk(_over, _n), do: {:error, :invalid_request}

  defp admit_signature(sig) do
    if exact_issuer_signature?(sig), do: :ok, else: {:error, :invalid_request}
  end

  defp exact_issuer_signature?(sig)
       when is_binary(sig) and byte_size(sig) == @max_signature_bytes,
       do: true

  defp exact_issuer_signature?(_), do: false

  # Chain is excluded from signing_payload and expected identity — cardinality/
  # shape gate only. Do not walk keys or values (nested constraints/signatures
  # are legitimate; nested values never cross owner boundaries on prepare).
  defp admit_delegation_chain(chain) when is_list(chain), do: admit_chain_entries(chain, 0)

  defp admit_delegation_chain(_), do: {:error, :invalid_request}

  defp admit_chain_entries([], _n), do: :ok

  defp admit_chain_entries([entry | rest], n) when n < @max_chain_len do
    case admit_chain_entry(entry) do
      :ok -> admit_chain_entries(rest, n + 1)
      {:error, _} = err -> err
    end
  end

  defp admit_chain_entries(_over, _n), do: {:error, :invalid_request}

  defp admit_chain_entry(entry)
       when is_map(entry) and not is_struct(entry) and map_size(entry) <= @max_chain_entry_keys,
       do: :ok

  defp admit_chain_entry(_), do: {:error, :invalid_request}

  defp admit_signed_maps(constraints, metadata) do
    with {:ok, constraints} <- require_non_struct_map(constraints),
         {:ok, metadata} <- require_non_struct_map(metadata),
         {:ok, remaining} <- walk_node(constraints, 0, @max_nodes),
         {:ok, _remaining} <- walk_node(metadata, 0, remaining) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp require_non_struct_map(value) when is_map(value) and not is_struct(value), do: {:ok, value}
  defp require_non_struct_map(_), do: :error

  defp walk_node(map, depth, budget) when is_map(map) and not is_struct(map) do
    size = map_size(map)

    if depth <= @max_depth and size <= @max_map_keys and budget > 0 and
         unique_canonical_keys?(Map.keys(map), MapSet.new()) do
      walk_kvs(Map.to_list(map), depth + 1, budget - 1)
    else
      :error
    end
  end

  defp walk_node(list, depth, budget) when is_list(list) do
    if depth <= @max_depth and budget > 0 do
      walk_elems(list, depth + 1, budget - 1, 0)
    else
      :error
    end
  end

  defp walk_node(binary, _depth, budget) when is_binary(binary) do
    if byte_size(binary) <= @max_scalar_bytes and String.valid?(binary) and budget > 0 do
      {:ok, budget - 1}
    else
      :error
    end
  end

  defp walk_node(value, _depth, budget) when is_atom(value) do
    encoded = Atom.to_string(value)

    if budget > 0 and byte_size(encoded) <= @max_scalar_bytes and String.valid?(encoded) do
      {:ok, budget - 1}
    else
      :error
    end
  end

  defp walk_node(value, _depth, budget) when is_integer(value) do
    if int_in_bounds?(value) and budget > 0, do: {:ok, budget - 1}, else: :error
  end

  defp walk_node(value, _depth, budget) when is_number(value) do
    if finite?(value) and budget > 0, do: {:ok, budget - 1}, else: :error
  end

  defp walk_node(_other, _depth, _budget), do: :error

  defp walk_kvs([], _depth, budget), do: {:ok, budget}

  defp walk_kvs([{key, value} | rest], depth, budget) do
    with :ok <- key_ok?(key),
         {:ok, remaining} <- walk_node(value, depth, budget) do
      walk_kvs(rest, depth, remaining)
    end
  end

  defp walk_elems([], _depth, budget, _n), do: {:ok, budget}

  defp walk_elems([elem | rest], depth, budget, n) when n < @max_list_len do
    with {:ok, remaining} <- walk_node(elem, depth, budget) do
      walk_elems(rest, depth, remaining, n + 1)
    end
  end

  defp walk_elems(_over, _depth, _budget, _n), do: :error

  defp key_ok?(key) when is_atom(key), do: key_ok?(Atom.to_string(key))

  defp key_ok?(key) when is_binary(key) do
    if byte_size(key) <= @max_scalar_bytes and String.valid?(key), do: :ok, else: :error
  end

  defp key_ok?(_), do: :error

  defp unique_canonical_keys?([], _seen), do: true

  defp unique_canonical_keys?([key | rest], seen) do
    with {:ok, canonical} <- canonical_key(key),
         false <- MapSet.member?(seen, canonical) do
      unique_canonical_keys?(rest, MapSet.put(seen, canonical))
    else
      _ -> false
    end
  end

  defp canonical_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp canonical_key(key) when is_binary(key), do: {:ok, key}
  defp canonical_key(_), do: :error

  # ---------------------------------------------------------------------------
  # Shared predicates
  # ---------------------------------------------------------------------------

  defp canonical_capability_id?("cap_" <> suffix) when byte_size(suffix) == 32 do
    Regex.match?(~r/\A[0-9a-f]{32}\z/, suffix)
  end

  defp canonical_capability_id?(_), do: false

  defp bounded_nonempty_utf8?(value, max_bytes)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes,
       do: String.valid?(value)

  defp bounded_nonempty_utf8?(_value, _max_bytes), do: false

  defp positive_token?(n) when is_integer(n) and n >= 1 and n <= @max_token, do: true
  defp positive_token?(_), do: false

  defp fence_digest?(digest) when is_binary(digest) and byte_size(digest) == 64 do
    Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)
  end

  defp fence_digest?(_), do: false

  defp int_in_bounds?(n) when is_integer(n),
    do: n >= @signed_int_min and n < @signed_int_max_excl

  defp int_in_bounds?(_), do: false

  defp finite?(n), do: n * 0.0 == 0.0
end
