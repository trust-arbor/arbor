defmodule Arbor.Shell.ExecutionWorker do
  @moduledoc false

  use GenServer

  alias Arbor.Shell.ExecutionRegistry

  defstruct [:execution_id, :runner, :opts, :start_ref]

  @spec start_link({String.t(), keyword(), (keyword() -> term()), reference()}) ::
          GenServer.on_start()
  def start_link({execution_id, opts, runner, start_ref}) do
    GenServer.start_link(__MODULE__, {execution_id, opts, runner, start_ref})
  end

  def child_spec(args) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl true
  def init({execution_id, opts, runner, start_ref}) do
    {:ok,
     %__MODULE__{
       execution_id: execution_id,
       opts: opts,
       runner: runner,
       start_ref: start_ref
     }}
  end

  @impl true
  def handle_info({:start_shell_execution, start_ref}, %{start_ref: start_ref} = state) do
    run_opts = Keyword.put(state.opts, :cancel_id, state.execution_id)

    case state.runner.(run_opts) do
      {:ok, result} when is_map(result) ->
        _ = ExecutionRegistry.finish(state.execution_id, result)

      {:error, reason} ->
        _ = ExecutionRegistry.fail(state.execution_id, reason)

      other ->
        _ = ExecutionRegistry.fail(state.execution_id, {:invalid_execution_result, other})
    end

    {:stop, :normal, state}
  end

  def handle_info({:cancel_shell_execution, execution_id}, %{execution_id: execution_id} = state) do
    result = cancellation_result()
    _ = ExecutionRegistry.finish(execution_id, result)
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp cancellation_result do
    %{
      exit_code: 137,
      stdout: "",
      stderr: "",
      duration_ms: 0,
      timed_out: false,
      killed: true,
      output_truncated: false,
      output_limit_exceeded: false,
      cancelled: true
    }
  end
end
