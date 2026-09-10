defmodule Arbor.Scheduler.Config do
  @moduledoc false

  def orchestrator,
    do: Application.get_env(:arbor_scheduler, :orchestrator_module, Arbor.Orchestrator)

  def oban_name, do: Application.get_env(:arbor_scheduler, :oban_name, Oban)

  def repo do
    case Oban.config(oban_name()) do
      %{repo: repo, prefix: prefix} when prefix in [nil, false, "public"] -> repo
      _ -> raise ArgumentError, "owned routines require the default Oban SQL schema"
    end
  end

  def routine_logs_root,
    do:
      Application.get_env(
        :arbor_scheduler,
        :routine_logs_root,
        Path.join(System.tmp_dir!(), "arbor_orchestrator")
      )

  def morning_digest_pipeline,
    do:
      Application.get_env(
        :arbor_scheduler,
        :morning_digest_pipeline,
        Application.app_dir(:arbor_scheduler, "priv/pipelines/morning_digest.dot")
      )
end
