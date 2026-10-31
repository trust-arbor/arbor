defmodule Arbor.Trust.ApplicationStartProfileHostIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  setup do
    original_children = Application.fetch_env(:arbor_trust, :start_children)
    original_runtime = Application.fetch_env(:arbor_kernel, :kernel_runtime)

    on_exit(fn ->
      Application.stop(:arbor_trust)
      Arbor.Trust.PolicyHost.release_claim()
      restore(:arbor_trust, :start_children, original_children)
      restore(:arbor_kernel, :kernel_runtime, original_runtime)
      {:ok, _} = Application.ensure_all_started(:arbor_trust)
    end)

    :ok
  end

  test ":full starts the policy host plus the provider tree" do
    assert {:ok, _} = restart_trust!(:full, true)

    ids = application_child_ids()
    assert MapSet.member?(ids, Arbor.Trust.PolicyHost)
    assert MapSet.member?(ids, Arbor.Trust.ProviderGate)
    assert MapSet.member?(ids, Arbor.Trust.Supervisor)
    assert Process.whereis(Arbor.Trust.Manager)
    assert Arbor.Trust.healthy?()

    started = Application.started_applications() |> Enum.map(&elem(&1, 0))
    assert :arbor_persistence_host in started
    assert :phoenix_pubsub in started
  end

  defp restart_trust!(profile, start_children) do
    Application.put_env(:arbor_trust, :start_children, start_children)
    runtime = Application.get_env(:arbor_kernel, :kernel_runtime, [])

    Application.put_env(
      :arbor_kernel,
      :kernel_runtime,
      Keyword.put(runtime, :start_profile, profile)
    )

    Application.stop(:arbor_trust)
    Arbor.Trust.PolicyHost.release_claim()
    Application.ensure_all_started(:arbor_trust)
  end

  defp application_child_ids do
    Arbor.Trust.ApplicationSupervisor
    |> Supervisor.which_children()
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)
end
