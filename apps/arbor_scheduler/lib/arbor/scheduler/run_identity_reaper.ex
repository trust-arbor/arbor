defmodule Arbor.Scheduler.RunIdentityReaper do
  @moduledoc """
  Reconciles scheduler-run identities owned by this local BEAM runtime.

  The runtime marker includes both the distributed node name and a per-BEAM
  instance marker. `:run_identity_runtime_id` is a logical namespace only; it
  never removes the instance marker. This prevents concurrent non-distributed
  runtimes from reaping each other's live identities.

  Residue from an obsolete BEAM runtime cannot be discovered safely without a
  durable ownership registry, so reconciliation is intentionally limited to
  the current BEAM instance.
  """

  use GenServer

  alias Arbor.Scheduler.{Identity, RunIdentity, RunLease}
  alias Arbor.Security
  alias Arbor.Trust

  @test_env Mix.env() == :test
  @startup_retry_ms 10
  @startup_retry_limit 100

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  @spec await_ready(timeout()) :: :ok | {:error, term()}
  def await_ready(timeout \\ 30_000) do
    GenServer.call(__MODULE__, :await_ready, timeout)
  catch
    :exit, {reason, {GenServer, :call, _args}} -> {:error, reason}
    :exit, reason -> {:error, reason}
  end

  @impl true
  def init(opts) do
    Process.flag(:sensitive, true)

    {:ok,
     %{
       opts: opts,
       status: :pending,
       retry_count: 0,
       reconcile_ref: make_ref(),
       ready_waiters: []
     }, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state), do: attempt_reconcile(state)

  @impl true
  def handle_call(:await_ready, from, %{status: :pending} = state) do
    {:noreply, %{state | ready_waiters: [from | state.ready_waiters]}}
  end

  def handle_call(:await_ready, _from, %{status: :ready} = state), do: {:reply, :ok, state}

  def handle_call(:await_ready, _from, %{status: {:error, error}} = state),
    do: {:reply, {:error, error}, state}

  def handle_call(_request, _from, state),
    do: {:reply, {:error, :run_identity_reaper_unauthorized}, state}

  @impl true
  def handle_cast(_request, state), do: {:noreply, state}

  @impl true
  def handle_info({:reconcile, reconcile_ref}, %{reconcile_ref: reconcile_ref} = state),
    do: attempt_reconcile(state)

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def reconcile(opts \\ []) do
    if legitimate_reconcile_caller?(self()) do
      perform_reconcile(opts)
    else
      {:error, :run_identity_reaper_unauthorized}
    end
  end

  defp perform_reconcile(opts) do
    security = Keyword.get(opts, :security_facade, Security)
    trust = Keyword.get(opts, :trust_facade, Trust)
    identity_name = Keyword.get(opts, :identity_name, RunIdentity.identity_name())
    active_cap_ids = Keyword.get(opts, :active_cap_ids)
    scheduler_mutation_token = scheduler_mutation_token(opts)

    with {:ok, active_ids} <- active_agent_ids(opts, active_cap_ids),
         {:ok, agent_ids} <- lookup_run_identities(security, identity_name) do
      agent_ids
      |> Enum.reduce_while(:ok, fn agent_id, :ok ->
        case reconcile_agent(
               agent_id,
               active_ids,
               active_cap_ids,
               security,
               trust,
               scheduler_mutation_token
             ) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {agent_id, reason}}}
        end
      end)
    end
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp reconcile_agent(
         agent_id,
         active_ids,
         active_cap_ids,
         security,
         trust,
         scheduler_mutation_token
       ) do
    cond do
      is_map(active_cap_ids) and Map.has_key?(active_cap_ids, agent_id) ->
        reap_orphan_capabilities(
          agent_id,
          Map.fetch!(active_cap_ids, agent_id),
          security,
          scheduler_mutation_token
        )

      MapSet.member?(active_ids, agent_id) ->
        :ok

      true ->
        reap(agent_id, security, trust, scheduler_mutation_token)
    end
  end

  defp reap_orphan_capabilities(agent_id, allowed_cap_ids, security, scheduler_mutation_token) do
    allowed_cap_ids = MapSet.new(allowed_cap_ids)

    with {:ok, caps} <- list_capabilities(security, agent_id) do
      orphan_caps = Enum.reject(caps, &MapSet.member?(allowed_cap_ids, &1.id))
      revoke_capabilities(orphan_caps, scheduler_mutation_token)
    end
  end

  defp lookup_run_identities(security, identity_name) do
    case security.lookup_identity_ids_by_display_name(identity_name) do
      {:ok, agent_ids} when is_list(agent_ids) -> {:ok, agent_ids}
      {:error, :not_found} -> {:ok, []}
      {:error, reason} -> {:error, {:identity_lookup_failed, reason}}
      other -> {:error, {:identity_lookup_failed, {:unexpected_result, other}}}
    end
  end

  defp reap(agent_id, security, trust, scheduler_mutation_token) do
    with {:ok, caps} <- list_capabilities(security, agent_id),
         :ok <- revoke_capabilities(caps, scheduler_mutation_token),
         :ok <- deregister_identity(agent_id, scheduler_mutation_token),
         :ok <- delete_trust_profile(trust, agent_id) do
      :ok
    end
  end

  defp active_agent_ids(opts, active_cap_ids) do
    value =
      case Keyword.fetch(opts, :active_agent_ids) do
        {:ok, configured} ->
          configured

        :error when is_map(active_cap_ids) ->
          active_cap_ids |> Map.keys() |> MapSet.new()

        :error ->
          RunLease.active_agent_ids()
      end

    case value do
      %MapSet{} = active_ids -> {:ok, active_ids}
      {:error, reason} -> {:error, {:active_run_lease_lookup_failed, reason}}
      other -> {:error, {:active_run_lease_lookup_failed, {:unexpected_result, other}}}
    end
  end

  defp attempt_reconcile(state) do
    case perform_reconcile(state.opts) do
      :ok ->
        reply_waiters(state.ready_waiters, :ok)
        {:noreply, %{state | status: :ready, ready_waiters: []}}

      {:error, {:active_run_lease_lookup_failed, reason}}
      when reason in [:recovery_in_progress, :run_lease_store_unavailable] and
             state.retry_count < @startup_retry_limit ->
        Process.send_after(self(), {:reconcile, state.reconcile_ref}, @startup_retry_ms)
        {:noreply, %{state | retry_count: state.retry_count + 1}}

      {:error, reason} ->
        error = {:run_identity_reconciliation_failed, reason}
        reply_waiters(state.ready_waiters, {:error, error})
        {:noreply, %{state | status: {:error, error}, ready_waiters: []}}
    end
  end

  defp reply_waiters(waiters, reply) do
    Enum.each(waiters, &GenServer.reply(&1, reply))
  end

  defp legitimate_reconcile_caller?(caller) do
    Enum.any?(
      [
        {[Arbor.Scheduler.RuntimeSupervisor, __MODULE__], __MODULE__},
        {[
           Arbor.Scheduler.RuntimeSupervisor,
           Arbor.Scheduler.RunLeaseSupervisor,
           Arbor.Scheduler.RunLease.Reconciler
         ], Arbor.Scheduler.RunLease.Reconciler}
      ],
      fn {path, registered_name} ->
        match?(
          {:ok, ^caller},
          Arbor.Common.supervised_registered_child_pid(
            :arbor_scheduler,
            path,
            registered_name
          )
        )
      end
    )
  rescue
    _exception -> false
  catch
    :exit, _reason -> false
  end

  defp list_capabilities(security, agent_id) do
    case security.list_capabilities(agent_id) do
      {:ok, caps} when is_list(caps) -> {:ok, caps}
      {:error, reason} -> {:error, {:capability_lookup_failed, reason}}
      other -> {:error, {:capability_lookup_failed, {:unexpected_result, other}}}
    end
  end

  defp revoke_capabilities(caps, scheduler_mutation_token) do
    Enum.reduce_while(caps, :ok, fn cap, :ok ->
      case normalize_delete(
             Identity.reap_capability(cap.id, scheduler_mutation_token),
             :capability_revoke_failed
           ) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp delete_trust_profile(trust, agent_id) do
    normalize_delete(trust.delete_trust_profile(agent_id), :trust_profile_delete_failed)
  end

  defp deregister_identity(agent_id, scheduler_mutation_token) do
    normalize_delete(
      Identity.reap_identity(agent_id, scheduler_mutation_token),
      :identity_deregister_failed
    )
  end

  defp scheduler_mutation_token(opts) do
    case Keyword.get(opts, :scheduler_mutation_token) do
      token when is_reference(token) ->
        token

      nil ->
        if @test_env do
          Application.get_env(:arbor_scheduler, :test_scheduler_mutation_token)
        end

      _ ->
        nil
    end
  end

  defp normalize_delete(:ok, _tag), do: :ok
  defp normalize_delete({:error, :not_found}, _tag), do: :ok
  defp normalize_delete({:error, reason}, tag), do: {:error, {tag, reason}}
  defp normalize_delete(other, tag), do: {:error, {tag, {:unexpected_result, other}}}
end
