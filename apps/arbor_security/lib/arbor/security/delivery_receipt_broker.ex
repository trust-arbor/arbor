defmodule Arbor.Security.DeliveryReceiptBroker do
  @moduledoc false

  # Private one-use delivery-receipt broker. Callers outside arbor_security must
  # use Arbor.Security facades. Intentionally ephemeral: restart loses every
  # outstanding receipt. No persistence, signals, or cluster sync.

  use GenServer

  alias Arbor.Contracts.Security.DeliveryReceipt
  alias Arbor.Security.Config
  alias Arbor.Security.Contracts.PrivateMemoryAdmission
  alias Arbor.Security.PrivateMemory
  alias Arbor.Security.PrivateState
  alias Arbor.Security.ReceiptIssuanceProof
  alias Arbor.Security.SupervisedOwner

  @token_bytes 32
  @default_ttl_ms 30_000
  @default_max_entries 4_096
  @default_cleanup_interval_ms 5_000
  @max_token_attempts 8
  @owner_table :arbor_security_delivery_receipt_broker_directory
  @private_state_anchor {__MODULE__, :private_state}
  @private_state_schema :delivery_receipt_broker_v1

  @type issue_error ::
          :broker_full
          | :receipt_issue_failed
          | :broker_unavailable
          | :receipt_issuance_unauthorized
  @type consume_error :: :invalid_receipt | :broker_unavailable

  # ---------------------------------------------------------------------------
  # Client API (internal — not a public library facade)
  # ---------------------------------------------------------------------------

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec issue(String.t(), String.t(), atom() | nil) ::
          {:ok, DeliveryReceipt.t()} | {:error, issue_error()}
  def issue(principal_id, resource_uri, action)
      when is_binary(principal_id) and is_binary(resource_uri) do
    issue(__MODULE__, principal_id, resource_uri, action)
  end

  @doc false
  @spec issue(GenServer.server(), String.t(), String.t(), atom() | nil) ::
          {:ok, DeliveryReceipt.t()} | {:error, issue_error()}
  def issue(server, principal_id, resource_uri, action)
      when is_binary(principal_id) and is_binary(resource_uri) do
    safe_call(server, {:issue, principal_id, resource_uri, action})
  end

  @doc false
  @spec issue_authorized(function()) ::
          {:ok, DeliveryReceipt.t()} | {:error, issue_error()}
  def issue_authorized(proof) when is_function(proof, 1),
    do: safe_call(__MODULE__, {:issue_authorized, proof})

  def issue_authorized(_proof), do: {:error, :receipt_issuance_unauthorized}

  @doc false
  @spec consume(binary(), String.t(), atom() | nil) ::
          {:ok, String.t()} | {:error, consume_error()}
  def consume(token, resource_uri, action)
      when is_binary(token) and is_binary(resource_uri) do
    consume(__MODULE__, token, resource_uri, action)
  end

  @doc false
  @spec consume(GenServer.server(), binary(), String.t(), atom() | nil) ::
          {:ok, String.t()} | {:error, consume_error()}
  def consume(server, token, resource_uri, action)
      when is_binary(token) and is_binary(resource_uri) do
    safe_call(server, {:consume, token, resource_uri, action})
  end

  @doc false
  @spec discard(binary()) :: :ok | {:error, :broker_unavailable}
  def discard(token) when is_binary(token) do
    discard(__MODULE__, token)
  end

  @doc false
  @spec discard(GenServer.server(), binary()) :: :ok | {:error, :broker_unavailable}
  def discard(server, token) when is_binary(token) do
    case safe_call(server, {:discard, token}) do
      :ok -> :ok
      {:error, :broker_unavailable} = err -> err
      _ -> :ok
    end
  end

  @doc false
  @spec stats() :: map() | {:error, :broker_unavailable}
  def stats, do: stats(__MODULE__)

  @doc false
  @spec stats(GenServer.server()) :: map() | {:error, :broker_unavailable}
  def stats(server) do
    safe_call(server, :stats)
  end

  def issue_conversation(principal, resource, canonical_owner, expected_engagement_id \\ nil) do
    safe_call(
      __MODULE__,
      {:issue_conversation, principal, resource, canonical_owner, expected_engagement_id}
    )
  end

  @doc false
  def issue_conversation_authorized(proof) when is_function(proof, 1),
    do: safe_call(__MODULE__, {:issue_conversation_authorized, proof})

  def issue_conversation_authorized(_proof),
    do: {:error, :receipt_issuance_unauthorized}

  def issue_conversation_operation(principal, resource, canonical_owner, expected, digest)
      when is_binary(digest) and byte_size(digest) == 32 do
    safe_call(
      __MODULE__,
      {:issue_conversation_operation, principal, resource, canonical_owner, expected, digest}
    )
  end

  @doc false
  def issue_conversation_operation_authorized(proof) when is_function(proof, 1),
    do: safe_call(__MODULE__, {:issue_conversation_operation_authorized, proof})

  def issue_conversation_operation_authorized(_proof),
    do: {:error, :receipt_issuance_unauthorized}

  def consume_conversation_operation(token, resource, digest)
      when is_binary(token) and is_binary(resource) and is_binary(digest) and
             byte_size(digest) == 32 do
    safe_call(__MODULE__, {:consume_conversation_operation, token, resource, digest})
  end

  def conversation_owner(token, principal, resource),
    do: safe_call(__MODULE__, {:conversation_owner, token, principal, resource})

  def memory_binding(token), do: safe_call(__MODULE__, {:memory_binding, token})

  def memory_exchange(token, agent_id, sender_id, context),
    do: safe_call(__MODULE__, {:memory_exchange, token, agent_id, sender_id, context})

  def memory_activate(token, engagement_id),
    do: safe_call(__MODULE__, {:memory_activate, token, engagement_id})

  def memory_check_engagement(token, engagement_id),
    do: safe_call(__MODULE__, {:memory_check_engagement, token, engagement_id})

  def memory_scope(token), do: safe_call(__MODULE__, {:memory_scope, token})
  def memory_close(token), do: safe_call(__MODULE__, {:memory_close, token})

  def memory_attestation_scope(token, owner),
    do: safe_call(__MODULE__, {:memory_attestation_scope, token, owner})

  if Mix.env() == :test do
    @doc false
    def set_clock_fixture(clock) when is_function(clock, 0),
      do: safe_call(__MODULE__, {:set_clock_fixture, clock})

    def set_clock_fixture(_clock), do: {:error, :invalid_test_fixture}
  end

  defp safe_call(server, request) do
    target = safe_call_target(server)

    case target do
      pid when is_pid(pid) -> Arbor.Common.authenticated_call(pid, request)
      _ -> {:error, :broker_unavailable}
    end
  catch
    :exit, _ -> {:error, :broker_unavailable}
  end

  defp safe_call_target(__MODULE__), do: default_owner_pid()

  if Mix.env() == :test do
    defp safe_call_target(server) when is_pid(server), do: server
    defp safe_call_target(server) when is_atom(server), do: Process.whereis(server)
  end

  defp safe_call_target(_server), do: nil

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:sensitive, true)
    name = Keyword.get(opts, :name, __MODULE__)

    with :ok <- maybe_claim_directory(name) do
      init_state(opts, name)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp init_state(opts, name) do
    ttl_ms = positive_int(Keyword.get(opts, :ttl_ms), @default_ttl_ms)
    max_entries = positive_int(Keyword.get(opts, :max_entries), @default_max_entries)

    cleanup_interval_ms =
      positive_int(Keyword.get(opts, :cleanup_interval_ms), @default_cleanup_interval_ms)

    clock = Keyword.get(opts, :clock, &System.monotonic_time/1)
    clock_fun = normalize_clock(clock)

    schedule_cleanup(cleanup_interval_ms)

    state = %{
      authorization_required: name == __MODULE__,
      authenticated_calls: Arbor.Common.new_authenticated_call_custody(),
      entries: %{},
      memory_admissions: %{},
      memory_monitors: %{},
      memory_ttl_ms: Config.private_memory_admission_ttl_ms(),
      ttl_ms: ttl_ms,
      max_entries: max_entries,
      cleanup_interval_ms: cleanup_interval_ms,
      clock: clock_fun,
      stats: %{
        issued: 0,
        consumed: 0,
        discarded: 0,
        expired: 0,
        rejected_full: 0,
        rejected_issue: 0,
        rejected_consume: 0
      }
    }

    {:ok, PrivateState.new(@private_state_anchor, @private_state_schema, state)}
  end

  @impl true
  def handle_call(_request, _from, private_state),
    do: {:reply, {:error, :receipt_issuance_unauthorized}, private_state}

  defp handle_authenticated_request({:issue, principal_id, resource_uri, action}, _from, state) do
    if state.authorization_required do
      {:reply, {:error, :receipt_issuance_unauthorized}, bump(state, :rejected_issue)}
    else
      issue_reply(state, principal_id, resource_uri, action)
    end
  end

  defp handle_authenticated_request({:issue_authorized, proof}, {caller, _tag}, state) do
    with {:ok,
          %{principal_id: principal_id, resource_uri: resource_uri, action: action} = payload} <-
           ReceiptIssuanceProof.admit(proof, caller, :delivery),
         true <- map_size(payload) == 3,
         true <- is_binary(principal_id) and is_binary(resource_uri) do
      issue_reply(state, principal_id, resource_uri, action)
    else
      _ -> {:reply, {:error, :receipt_issuance_unauthorized}, bump(state, :rejected_issue)}
    end
  end

  defp handle_authenticated_request(
         {:issue_conversation, principal, resource, canonical_owner, expected_engagement_id},
         _from,
         state
       ) do
    if state.authorization_required do
      {:reply, {:error, :receipt_issuance_unauthorized}, bump(state, :rejected_issue)}
    else
      issue_conversation_reply(
        state,
        principal,
        resource,
        canonical_owner,
        expected_engagement_id
      )
    end
  end

  defp handle_authenticated_request(
         {:issue_conversation_authorized, proof},
         {caller, _tag},
         state
       ) do
    with {:ok,
          %{
            principal_id: principal,
            resource_uri: resource,
            canonical_owner_id: canonical_owner,
            expected_engagement_id: expected_engagement_id
          } = payload} <- ReceiptIssuanceProof.admit(proof, caller, :conversation_delivery),
         true <- map_size(payload) == 4,
         true <-
           is_binary(principal) and is_binary(resource) and is_binary(canonical_owner) and
             (is_nil(expected_engagement_id) or is_binary(expected_engagement_id)) do
      issue_conversation_reply(
        state,
        principal,
        resource,
        canonical_owner,
        expected_engagement_id
      )
    else
      _ -> {:reply, {:error, :receipt_issuance_unauthorized}, bump(state, :rejected_issue)}
    end
  end

  defp handle_authenticated_request(
         {:issue_conversation_operation, principal, resource, owner, expected, digest},
         _from,
         state
       ) do
    if state.authorization_required do
      {:reply, {:error, :receipt_issuance_unauthorized}, bump(state, :rejected_issue)}
    else
      issue_conversation_operation_reply(state, principal, resource, owner, expected, digest)
    end
  end

  defp handle_authenticated_request(
         {:issue_conversation_operation_authorized, proof},
         {caller, _tag},
         state
       ) do
    with {:ok,
          %{
            principal_id: principal,
            resource_uri: resource,
            canonical_owner_id: owner,
            expected_engagement_id: expected,
            operation_digest: digest
          } = payload} <-
           ReceiptIssuanceProof.admit(proof, caller, :conversation_operation_delivery),
         true <- map_size(payload) == 5,
         true <-
           is_binary(principal) and is_binary(resource) and is_binary(owner) and
             (is_nil(expected) or is_binary(expected)) and is_binary(digest) and
             byte_size(digest) == 32 do
      issue_conversation_operation_reply(state, principal, resource, owner, expected, digest)
    else
      _ -> {:reply, {:error, :receipt_issuance_unauthorized}, bump(state, :rejected_issue)}
    end
  end

  defp handle_authenticated_request(
         {:conversation_owner, token, principal, resource},
         _from,
         state
       ) do
    now = state.clock.()

    reply =
      case Map.get(state.entries, token) do
        %{
          principal_id: ^principal,
          resource_uri: ^resource,
          action: :chat,
          canonical_owner_id: owner,
          expires_at_ms: expiry
        }
        when expiry > now ->
          {:ok, owner}

        _ ->
          {:error, :invalid_receipt}
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_request({:consume, token, resource_uri, action}, _from, state) do
    now = state.clock.()
    {entry, entries} = Map.pop(state.entries, token)
    state = %{state | entries: entries}

    case entry do
      nil ->
        state = bump(state, :rejected_consume)
        {:reply, {:error, :invalid_receipt}, state}

      %{expires_at_ms: exp} when exp <= now ->
        state = bump(state, :expired) |> bump(:rejected_consume)
        {:reply, {:error, :invalid_receipt}, state}

      %{resource_uri: ^resource_uri, action: ^action, principal_id: principal_id} = entry
      when not is_map_key(entry, :operation_digest) ->
        state = bump(state, :consumed)
        {:reply, {:ok, principal_id}, state}

      _mismatch ->
        # Token already removed — cannot retry against another target.
        state = bump(state, :rejected_consume)
        {:reply, {:error, :invalid_receipt}, state}
    end
  end

  defp handle_authenticated_request(
         {:consume_conversation_operation, token, resource, digest},
         _from,
         state
       ) do
    now = state.clock.()
    {entry, entries} = Map.pop(state.entries, token)
    state = %{state | entries: entries}

    case entry do
      %{expires_at_ms: expiry} when expiry <= now ->
        {:reply, {:error, :invalid_receipt}, bump(state, :expired) |> bump(:rejected_consume)}

      %{
        resource_uri: ^resource,
        action: :chat,
        operation_digest: ^digest,
        principal_id: principal,
        canonical_owner_id: owner,
        expected_engagement_id: expected
      } ->
        binding = %{
          principal_id: principal,
          canonical_owner_id: owner,
          expected_engagement_id: expected
        }

        {:reply, {:ok, binding}, bump(state, :consumed)}

      _ ->
        {:reply, {:error, :invalid_receipt}, bump(state, :rejected_consume)}
    end
  end

  defp handle_authenticated_request({:discard, token}, _from, state) do
    {entry, entries} = Map.pop(state.entries, token)
    state = %{state | entries: entries}

    state =
      if is_nil(entry) do
        state
      else
        bump(state, :discarded)
      end

    {:reply, :ok, state}
  end

  defp handle_authenticated_request(
         {:memory_exchange, token, agent_id, sender_id, context},
         {owner, _},
         state
       ) do
    {entry, entries} = Map.pop(state.entries, token)
    state = prune_memory_admissions(%{state | entries: entries})
    resource = "arbor://chat/agent/" <> agent_id
    now = state.clock.()

    case entry do
      %{principal_id: ^sender_id, resource_uri: ^resource, action: :chat, expires_at_ms: expiry} =
          entry
      when expiry > now and not is_map_key(entry, :operation_digest) ->
        with true <- map_size(state.memory_admissions) < state.max_entries,
             {:ok, canonical_owner} <- Arbor.Security.resolve_conversation_owner(sender_id),
             true <- Map.get(entry, :canonical_owner_id, canonical_owner) == canonical_owner do
          create_memory_admission(
            state,
            owner,
            agent_id,
            sender_id,
            canonical_owner,
            Map.get(entry, :expected_engagement_id),
            context,
            now
          )
        else
          _ -> {:reply, {:error, :invalid_memory_admission}, state}
        end

      _ ->
        {:reply, {:error, :invalid_memory_admission}, state}
    end
  end

  defp handle_authenticated_request({:memory_activate, token, engagement_id}, {owner, _}, state) do
    state = prune_memory_admissions(state)

    with {:ok, %{status: :pending} = entry} <- memory_entry(state, token, owner),
         true <- PrivateMemory.scalar?(engagement_id),
         true <- engagement_matches?(entry, engagement_id) do
      entry = %{
        entry
        | status: :active,
          scope: Map.put(entry.scope, :engagement_id, engagement_id)
      }

      {:reply, :ok, put_in(state, [:memory_admissions, token], entry)}
    else
      _ -> {:reply, {:error, :invalid_memory_admission}, state}
    end
  end

  defp handle_authenticated_request(
         {:memory_check_engagement, token, engagement_id},
         {owner, _},
         state
       ) do
    state = prune_memory_admissions(state)

    result =
      with {:ok, entry} <- memory_entry(state, token, owner),
           true <- PrivateMemory.scalar?(engagement_id),
           true <- engagement_matches?(entry, engagement_id) do
        :ok
      else
        _ -> {:error, :invalid_memory_admission}
      end

    {:reply, result, state}
  end

  defp handle_authenticated_request({:memory_binding, token}, {owner, _}, state) do
    state = prune_memory_admissions(state)

    reply =
      case memory_entry(state, token, owner) do
        {:ok, %{scope: scope}} ->
          {:ok,
           %{
             authenticated_principal_id: scope.authenticated_principal_id,
             canonical_owner_id: scope.human_id
           }}

        _ ->
          {:error, :invalid_memory_admission}
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_request({:memory_scope, token}, {owner, _}, state) do
    state = prune_memory_admissions(state)

    reply =
      case memory_entry(state, token, owner) do
        {:ok, %{status: :active, scope: scope}} -> {:ok, scope}
        _ -> {:error, :invalid_memory_admission}
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_request({:memory_close, token}, {owner, _}, state) do
    state = prune_memory_admissions(state)

    case Map.get(state.memory_admissions, token) do
      nil -> {:reply, :ok, state}
      %{owner: ^owner} -> {:reply, :ok, remove_memory_admission(state, token)}
      _ -> {:reply, {:error, :invalid_memory_admission}, state}
    end
  end

  defp handle_authenticated_request({:memory_attestation_scope, token, owner}, {caller, _}, state) do
    state = prune_memory_admissions(state)

    reply =
      with true <-
             SupervisedOwner.authorized?(
               caller,
               :arbor_security,
               [Arbor.Security.SystemAuthority]
             ),
           {:ok, %{status: :active, scope: scope}} <- memory_entry(state, token, owner) do
        {:ok, scope}
      else
        _ -> {:error, :invalid_memory_admission}
      end

    {:reply, reply, state}
  end

  defp handle_authenticated_request(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        active: map_size(state.entries)
      })

    {:reply, stats, state}
  end

  if Mix.env() == :test do
    defp handle_authenticated_request({:set_clock_fixture, clock}, _from, state)
         when is_function(clock, 0),
         do: {:reply, :ok, %{state | clock: clock}}
  end

  defp handle_private_info(:cleanup, state) do
    state = state |> prune_expired() |> prune_memory_admissions()
    schedule_cleanup(state.cleanup_interval_ms)
    {:noreply, state}
  end

  defp handle_private_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.memory_monitors, ref) do
      nil -> {:noreply, state}
      token -> {:noreply, remove_memory_admission(state, token)}
    end
  end

  defp handle_private_info(message, state) do
    case Arbor.Common.handle_authenticated_call(message, state.authenticated_calls) do
      {:authenticated, caller, request, reply_to} ->
        case handle_authenticated_request(request, {caller, reply_to}, state) do
          {:reply, reply, next_state} ->
            :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
            {:noreply, next_state}

          {:stop, reason, reply, next_state} ->
            :ok = Arbor.Common.reply_authenticated_call(reply_to, reply)
            {:stop, reason, next_state}
        end

      result when result in [:pending, :expired, :rejected] ->
        {:noreply, state}

      :unrecognized ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(message, private_state) do
    with {:ok, state} <- private_state(private_state) do
      case handle_private_info(message, state) do
        {:noreply, next_state} ->
          case put_private_state(private_state, next_state) do
            :ok -> {:noreply, private_state}
            {:error, _reason} -> {:stop, :invalid_private_state, private_state}
          end

        {:stop, reason, next_state} ->
          _ = put_private_state(private_state, next_state)
          {:stop, reason, private_state}
      end
    else
      {:error, _reason} -> {:stop, :invalid_private_state, private_state}
    end
  end

  @impl true
  def format_status(status) when is_map(status) do
    redacted =
      status
      |> Map.put(:message, :redacted)
      |> Map.put(:state, %{delivery_receipt_broker: :redacted})

    maybe_redact_status_field(redacted, :reason)
    |> maybe_redact_status_field(:log)
  end

  @impl true
  def terminate(_reason, private_state) do
    case private_state(private_state) do
      {:ok, state} ->
        Enum.each(Map.keys(state.memory_monitors), &Process.demonitor(&1, [:flush]))

      {:error, _reason} ->
        :ok
    end

    PrivateState.delete(private_state, @private_state_anchor)
    :ok
  end

  defp private_state(state) do
    PrivateState.fetch(
      state,
      @private_state_anchor,
      @private_state_schema,
      &valid_private_state?/1
    )
  end

  defp put_private_state(handle, state) do
    PrivateState.replace(
      handle,
      @private_state_anchor,
      @private_state_schema,
      state,
      &valid_private_state?/1
    )
  end

  defp valid_private_state?(state) when is_map(state) do
    Map.keys(state) |> Enum.sort() ==
      [
        :authenticated_calls,
        :authorization_required,
        :cleanup_interval_ms,
        :clock,
        :entries,
        :max_entries,
        :memory_admissions,
        :memory_monitors,
        :memory_ttl_ms,
        :stats,
        :ttl_ms
      ] and
      is_boolean(state.authorization_required) and is_reference(state.authenticated_calls) and
      is_map(state.entries) and is_map(state.memory_admissions) and
      is_map(state.memory_monitors) and is_map(state.stats) and is_function(state.clock, 0) and
      Enum.all?(
        [state.cleanup_interval_ms, state.max_entries, state.memory_ttl_ms, state.ttl_ms],
        &(is_integer(&1) and &1 > 0)
      )
  end

  defp valid_private_state?(_state), do: false

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp issue_reply(state, principal_id, resource_uri, action) do
    # Skip O(n) expiry prune while under capacity; prune once at capacity and
    # re-check before returning :broker_full. Periodic cleanup still runs.
    state =
      if map_size(state.entries) >= state.max_entries do
        prune_expired(state)
      else
        state
      end

    now = state.clock.()

    cond do
      map_size(state.entries) >= state.max_entries ->
        state = bump(state, :rejected_full)
        {:reply, {:error, :broker_full}, state}

      true ->
        case mint_receipt(state, principal_id, resource_uri, action, now) do
          {:ok, receipt, state} ->
            {:reply, {:ok, receipt}, bump(state, :issued)}

          {:error, reason, state} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  defp issue_conversation_reply(
         state,
         principal,
         resource,
         canonical_owner,
         expected_engagement_id
       ) do
    case issue_reply(state, principal, resource, :chat) do
      {:reply, {:ok, receipt}, next} ->
        {:ok, token} = DeliveryReceipt.bearer_token(receipt)
        next = put_in(next, [:entries, token, :canonical_owner_id], canonical_owner)
        next = put_in(next, [:entries, token, :expected_engagement_id], expected_engagement_id)
        {:reply, {:ok, receipt}, next}

      other ->
        other
    end
  end

  defp issue_conversation_operation_reply(state, principal, resource, owner, expected, digest) do
    case issue_conversation_reply(state, principal, resource, owner, expected) do
      {:reply, {:ok, receipt}, next} ->
        {:ok, token} = DeliveryReceipt.bearer_token(receipt)
        {:reply, {:ok, receipt}, put_in(next, [:entries, token, :operation_digest], digest)}

      other ->
        other
    end
  end

  defp create_memory_admission(
         state,
         owner,
         agent_id,
         principal_id,
         human_id,
         expected_engagement_id,
         context,
         now
       ) do
    token = :crypto.strong_rand_bytes(@token_bytes)

    if Map.has_key?(state.memory_admissions, token) do
      {:reply, {:error, :receipt_issue_failed}, state}
    else
      ref = Process.monitor(owner)

      scope =
        Map.merge(context, %{
          agent_id: agent_id,
          human_id: human_id,
          authenticated_principal_id: principal_id
        })

      entry = %{
        owner: owner,
        monitor: ref,
        scope: scope,
        status: :pending,
        expected_engagement_id: expected_engagement_id,
        expires_at_ms: now + state.memory_ttl_ms
      }

      {:ok, admission} = PrivateMemoryAdmission.new(token)

      state =
        state
        |> put_in([:memory_admissions, token], entry)
        |> put_in([:memory_monitors, ref], token)

      {:reply, {:ok, admission}, state}
    end
  end

  defp engagement_matches?(entry, engagement_id) do
    expected = Map.get(entry, :expected_engagement_id)
    bound = Map.get(entry.scope, :engagement_id)
    (is_nil(expected) or expected == engagement_id) and (is_nil(bound) or bound == engagement_id)
  end

  defp memory_entry(state, token, owner) do
    case Map.get(state.memory_admissions, token) do
      %{owner: ^owner} = entry ->
        if Process.alive?(owner), do: {:ok, entry}, else: {:error, :invalid_memory_admission}

      _ ->
        {:error, :invalid_memory_admission}
    end
  end

  defp remove_memory_admission(state, token) do
    case Map.pop(state.memory_admissions, token) do
      {nil, _} ->
        state

      {entry, admissions} ->
        Process.demonitor(entry.monitor, [:flush])

        %{
          state
          | memory_admissions: admissions,
            memory_monitors: Map.delete(state.memory_monitors, entry.monitor)
        }
    end
  end

  defp prune_memory_admissions(state) do
    now = state.clock.()

    Enum.reduce(state.memory_admissions, state, fn {token, entry}, acc ->
      if entry.expires_at_ms <= now or not Process.alive?(entry.owner),
        do: remove_memory_admission(acc, token),
        else: acc
    end)
  end

  defp maybe_claim_directory(__MODULE__) do
    table = :ets.new(@owner_table, [:named_table, :protected, :set, read_concurrency: true])
    true = :ets.insert(table, {:owner, self()})
    :ok
  rescue
    _ -> {:error, :broker_owner_directory_unavailable}
  end

  defp maybe_claim_directory(_custom_name), do: :ok

  defp default_owner_pid do
    SupervisedOwner.protected_directory_owner(
      @owner_table,
      :owner,
      :arbor_security,
      [__MODULE__]
    )
  end

  defp mint_receipt(state, principal_id, resource_uri, action, now) do
    do_mint(state, principal_id, resource_uri, action, now, @max_token_attempts)
  end

  defp do_mint(state, _principal_id, _resource_uri, _action, _now, 0) do
    {:error, :receipt_issue_failed, bump(state, :rejected_issue)}
  end

  defp do_mint(state, principal_id, resource_uri, action, now, attempts_left) do
    token = :crypto.strong_rand_bytes(@token_bytes)

    cond do
      Map.has_key?(state.entries, token) ->
        do_mint(state, principal_id, resource_uri, action, now, attempts_left - 1)

      true ->
        case DeliveryReceipt.new(token: token) do
          {:ok, receipt} ->
            entry = %{
              principal_id: principal_id,
              resource_uri: resource_uri,
              action: action,
              expires_at_ms: now + state.ttl_ms
            }

            state = put_in(state, [:entries, token], entry)
            {:ok, receipt, state}

          {:error, _reason} ->
            do_mint(state, principal_id, resource_uri, action, now, attempts_left - 1)
        end
    end
  end

  defp prune_expired(state) do
    now = state.clock.()

    {kept, expired_count} =
      Enum.reduce(state.entries, {%{}, 0}, fn {token, entry}, {acc, count} ->
        if entry.expires_at_ms <= now do
          {acc, count + 1}
        else
          {Map.put(acc, token, entry), count}
        end
      end)

    state = %{state | entries: kept}

    if expired_count > 0 do
      update_in(state, [:stats, :expired], &(&1 + expired_count))
    else
      state
    end
  end

  defp bump(state, key) do
    update_in(state, [:stats, key], &(&1 + 1))
  end

  defp schedule_cleanup(interval_ms) do
    Process.send_after(self(), :cleanup, interval_ms)
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp normalize_clock(fun) when is_function(fun, 0), do: fun

  defp normalize_clock(fun) when is_function(fun, 1) do
    fn -> fun.(:millisecond) end
  end

  defp normalize_clock(_), do: fn -> System.monotonic_time(:millisecond) end

  defp maybe_redact_status_field(status, key) do
    if Map.has_key?(status, key), do: Map.put(status, key, :redacted), else: status
  end
end
