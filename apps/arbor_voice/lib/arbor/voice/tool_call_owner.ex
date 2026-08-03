defmodule Arbor.Voice.ToolCallOwner do
  @moduledoc false
  # Per-tool-call coordinator. Activation handshake: does not spawn router work
  # until Session sends {:activate, token} after installing monitor + pending.
  # Proposes outcome before normal exit so Session can treat any remaining
  # matching DOWN (including :normal/:shutdown) as tool_failed when pending.

  alias Arbor.Voice.Session.ToolTaskCore

  @activate_wait_ms 5_000
  @max_output_bytes ToolTaskCore.max_output_bytes()

  @doc false
  def run(opts) when is_map(opts) do
    session_pid = Map.fetch!(opts, :session_pid)
    generation = Map.fetch!(opts, :generation)
    call_id = Map.fetch!(opts, :call_id)
    token = Map.fetch!(opts, :token)
    router = Map.fetch!(opts, :router)
    context = Map.fetch!(opts, :context)
    timeout_ms = Map.fetch!(opts, :timeout_ms)

    # Keep the supervisor/worker links load-bearing. Supervisor shutdown or an
    # unexpected worker crash takes this owner down, and Session's monitor owns
    # the single fallback outcome.
    Process.flag(:trap_exit, false)
    session_mon = Process.monitor(session_pid)

    # Wait for Session activation carrying the pre-created fence token.
    receive do
      {:DOWN, ^session_mon, :process, ^session_pid, _} ->
        exit(:shutdown)

      {:activate, ^token} ->
        :ok
    after
      @activate_wait_ms ->
        exit(:shutdown)
    end

    if not Process.alive?(session_pid) do
      _ = Process.demonitor(session_mon, [:flush])
      exit(:shutdown)
    end

    timeout_message = {:tool_timeout, generation, call_id, token}
    timer_ref = Process.send_after(self(), timeout_message, timeout_ms)
    owner = self()

    worker =
      spawn_link(fn ->
        output = router |> safe_invoke(context) |> ToolTaskCore.normalize()
        send(owner, {:worker_finished, generation, call_id, token, output})
      end)

    loop(%{
      session_pid: session_pid,
      session_mon: session_mon,
      timer_ref: timer_ref,
      timeout_message: timeout_message,
      worker: worker,
      generation: generation,
      call_id: call_id,
      token: token
    })
  end

  defp loop(
         %{
           generation: generation,
           call_id: call_id,
           token: token,
           timeout_message: timeout_message
         } = state
       ) do
    receive do
      {:DOWN, mon, :process, _pid, _reason} when mon == state.session_mon ->
        shutdown_owner(state)

      ^timeout_message ->
        shutdown_worker(state.worker)
        _ = Process.demonitor(state.session_mon, [:flush])
        propose(state, ToolTaskCore.normalize(:tool_timeout))
        exit(:normal)

      {:worker_finished, ^generation, ^call_id, ^token, output}
      when is_binary(output) and byte_size(output) <= @max_output_bytes ->
        cancel_timer(state.timer_ref, timeout_message)
        _ = Process.demonitor(state.session_mon, [:flush])
        # Outcome before normal exit — Session sees tool_outcome before DOWN.
        propose(state, output)
        exit(:normal)

      _other ->
        loop(state)
    end
  end

  defp shutdown_owner(state) do
    cancel_timer(state.timer_ref, state.timeout_message)
    shutdown_worker(state.worker)
    _ = Process.demonitor(state.session_mon, [:flush])
    exit(:shutdown)
  end

  defp propose(state, output) when is_binary(output) do
    send(
      state.session_pid,
      {:tool_outcome, state.generation, state.call_id, state.token, output}
    )

    :ok
  end

  defp safe_invoke(router, context) do
    case router.invoke(context) do
      {:ok, _} = ok -> ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> :invalid_return
    end
  rescue
    _ -> :tool_failed
  catch
    :exit, _ -> :tool_failed
    _kind, _reason -> :tool_failed
  end

  defp shutdown_worker(worker) when is_pid(worker) do
    # The owner must survive its own timeout/cancel kill long enough to propose
    # the terminal outcome. Other owner exits retain the link and kill workers.
    Process.unlink(worker)

    if Process.alive?(worker) do
      Process.exit(worker, :kill)
    end

    :ok
  end

  defp cancel_timer(ref, timeout_message) when is_reference(ref) do
    _ = Process.cancel_timer(ref)

    receive do
      ^timeout_message -> :ok
    after
      0 -> :ok
    end
  end
end
