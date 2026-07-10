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
    {:ok, %{status: :completed}}
  end
end
