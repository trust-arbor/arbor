defmodule Arbor.Agent.RuntimeAdmission.OrdinaryStart do
  @moduledoc """
  Imperative shell for ordinary `Lifecycle.start/2` via runtime-admission intents.

  Validates opts, admits/joins through TaskStore, and restart-safely awaits
  settlement using the same fingerprint so vanished waiters rejoin after
  TaskStore restart.
  """

  alias Arbor.Agent.Orchestration.TaskStore
  alias Arbor.Agent.RuntimeAdmission.Opts

  @default_store TaskStore
  @default_deadline_ms 120_000
  @max_deadline_ms 180_000
  @ready_poll_ms 50
  @call_timeout_ms 30_000

  @doc """
  Admit or join an ordinary runtime start for `agent_id` and await settlement.
  """
  @spec request(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def request(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    store_ref = store_ref(opts)
    # Strip test-only seams before identity projection.
    identity_opts = Keyword.drop(opts, [:name, :task_store, :timeout_ms])

    with {:ok, %{fingerprint: fp, keyword: validated}} <- Opts.project(identity_opts) do
      deadline = absolute_deadline(opts)
      await_loop(agent_id, fp, validated, store_ref, deadline)
    end
  end

  defp await_loop(agent_id, fingerprint, validated, store_ref, deadline) do
    if now_ms() >= deadline do
      {:error, :timeout}
    else
      case ensure_ready(store_ref, deadline) do
        :ok ->
          admit_and_await(agent_id, fingerprint, validated, store_ref, deadline)

        {:error, :timeout} ->
          {:error, :timeout}

        {:error, :store_restart} ->
          await_loop(agent_id, fingerprint, validated, store_ref, deadline)

        {:error, _} = err ->
          err
      end
    end
  end

  defp admit_and_await(agent_id, fingerprint, validated, store_ref, deadline) do
    remaining = max(deadline - now_ms(), 1)
    call_timeout = min(@call_timeout_ms, remaining)

    try do
      case TaskStore.admit_ordinary_runtime_start(
             agent_id,
             fingerprint,
             validated,
             name: store_ref,
             timeout: call_timeout
           ) do
        {:ok, pid} when is_pid(pid) ->
          {:ok, pid}

        {:error, _} = err ->
          err

        other ->
          {:error, {:unexpected_admit_result, other}}
      end
    catch
      :exit, reason ->
        if store_restart_exit?(reason, store_ref) do
          # Wait readiness and rejoin same fingerprint.
          _ = wait_ready_after_restart(store_ref, deadline)
          await_loop(agent_id, fingerprint, validated, store_ref, deadline)
        else
          exit(reason)
        end
    end
  end

  defp ensure_ready(store_ref, deadline) do
    if now_ms() >= deadline do
      {:error, :timeout}
    else
      try do
        if TaskStore.runtime_admission_ready?(name: store_ref) do
          :ok
        else
          Process.sleep(@ready_poll_ms)
          ensure_ready(store_ref, deadline)
        end
      catch
        :exit, reason ->
          if store_restart_exit?(reason, store_ref) do
            Process.sleep(@ready_poll_ms)
            {:error, :store_restart}
          else
            exit(reason)
          end
      end
    end
  end

  defp wait_ready_after_restart(store_ref, deadline) do
    ensure_ready(store_ref, deadline)
  end

  defp store_ref(opts) do
    cond do
      Keyword.has_key?(opts, :name) -> Keyword.fetch!(opts, :name)
      Keyword.has_key?(opts, :task_store) and Mix.env() == :test -> Keyword.fetch!(opts, :task_store)
      true -> @default_store
    end
  end

  defp absolute_deadline(opts) do
    requested = Keyword.get(opts, :timeout_ms, @default_deadline_ms)

    ms =
      cond do
        not is_integer(requested) -> @default_deadline_ms
        requested < 1_000 -> 1_000
        requested > @max_deadline_ms -> @max_deadline_ms
        true -> requested
      end

    now_ms() + ms
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  @doc false
  def store_restart_exit?(reason, store_ref) do
    do_store_restart_exit?(reason, store_ref)
  end

  defp do_store_restart_exit?({:noproc, {GenServer, :call, args}}, store_ref),
    do: call_targets_store?(args, store_ref)

  defp do_store_restart_exit?({{:nodedown, _}, {GenServer, :call, args}}, store_ref),
    do: call_targets_store?(args, store_ref)

  defp do_store_restart_exit?({reason, {GenServer, :call, args}}, store_ref)
       when reason in [:normal, :shutdown, :killed, :noproc] do
    call_targets_store?(args, store_ref)
  end

  defp do_store_restart_exit?({{:shutdown, _}, {GenServer, :call, args}}, store_ref),
    do: call_targets_store?(args, store_ref)

  # Unrelated :noproc (non-GenServer.call shape) is NOT a store restart.
  defp do_store_restart_exit?(_, _), do: false

  defp call_targets_store?([store_ref | _], store_ref), do: true
  defp call_targets_store?(_, _), do: false
end
