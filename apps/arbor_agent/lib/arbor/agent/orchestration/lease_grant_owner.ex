defmodule Arbor.Agent.Orchestration.LeaseGrantOwner do
  @moduledoc """
  Supervised owner of a preprovisioned task-control lease grant principal.
  A grant requires an acknowledged recovery marker and live reservation token.
  """

  use GenServer

  alias Arbor.Agent.Orchestration.{TaskControlLease, TaskStore}
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security

  @purpose :orchestration_lease_grant
  @resources ["arbor://security/grant/**", "arbor://security/revoke/**"]
  @ticket_lifetime_seconds 300

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  def begin_dispatch(principal, target_agent_id, auth_opts) do
    GenServer.call(__MODULE__, {:begin_dispatch, principal, target_agent_id, auth_opts}, 30_000)
  catch
    :exit, _ -> {:error, :lease_grant_owner_unavailable}
  end

  @doc false
  def close_dispatch(ticket) when is_binary(ticket) do
    GenServer.call(__MODULE__, {:close_dispatch, ticket})
  catch
    :exit, _ -> :ok
  end

  def close_dispatch(_), do: :ok

  @doc false
  def grant(kind, spec, token, store_opts \\ [], ticket \\ nil) do
    GenServer.call(__MODULE__, {:grant, kind, spec, token, store_opts, ticket}, 30_000)
  catch
    :exit, _ -> {:error, :lease_grant_owner_unavailable}
  end

  @doc false
  def revoke(capability_id, store_opts \\ [])

  def revoke(capability_id, store_opts)
      when is_binary(capability_id) and capability_id != "" do
    GenServer.call(__MODULE__, {:revoke, capability_id, store_opts}, 30_000)
  catch
    :exit, _ -> {:error, :lease_grant_owner_unavailable}
  end

  def revoke(_, _), do: {:error, :invalid_request}

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)
    {:ok, %{minted_ids: MapSet.new(), tickets: %{}}}
  end

  @impl true
  def handle_call({:begin_dispatch, principal, target_agent_id, auth_opts}, {caller, _}, state) do
    now = System.monotonic_time(:second)

    state = %{
      state
      | tickets: Map.filter(state.tickets, fn {_id, entry} -> entry.expires_at >= now end)
    }

    with true <- is_binary(principal) and principal != "",
         true <- is_binary(target_agent_id) and target_agent_id != "",
         :ok <- valid_auth_opts(auth_opts),
         :ok <- authorized_dispatch?(principal, target_agent_id, auth_opts) do
      ticket = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      entry = %{
        principal: principal,
        target_agent_id: target_agent_id,
        caller: caller,
        expires_at: now + @ticket_lifetime_seconds
      }

      {:reply, {:ok, ticket}, put_in(state.tickets[ticket], entry)}
    else
      _ -> {:reply, {:error, {:unauthorized, :agent_dispatch_required}}, state}
    end
  end

  def handle_call({:close_dispatch, ticket}, _from, state) do
    {:reply, :ok, update_in(state.tickets, &Map.delete(&1, ticket))}
  end

  def handle_call({:grant, kind, spec, token, store_opts, ticket}, {caller, _}, state) do
    result =
      with :ok <- valid_spec(kind, spec),
           {:ok, target_agent_id} <- admitted?(spec, token, store_opts),
           :ok <-
             valid_ticket?(
               state,
               ticket,
               caller,
               Keyword.fetch!(spec, :principal),
               target_agent_id
             ),
           {:ok, authority} <- open_authority() do
        try do
          Security.grant(Keyword.put(spec, :actor_authority, authority))
        after
          _ = Security.close_signing_authority(authority)
        end
      end

    state =
      case result do
        {:ok, %{id: id}} when is_binary(id) ->
          %{state | minted_ids: MapSet.put(state.minted_ids, id)}

        _ ->
          state
      end

    {:reply, result, state}
  end

  def handle_call({:revoke, capability_id, store_opts}, _from, state) do
    if MapSet.member?(state.minted_ids, capability_id) or
         admitted_revoke?(capability_id, store_opts) do
      result =
        with {:ok, authority} <- open_authority() do
          try do
            Security.revoke(capability_id, actor_authority: authority)
          after
            _ = Security.close_signing_authority(authority)
          end
        end

      state =
        if result in [:ok, {:error, :not_found}, {:error, :already_revoked}],
          do: %{state | minted_ids: MapSet.delete(state.minted_ids, capability_id)},
          else: state

      {:reply, result, state}
    else
      {:reply, {:error, :lease_capability_not_owned}, state}
    end
  end

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :lease_grant_unauthorized}, state}

  @impl true
  def format_status(%{state: state} = status) when is_map(state) do
    Map.put(status, :state, %{
      minted_count: MapSet.size(state.minted_ids),
      ticket_count: map_size(state.tickets)
    })
  end

  def format_status(status), do: status

  defp valid_spec(kind, spec) when is_list(spec) do
    principal = Keyword.get(spec, :principal)
    task_id = Keyword.get(spec, :task_id)
    expires_at = Keyword.get(spec, :expires_at)

    with true <- kind in TaskControlLease.kinds(),
         true <- is_binary(principal) and principal != "",
         true <- TaskControlLease.valid_task_id?(task_id),
         %DateTime{} <- expires_at,
         true <-
           abs(
             DateTime.diff(
               expires_at,
               DateTime.add(DateTime.utc_now(), TaskControlLease.ttl_seconds(kind), :second),
               :second
             )
           ) <= 60,
         {:ok, expected} <-
           TaskControlLease.grant_spec(
             kind,
             principal,
             task_id,
             DateTime.add(expires_at, -TaskControlLease.ttl_seconds(kind), :second)
           ),
         true <- spec == expected do
      :ok
    else
      _ -> {:error, :invalid_lease_grant_spec}
    end
  rescue
    _ -> {:error, :invalid_lease_grant_spec}
  end

  defp valid_spec(_, _), do: {:error, :invalid_lease_grant_spec}

  defp admitted?(spec, token, store_opts) do
    if is_binary(token) and is_list(store_opts) do
      TaskStore.lease_grant_admitted?(
        Keyword.fetch!(spec, :task_id),
        token,
        Keyword.fetch!(spec, :principal),
        admitted_store_opts(store_opts)
      )
    else
      {:error, :lease_grant_not_admitted}
    end
  catch
    :exit, _ -> {:error, :lease_grant_not_admitted}
  end

  defp admitted_revoke?(capability_id, store_opts) when is_list(store_opts) do
    case TaskStore.lease_revoke_admitted?(capability_id, admitted_store_opts(store_opts)) do
      {:ok, task_id, kind} -> valid_retired_capability?(capability_id, task_id, kind)
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  defp admitted_revoke?(_, _), do: false

  defp valid_retired_capability?(capability_id, task_id, kind) do
    with {:ok, resource} <- TaskControlLease.uri(kind, task_id),
         {:ok, fence} <- Security.prepare_acknowledged_revoke(capability_id),
         principal when is_binary(principal) <- Map.get(fence, "principal_id"),
         {:ok, _} <-
           Security.admit_acknowledged_revoke_fence(fence, %{
             capability_id: capability_id,
             principal_id: principal,
             resource_uri: resource
           }),
         {:ok, capabilities} <- Security.list_capabilities(principal) do
      Enum.any?(capabilities, fn
        %Capability{id: ^capability_id, resource_uri: ^resource, metadata: metadata} ->
          is_map(metadata) and Map.get(metadata, :source) == :orchestration_task_dispatch and
            Map.get(metadata, :task_id) == task_id and
            Map.get(metadata, :kind) == Atom.to_string(kind)

        _ ->
          false
      end)
    else
      {:error, :not_found} -> true
      _ -> false
    end
  end

  defp valid_auth_opts(verify_identity: false), do: :ok

  defp valid_auth_opts(verify_identity: false, session_token: token)
       when is_binary(token) and byte_size(token) in 1..4096,
       do: :ok

  defp valid_auth_opts(_), do: {:error, :lease_dispatch_unauthorized}

  defp valid_ticket?(state, ticket, caller, principal, target_agent_id) do
    case Map.get(state.tickets, ticket) do
      %{
        principal: ^principal,
        target_agent_id: ^target_agent_id,
        caller: ^caller,
        expires_at: expires_at
      } ->
        if expires_at >= System.monotonic_time(:second),
          do: :ok,
          else: {:error, :lease_dispatch_unauthorized}

      _ ->
        {:error, :lease_dispatch_unauthorized}
    end
  end

  defp authorized_dispatch?(principal, target_agent_id, auth_opts) do
    resources = [
      "arbor://agent/dispatch/" <> target_agent_id,
      "arbor://agent/dispatch"
    ]

    if Enum.any?(resources, fn resource ->
         Security.authorize(principal, resource, :execute, auth_opts) ==
           {:ok, :authorized}
       end),
       do: :ok,
       else: {:error, :lease_dispatch_unauthorized}
  rescue
    _ -> {:error, :lease_dispatch_unauthorized}
  end

  if Mix.env() == :test do
    defp admitted_store_opts(opts), do: opts
  else
    defp admitted_store_opts(_opts), do: []
  end

  defp open_authority do
    principal = Application.get_env(:arbor_agent, :lease_grant_principal_id)

    with true <- is_binary(principal) and principal != "",
         {:ok, capabilities} <- Security.list_capabilities(principal),
         true <-
           Enum.all?(@resources, fn resource ->
             Enum.any?(capabilities, fn
               %Capability{resource_uri: ^resource} = cap -> Capability.valid?(cap)
               _ -> false
             end)
           end),
         {:ok, proof} <-
           Security.build_stored_signing_authority_acquisition_proof(
             principal,
             @purpose,
             self(),
             __MODULE__
           ) do
      Security.open_signing_authority(proof)
    else
      _ -> {:error, :lease_grant_owner_unavailable}
    end
  end
end
