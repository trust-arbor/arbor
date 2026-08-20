defmodule Arbor.Security.IssuerRegistry do
  @moduledoc """
  Registry of capability-signing issuers and the maximum envelope each is
  allowed to sign within.

  This is Phase 2 of the scheduler-privesc redesign (Option 2-signed). An
  "issuer" here is an `Arbor.Security.Identity.Registry`-registered identity
  that has been administratively enrolled with a bound on what capabilities
  they can sign. The bound is itself a `Capability` (the `max_envelope_cap`)
  — anything outside that envelope, the issuer is not authorized to declare.

  ## Why this exists

  The `.caps.json` files that ride alongside scheduler pipeline DOTs declare
  what capabilities the pipeline needs. Those files are signed by their
  author. Without an issuer registry, anyone with a valid identity key could
  sign a `.caps.json` granting themselves anything — the cryptographic
  signature would validate but the trust model would be vacuous. The issuer
  registry says: "yes this key is valid (Identity.Registry), AND the holder
  of this key is authorized to sign capabilities within envelope X."

  ## Distinct from Identity.Registry

  - `Identity.Registry` knows who exists and what their public key is.
  - `IssuerRegistry` knows who is allowed to sign capability files, and
    within what bound.
  - An identity can exist without being an issuer (most agents are not
    issuers — they're recipients of caps, not signers of cap files).
  - An issuer can be revoked here without revoking the underlying identity
    (separation of concerns: maybe their cap-signing privileges are pulled
    but they're still allowed to run as a normal agent).

  ## Persistence

  Backed by Security-owned `Arbor.Security.AuthorityStore` under the name
  `:arbor_security_issuers`. There is deliberately no hot durable substitute:
  when the authority is absent or unavailable, reads and mutations fail closed.
  """

  use GenServer

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.CapabilityStore.Serializer
  alias Arbor.Security.Identity.Registry, as: IdentityRegistry

  @store :arbor_security_issuers

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Start the IssuerRegistry GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enroll an identity as a capability-signing issuer with a set of maximum
  envelopes.

  The identity must already be registered in `Identity.Registry`. Each
  envelope cap in the list defines a bound on what this issuer may sign:
  any signed capability must be a `Capability.envelope_subset?/2` of AT
  LEAST ONE envelope cap.

  Multiple envelope caps are how a single issuer is authorized for
  multiple non-overlapping resource patterns (e.g. read access to one
  subtree AND write access to another) without resorting to a coarser
  pattern that would dilute the bound.

  ## Options

    - `:reason` — human-readable reason for enrollment, recorded for audit

  Returns `:ok` only after the exact insert is acknowledged. Authority lookup
  and mutation failures return bounded store errors rather than being treated
  as an unenrolled issuer.
  """
  @spec register(String.t(), [Capability.t()], keyword()) ::
          :ok | {:error, atom() | tuple()}
  def register(issuer_id, envelope_caps, opts \\ [])

  def register(issuer_id, envelope_caps, opts)
      when is_binary(issuer_id) and is_list(envelope_caps) do
    GenServer.call(__MODULE__, {:register, issuer_id, envelope_caps, opts})
  end

  def register(issuer_id, %Capability{} = single, opts) when is_binary(issuer_id) do
    # Backward-compat shim for callers that still pass a single Capability.
    # Wraps in a one-element list. New callers should pass a list directly.
    register(issuer_id, [single], opts)
  end

  @doc """
  Look up an enrolled issuer's public key + envelope caps.

  Returns `{:ok, %{public_key: binary, max_envelope_caps: [Capability.t()]}}`
  on success. Returns `{:error, reason}` if the issuer is unknown, revoked,
  or the underlying identity is unavailable (suspended/revoked/missing).
  """
  @spec lookup(String.t()) ::
          {:ok, %{public_key: binary(), max_envelope_caps: [Capability.t()]}}
          | {:error, :not_found | :revoked | :identity_unavailable | atom()}
  def lookup(issuer_id) when is_binary(issuer_id) do
    GenServer.call(__MODULE__, {:lookup, issuer_id})
  end

  @doc """
  Verify that `cap` fits within at least one of `issuer_id`'s enrolled
  envelopes.

  Returns `:ok` if cap is a subset of any of the issuer's envelope caps
  and the issuer is active. Otherwise returns one of:

    - `{:error, :not_found}` — issuer not enrolled
    - `{:error, :revoked}` — issuer was revoked
    - `{:error, :identity_unavailable}` — underlying identity gone
    - `{:error, :exceeds_envelope}` — cap is outside every envelope
    - `{:error, :store_unavailable}` — authority could not be read
    - `{:error, :malformed_authority}` — the authoritative entry was invalid

  Used by `Arbor.Scheduler.CapsFile` (Phase 3) at load time and by anything
  else verifying that a signed capability declaration is within bounds.
  """
  @spec verify_envelope(String.t(), Capability.t()) ::
          :ok
          | {:error,
             :not_found
             | :revoked
             | :identity_unavailable
             | :exceeds_envelope
             | :store_unavailable
             | :malformed_authority}
  def verify_envelope(issuer_id, %Capability{} = cap) when is_binary(issuer_id) do
    case lookup(issuer_id) do
      {:ok, %{max_envelope_caps: envelopes}} ->
        if Enum.any?(envelopes, &Capability.envelope_subset?(cap, &1)) do
          :ok
        else
          {:error, :exceeds_envelope}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Revoke an issuer. Their signed `.caps.json` files will no longer be honored.

  The underlying identity is NOT affected — only their cap-signing privilege.
  Captures `reason` for audit.

  Returns `:ok` only after the exact replacement is acknowledged. It may also
  return `:not_found`, `:conflict`, `:outcome_unknown`, `:store_unavailable`,
  or `:malformed_authority`.
  """
  @spec revoke(String.t(), String.t() | nil) ::
          :ok
          | {:error,
             :not_found
             | :conflict
             | :outcome_unknown
             | :store_unavailable
             | :malformed_authority}
  def revoke(issuer_id, reason \\ nil) when is_binary(issuer_id) do
    GenServer.call(__MODULE__, {:revoke, issuer_id, reason})
  end

  @doc """
  Replace the envelope list for an active issuer.

  Use this when an operator needs to expand or narrow an existing
  issuer's authority WITHOUT going through revoke + re-register, which
  would invalidate every `.caps.json` previously signed under the
  original envelope set even if those files would still fit within the
  new envelopes.

  Semantics:
    - Replaces the FULL envelope list (not appends). Callers pass the
      complete new set; what isn't in the list is dropped.
    - Issuer must be active. Revoked issuers can't be updated — caller
      must explicitly re-enroll if they want to bring a revoked issuer
      back, which is a deliberate friction point (key compromise
      shouldn't be quietly undone).
    - Validates the new list is non-empty and contains only `Capability`
      structs (same as `register/3`).
    - Commits through the Security-owned authority store before returning.

  ## Options

    - `:reason` — human-readable reason for the update, recorded for audit.

  Returns `:ok` only after the exact replacement is acknowledged. Validation,
  lookup, conflict, and authority-availability failures are returned as bounded
  errors.
  """
  @spec update_envelopes(String.t(), [Capability.t()], keyword()) ::
          :ok | {:error, atom() | tuple()}
  def update_envelopes(issuer_id, envelope_caps, opts \\ [])

  def update_envelopes(issuer_id, envelope_caps, opts)
      when is_binary(issuer_id) and is_list(envelope_caps) do
    GenServer.call(__MODULE__, {:update_envelopes, issuer_id, envelope_caps, opts})
  end

  @doc """
  List all enrolled issuers with their status. Used by audit tooling.
  """
  @spec list() :: [
          %{
            issuer_id: String.t(),
            max_envelope_caps: [Capability.t()],
            status: :active | :revoked,
            enrolled_at: DateTime.t(),
            status_changed_at: DateTime.t() | nil,
            status_reason: String.t() | nil
          }
        ]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  # ===========================================================================
  # GenServer callbacks
  # ===========================================================================

  @impl true
  def init(_opts) do
    if Process.whereis(@store) do
      case take_and_validate_authority() do
        :ok -> {:ok, %{authority_mode: :durable}}
        {:error, reason} -> {:stop, {:issuer_authority, reason}}
      end
    else
      {:ok, %{authority_mode: :unavailable}}
    end
  end

  @impl true
  def handle_call({:register, issuer_id, envelope_caps, opts}, _from, state) do
    with :ok <- require_authority(state),
         :ok <- validate_envelopes(envelope_caps),
         {:error, :not_found} <- authoritative_entry(issuer_id),
         :ok <- require_identity(issuer_id) do
      entry = %{
        max_envelope_caps: envelope_caps,
        status: :active,
        enrolled_at: DateTime.utc_now(),
        status_changed_at: nil,
        status_reason: Keyword.get(opts, :reason)
      }

      case acknowledged_insert(issuer_id, entry) do
        :ok -> {:reply, :ok, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:ok, _record, _entry} -> {:reply, {:error, :already_enrolled}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:lookup, issuer_id}, _from, state) do
    result =
      case require_authority(state) do
        :ok -> lookup_authoritative_issuer(issuer_id)
        {:error, reason} -> {:error, reason}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:revoke, issuer_id, reason}, _from, state) do
    with :ok <- require_authority(state),
         {:ok, current, entry} <- authoritative_entry(issuer_id) do
      updated = %{
        entry
        | status: :revoked,
          status_changed_at: DateTime.utc_now(),
          status_reason: reason
      }

      case acknowledged_replace(issuer_id, current, updated) do
        :ok -> {:reply, :ok, state}
        {:error, error} -> {:reply, {:error, error}, state}
      end
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    entries =
      with :ok <- require_authority(state),
           {:ok, records} <- fresh_authoritative_entries(),
           {:ok, entries} <- validate_authority_entries(records) do
        Enum.map(entries, fn {issuer_id, _record, entry} ->
          Map.put(entry, :issuer_id, issuer_id)
        end)
      else
        _ -> []
      end

    {:reply, entries, state}
  end

  @impl true
  def handle_call({:update_envelopes, issuer_id, envelope_caps, opts}, _from, state) do
    with :ok <- require_authority(state),
         :ok <- validate_envelopes(envelope_caps),
         {:ok, current, entry} <- authoritative_entry(issuer_id),
         :ok <- require_active_issuer(entry) do
      updated = %{
        entry
        | max_envelope_caps: envelope_caps,
          status_reason: Keyword.get(opts, :reason, entry.status_reason)
      }

      case acknowledged_replace(issuer_id, current, updated) do
        :ok -> {:reply, :ok, state}
        {:error, error} -> {:reply, {:error, error}, state}
      end
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  # ===========================================================================
  # Internal helpers
  # ===========================================================================

  defp lookup_authoritative_issuer(issuer_id) do
    case authoritative_entry(issuer_id) do
      {:error, reason} ->
        {:error, reason}

      {:ok, _record, %{status: :revoked}} ->
        {:error, :revoked}

      {:ok, _record, %{status: :active, max_envelope_caps: envelopes}} ->
        case IdentityRegistry.lookup(issuer_id) do
          {:ok, public_key} ->
            {:ok, %{public_key: public_key, max_envelope_caps: envelopes}}

          {:error, _} ->
            {:error, :identity_unavailable}
        end

      {:ok, _record, _malformed} ->
        {:error, :malformed_authority}
    end
  end

  defp require_authority(%{authority_mode: :durable}) do
    if Process.whereis(@store), do: :ok, else: {:error, :store_unavailable}
  end

  defp require_authority(_state), do: {:error, :store_unavailable}

  defp require_identity(issuer_id) do
    case IdentityRegistry.lookup(issuer_id) do
      {:ok, _public_key} -> :ok
      _ -> {:error, :identity_not_found}
    end
  end

  defp require_active_issuer(%{status: :active}), do: :ok
  defp require_active_issuer(%{status: :revoked}), do: {:error, :revoked}
  defp require_active_issuer(_entry), do: {:error, :malformed_authority}

  defp validate_envelopes([]), do: {:error, :empty_envelopes}

  defp validate_envelopes(envelopes) when is_list(envelopes) do
    if Enum.all?(envelopes, &valid_capability?/1),
      do: :ok,
      else: {:error, :invalid_envelope}
  end

  defp validate_envelopes(_envelopes), do: {:error, :invalid_envelope}

  defp valid_capability?(%Capability{} = capability) do
    case Capability.new(capability_validation_opts(capability)) do
      {:ok, _validated} -> valid_capability_fields?(capability)
      {:error, _reason} -> false
    end
  rescue
    _ -> false
  end

  defp valid_capability?(_capability), do: false

  defp valid_capability_fields?(capability) do
    is_binary(capability.id) and capability.id != "" and
      match?(%DateTime{}, capability.granted_at) and
      (is_nil(capability.expires_at) or match?(%DateTime{}, capability.expires_at)) and
      (is_nil(capability.not_before) or match?(%DateTime{}, capability.not_before)) and
      is_map(capability.constraints) and is_list(capability.delegation_chain) and
      is_map(capability.metadata) and
      (is_nil(capability.issuer_signature) or is_binary(capability.issuer_signature)) and
      (is_nil(capability.signed_at) or match?(%DateTime{}, capability.signed_at))
  end

  defp capability_validation_opts(capability) do
    [
      id: capability.id,
      resource_uri: capability.resource_uri,
      principal_id: capability.principal_id,
      granted_at: capability.granted_at,
      expires_at: capability.expires_at,
      not_before: capability.not_before,
      parent_capability_id: capability.parent_capability_id,
      delegation_depth: capability.delegation_depth,
      max_uses: capability.max_uses,
      allowed_delegatees: capability.allowed_delegatees,
      session_id: capability.session_id,
      task_id: capability.task_id,
      principal_scope: capability.principal_scope,
      constraints: capability.constraints,
      issuer_id: capability.issuer_id,
      issuer_signature: capability.issuer_signature,
      delegation_chain: capability.delegation_chain,
      metadata: capability.metadata
    ]
  end

  defp take_and_validate_authority do
    with {:ok, entries} <-
           safe_authority_call(fn ->
             AuthorityStore.take_hydrated_entries(name: @store)
           end),
         {:ok, _validated} <- validate_authority_entries(entries) do
      :ok
    else
      {:error, reason} -> {:error, issuer_hydration_error(reason)}
      _ -> {:error, :malformed_inventory}
    end
  end

  defp fresh_authoritative_entries do
    case safe_authority_call(fn -> AuthorityStore.authoritative_entries(name: @store) end) do
      {:ok, entries} when is_list(entries) -> {:ok, entries}
      {:error, _reason} -> {:error, :store_unavailable}
      _ -> {:error, :malformed_authority}
    end
  end

  defp validate_authority_entries(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn
      {key, %Record{} = record}, {:ok, acc} when is_binary(key) ->
        case deserialize_issuer_record(key, record) do
          {:ok, entry} -> {:cont, {:ok, [{key, record, entry} | acc]}}
          {:error, _reason} -> {:halt, {:error, :malformed_inventory}}
        end

      _malformed, _acc ->
        {:halt, {:error, :malformed_inventory}}
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_authority_entries(_entries), do: {:error, :malformed_inventory}

  defp authoritative_entry(issuer_id) do
    case safe_authority_call(fn -> AuthorityStore.authoritative_get(issuer_id, name: @store) end) do
      {:ok, %Record{} = record} ->
        case deserialize_issuer_record(issuer_id, record) do
          {:ok, entry} -> {:ok, record, entry}
          {:error, _reason} -> {:error, :malformed_authority}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :store_unavailable}

      _invalid ->
        {:error, :malformed_authority}
    end
  end

  defp acknowledged_insert(issuer_id, entry) do
    replacement = Record.new(issuer_id, serialize_entry(issuer_id, entry))

    case safe_authority_call(fn ->
           AuthorityStore.acknowledged_compare_and_swap(
             issuer_id,
             :not_found,
             replacement,
             name: @store
           )
         end) do
      {:ok, %Record{}} -> :ok
      {:error, reason} -> {:error, issuer_store_error(reason)}
      _ -> {:error, :outcome_unknown}
    end
  end

  defp acknowledged_replace(issuer_id, current, entry) do
    replacement = Record.new(issuer_id, serialize_entry(issuer_id, entry))

    case safe_authority_call(fn ->
           AuthorityStore.acknowledged_compare_and_swap(
             issuer_id,
             {:value, current},
             replacement,
             name: @store
           )
         end) do
      {:ok, %Record{}} -> :ok
      {:error, reason} -> {:error, issuer_store_error(reason)}
      _ -> {:error, :outcome_unknown}
    end
  end

  defp issuer_store_error(:conflict), do: :conflict
  defp issuer_store_error(:outcome_unknown), do: :outcome_unknown
  defp issuer_store_error(:key_mismatch), do: :malformed_authority
  defp issuer_store_error(_reason), do: :store_unavailable

  defp issuer_hydration_error(reason)
       when reason in [
              :hydration_limit_exceeded,
              :inventory_limit_exceeded,
              :bounded_inventory_unsupported
            ],
       do: :inventory_limit_exceeded

  defp issuer_hydration_error(reason)
       when reason in [:backend_unavailable, :outcome_unknown, :not_hydrated],
       do: :inventory_unavailable

  defp issuer_hydration_error(_reason), do: :malformed_inventory

  defp safe_authority_call(fun) do
    fun.()
  rescue
    _ -> {:error, :backend_unavailable}
  catch
    _, _ -> {:error, :backend_unavailable}
  end

  defp deserialize_issuer_record(key, %Record{key: key, data: data}) when is_map(data) do
    case deserialize_entry(data) do
      {:ok, ^key, entry} -> {:ok, entry}
      _ -> {:error, :malformed_authority}
    end
  end

  defp deserialize_issuer_record(_key, _record), do: {:error, :malformed_authority}

  defp serialize_entry(issuer_id, entry) do
    %{
      "issuer_id" => issuer_id,
      "max_envelope_caps" => Enum.map(entry.max_envelope_caps, &Serializer.serialize/1),
      "status" => Atom.to_string(entry.status),
      "enrolled_at" => DateTime.to_iso8601(entry.enrolled_at),
      "status_changed_at" =>
        if(entry.status_changed_at, do: DateTime.to_iso8601(entry.status_changed_at)),
      "status_reason" => entry.status_reason
    }
  end

  defp deserialize_entry(%{"issuer_id" => issuer_id} = data) do
    with true <- is_binary(issuer_id) and issuer_id != "",
         true <- complete_issuer_payload?(data),
         {:ok, envelopes} <- deserialize_envelopes(data["max_envelope_caps"]),
         {:ok, status} <- deserialize_status(data["status"]),
         {:ok, enrolled_at} <- deserialize_datetime(data["enrolled_at"]),
         {:ok, status_changed_at} <- deserialize_optional_datetime(data["status_changed_at"]),
         true <- is_nil(data["status_reason"]) or is_binary(data["status_reason"]) do
      entry = %{
        max_envelope_caps: envelopes,
        status: status,
        enrolled_at: enrolled_at,
        status_changed_at: status_changed_at,
        status_reason: data["status_reason"]
      }

      {:ok, issuer_id, entry}
    else
      _ -> {:error, :malformed_authority}
    end
  end

  defp deserialize_entry(_), do: {:error, :invalid_entry_shape}

  defp complete_issuer_payload?(data) do
    Enum.all?(
      [
        "issuer_id",
        "max_envelope_caps",
        "status",
        "enrolled_at",
        "status_changed_at",
        "status_reason"
      ],
      &Map.has_key?(data, &1)
    )
  end

  defp deserialize_envelopes([_first | _rest] = list) do
    Enum.reduce_while(list, {:ok, []}, fn envelope_map, {:ok, acc} ->
      case deserialize_envelope(envelope_map) do
        {:ok, cap} -> {:cont, {:ok, [cap | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, caps} -> {:ok, Enum.reverse(caps)}
      err -> err
    end
  end

  defp deserialize_envelopes(_), do: {:error, :invalid_envelope_list}

  defp deserialize_envelope(map) when is_map(map) do
    with :ok <- validate_serialized_envelope(map),
         {:ok, %Capability{} = capability} <- Serializer.deserialize(map),
         true <- valid_capability?(capability) do
      {:ok, capability}
    else
      _ -> {:error, :invalid_envelope}
    end
  end

  defp deserialize_envelope(_map), do: {:error, :invalid_envelope}

  defp validate_serialized_envelope(map) do
    with true <- complete_envelope_payload?(map),
         true <- is_binary(map["id"]) and map["id"] != "",
         true <- is_binary(map["resource_uri"]),
         true <- is_binary(map["principal_id"]),
         {:ok, _granted_at} <- deserialize_datetime(map["granted_at"]),
         {:ok, _expires_at} <- deserialize_optional_datetime(map["expires_at"]),
         {:ok, _not_before} <- deserialize_optional_datetime(map["not_before"]),
         {:ok, _signed_at} <- deserialize_optional_datetime(map["signed_at"]),
         true <- is_integer(map["delegation_depth"]),
         true <- is_map(map["constraints"]),
         true <- is_list(map["delegation_chain"]),
         true <- is_map(map["metadata"]),
         :ok <- validate_optional_hex(map["issuer_signature"]) do
      :ok
    else
      _ -> {:error, :invalid_envelope}
    end
  end

  defp complete_envelope_payload?(map) do
    Enum.all?(
      [
        "id",
        "resource_uri",
        "principal_id",
        "granted_at",
        "expires_at",
        "not_before",
        "parent_capability_id",
        "delegation_depth",
        "max_uses",
        "allowed_delegatees",
        "session_id",
        "task_id",
        "principal_scope",
        "signed_at",
        "constraints",
        "issuer_id",
        "issuer_signature",
        "delegation_chain",
        "metadata"
      ],
      &Map.has_key?(map, &1)
    )
  end

  defp validate_optional_hex(nil), do: :ok

  defp validate_optional_hex(hex) when is_binary(hex) and hex != "" do
    case Base.decode16(hex, case: :mixed) do
      {:ok, _binary} -> :ok
      :error -> {:error, :invalid_envelope}
    end
  end

  defp validate_optional_hex(_hex), do: {:error, :invalid_envelope}

  defp deserialize_status("active"), do: {:ok, :active}
  defp deserialize_status("revoked"), do: {:ok, :revoked}
  defp deserialize_status(_status), do: {:error, :malformed_authority}

  defp deserialize_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :malformed_authority}
    end
  end

  defp deserialize_datetime(_iso), do: {:error, :malformed_authority}

  defp deserialize_optional_datetime(nil), do: {:ok, nil}
  defp deserialize_optional_datetime(iso), do: deserialize_datetime(iso)
end
