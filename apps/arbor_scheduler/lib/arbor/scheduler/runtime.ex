defmodule Arbor.Scheduler.Runtime do
  @moduledoc false

  # Oban is the only scheduler component that produces work. It is a static
  # child of Arbor.Scheduler.RuntimeSupervisor in *standby* (no queues, no
  # plugins: jobs can be inserted but nothing executes and cron does not fire)
  # until Scheduler.Identity holds its operator-provisioned authority. Keeping
  # the standby child static means a RuntimeSupervisor restart never loses
  # Oban; Identity re-activates it after its own re-bootstrap.

  alias Arbor.Scheduler.Config

  @spec oban_child_spec(:standby | :active) :: Supervisor.child_spec()
  def oban_child_spec(:standby) do
    Oban.child_spec(Keyword.merge(oban_opts(), queues: false, plugins: false))
  end

  def oban_child_spec(:active), do: Oban.child_spec(oban_opts())

  @doc false
  @spec oban_mode() :: :active | :standby | :stopped
  def oban_mode do
    case Oban.config(Config.oban_name()) do
      %{queues: [], plugins: []} -> if standby_differs?(), do: :standby, else: :active
      _config -> :active
    end
  rescue
    _ -> :stopped
  catch
    :exit, _ -> :stopped
  end

  @doc """
  Replaces the standby Oban child of `runtime_supervisor` with the configured
  one. Idempotent: an already active Oban is left running.
  """
  @spec activate_oban(pid()) :: :ok | {:error, term()}
  def activate_oban(runtime_supervisor) when is_pid(runtime_supervisor) do
    if oban_mode() == :active do
      :ok
    else
      %{id: id} = spec = oban_child_spec(:active)

      with :ok <- ignore_not_found(Supervisor.terminate_child(runtime_supervisor, id)),
           :ok <- ignore_not_found(Supervisor.delete_child(runtime_supervisor, id)) do
        case Supervisor.start_child(runtime_supervisor, spec) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, {:oban_activation_failed, reason}}
        end
      end
    end
  end

  defp oban_opts do
    :arbor_scheduler
    |> Application.fetch_env!(Oban)
    |> Keyword.put_new(:name, Config.oban_name())
  end

  # When the configured instance itself has no queues or plugins, standby and
  # active are the same thing and there is nothing to activate.
  defp standby_differs? do
    opts = oban_opts()

    Keyword.get(opts, :queues) not in [nil, false, []] or
      Keyword.get(opts, :plugins) not in [nil, false, []]
  end

  defp ignore_not_found(:ok), do: :ok
  defp ignore_not_found({:error, :not_found}), do: :ok
  defp ignore_not_found({:error, reason}), do: {:error, {:oban_activation_failed, reason}}
end
