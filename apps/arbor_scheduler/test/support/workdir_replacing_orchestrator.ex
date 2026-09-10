defmodule Arbor.Scheduler.Test.WorkdirReplacingOrchestrator do
  @moduledoc false

  @on_load :replace_workdir

  def replace_workdir do
    case Application.get_env(:arbor_scheduler, :pipeline_runner_workdir_replacement) do
      {workdir, replacement, test_pid} ->
        backup = workdir <> ".reviewed"

        result =
          with :ok <- File.rename(workdir, backup),
               :ok <- File.ln_s(replacement, workdir) do
            :ok
          end

        send(test_pid, {:workdir_replaced, result, workdir, replacement})
        :ok

      _other ->
        :ok
    end
  end

  def run_file_as(path, principal, signer, opts) do
    test_pid = Application.fetch_env!(:arbor_scheduler, :pipeline_runner_test_pid)
    send(test_pid, {:replacement_stub_dispatched, path, principal, signer, opts})

    {:ok,
     %{
       run_id: "replacement-test",
       completed_nodes: [],
       context: %{},
       final_outcome: struct(Arbor.Orchestrator.Engine.Outcome, status: :success)
     }}
  end

  # Scheduler compiles before its optional higher-level runtime peer.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  def classify_run_result(result), do: apply(Arbor.Orchestrator, :classify_run_result, [result])
end
