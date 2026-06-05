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

  Backed by `Arbor.Persistence.BufferedStore` under the name
  `:arbor_security_issuers`. Same pattern as `Identity.Registry`.
  """

  use GenServer

  require Logger

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.Identity.Registry, as: IdentityRegistry

  # Runtime bridge — arbor_persistence is a Level 1 peer, no compile-time dep
  @buffered_store Arbor.Persistence.BufferedStore
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

  Returns `:ok | {:error, :identity_not_found | :already_enrolled |
  :empty_envelopes | :invalid_envelope}`.
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

  Used by `Arbor.Scheduler.CapsFile` (Phase 3) at load time and by anything
  else verifying that a signed capability declaration is within bounds.
  """
  @spec verify_envelope(String.t(), Capability.t()) ::
          :ok | {:error, :not_found | :revoked | :identity_unavailable | :exceeds_envelope}
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

  Returns `:ok | {:error, :not_found}`.
  """
  @spec revoke(String.t(), String.t() | nil) :: :ok | {:error, :not_found}
  def revoke(issuer_id, reason \\ nil) when is_binary(issuer_id) do
    GenServer.call(__MODULE__, {:revoke, issuer_id, reason})
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
    state = %{by_issuer_id: %{}}
    {:ok, restore_from_store(state)}
  end

  @impl true
  def handle_call({:register, issuer_id, envelope_caps, opts}, _from, state) do
    cond do
      Map.has_key?(state.by_issuer_id, issuer_id) ->
        {:reply, {:error, :already_enrolled}, state}

      envelope_caps == [] ->
        {:reply, {:error, :empty_envelopes}, state}

      not Enum.all?(envelope_caps, &match?(%Capability{}, &1)) ->
        {:reply, {:error, :invalid_envelope}, state}

      not identity_exists?(issuer_id) ->
        {:reply, {:error, :identity_not_found}, state}

      true ->
        entry = %{
          max_envelope_caps: envelope_caps,
          status: :active,
          enrolled_at: DateTime.utc_now(),
          status_changed_at: nil,
          status_reason: Keyword.get(opts, :reason)
        }

        new_state = put_in(state, [:by_issuer_id, issuer_id], entry)
        persist_to_store(issuer_id, entry)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:lookup, issuer_id}, _from, state) do
    result =
      case Map.get(state.by_issuer_id, issuer_id) do
        nil ->
          {:error, :not_found}

        %{status: :revoked} ->
          {:error, :revoked}

        %{status: :active, max_envelope_caps: envelopes} ->
          case IdentityRegistry.lookup(issuer_id) do
            {:ok, public_key} ->
              {:ok, %{public_key: public_key, max_envelope_caps: envelopes}}

            {:error, _} ->
              {:error, :identity_unavailable}
          end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:revoke, issuer_id, reason}, _from, state) do
    case Map.get(state.by_issuer_id, issuer_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        updated = %{
          entry
          | status: :revoked,
            status_changed_at: DateTime.utc_now(),
            status_reason: reason
        }

        new_state = put_in(state, [:by_issuer_id, issuer_id], updated)
        persist_to_store(issuer_id, updated)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    entries =
      Enum.map(state.by_issuer_id, fn {issuer_id, entry} ->
        Map.put(entry, :issuer_id, issuer_id)
      end)

    {:reply, entries, state}
  end

  # ===========================================================================
  # Internal helpers
  # ===========================================================================

  defp identity_exists?(issuer_id) do
    case IdentityRegistry.lookup(issuer_id) do
      {:ok, _public_key} -> true
      _ -> false
    end
  end

  # ===========================================================================
  # Persistence via BufferedStore
  # ===========================================================================

  defp persist_to_store(issuer_id, entry) do
    if Process.whereis(@store) do
      data = serialize_entry(issuer_id, entry)
      record = Record.new(issuer_id, data)
      apply(@buffered_store, :put, [issuer_id, record, [name: @store]])
    end

    :ok
  catch
    _, reason ->
      Logger.warning("Failed to persist issuer #{issuer_id}: #{inspect(reason)}")
      :ok
  end

  defp restore_from_store(state) do
    if Process.whereis(@store) do
      case apply(@buffered_store, :list, [[name: @store]]) do
        {:ok, keys} -> Enum.reduce(keys, state, &restore_key_from_store/2)
        {:error, _reason} -> state
      end
    else
      state
    end
  catch
    _, reason ->
      Logger.warning("Failed to restore issuer registry: #{inspect(reason)}")
      state
  end

  defp restore_key_from_store(key, acc) do
    case apply(@buffered_store, :get, [key, [name: @store]]) do
      {:ok, %Record{data: data}} ->
        case deserialize_entry(data) do
          {:ok, issuer_id, entry} -> put_in(acc, [:by_issuer_id, issuer_id], entry)
          {:error, _} -> acc
        end

      {:error, _} ->
        acc
    end
  end

  defp serialize_entry(issuer_id, entry) do
    %{
      "issuer_id" => issuer_id,
      "max_envelope_caps" => Enum.map(entry.max_envelope_caps, &Map.from_struct/1),
      "status" => Atom.to_string(entry.status),
      "enrolled_at" => DateTime.to_iso8601(entry.enrolled_at),
      "status_changed_at" =>
        if(entry.status_changed_at, do: DateTime.to_iso8601(entry.status_changed_at)),
      "status_reason" => entry.status_reason
    }
  end

  defp deserialize_entry(%{"issuer_id" => issuer_id} = data) do
    with {:ok, envelopes} <- deserialize_envelopes(data["max_envelope_caps"]),
         {:ok, enrolled_at, _} <- DateTime.from_iso8601(data["enrolled_at"]) do
      status_changed_at =
        case data["status_changed_at"] do
          nil ->
            nil

          iso ->
            case DateTime.from_iso8601(iso) do
              {:ok, dt, _} -> dt
              _ -> nil
            end
        end

      entry = %{
        max_envelope_caps: envelopes,
        status: String.to_existing_atom(data["status"]),
        enrolled_at: enrolled_at,
        status_changed_at: status_changed_at,
        status_reason: data["status_reason"]
      }

      {:ok, issuer_id, entry}
    end
  end

  defp deserialize_entry(_), do: {:error, :invalid_entry_shape}

  defp deserialize_envelopes(list) when is_list(list) do
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
    # Map.from_struct lost the struct identity; rebuild Capability via
    # struct! with the persisted fields. issuer_signature etc. are
    # preserved as-is.
    attrs =
      map
      |> Enum.flat_map(fn
        {:__struct__, _} -> []
        {k, v} when is_atom(k) -> [{k, v}]
        {k, v} when is_binary(k) -> [{String.to_existing_atom(k), v}]
      end)

    cap = struct!(Capability, attrs)
    {:ok, cap}
  rescue
    e -> {:error, {:deserialize_envelope_failed, Exception.message(e)}}
  end
end
