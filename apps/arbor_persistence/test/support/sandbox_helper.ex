defmodule Arbor.Persistence.SandboxHelper do
  @moduledoc """
  Ensures the Ecto Repo is running with Sandbox in :auto mode.

  Call `Arbor.Persistence.SandboxHelper.setup()` from any app's
  test_helper.exs that might hit Postgres (directly or via BufferedStore).

  Only activates when ARBOR_DB=postgres. No-op otherwise.
  """

  def setup do
    if System.get_env("ARBOR_DB") == "postgres" do
      ensure_repo_started()
      Ecto.Adapters.SQL.Sandbox.mode(Arbor.Persistence.Repo, :auto)
    end
  end

  defp ensure_repo_started do
    if not is_pid(Process.whereis(Arbor.Persistence.Repo)) do
      case Supervisor.start_child(Arbor.Persistence.Supervisor, Arbor.Persistence.Repo) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, reason} -> IO.puts("[SandboxHelper] Repo start failed: #{inspect(reason)}")
      end
    end
  end
end
