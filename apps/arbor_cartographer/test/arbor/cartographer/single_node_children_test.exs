defmodule Arbor.Cartographer.SingleNodeChildrenTest do
  # Manages the globally named Cartographer processes.
  use ExUnit.Case, async: false

  alias Arbor.Cartographer
  alias Arbor.Cartographer.{CapabilityRegistry, ClusterKeeper, Scout}

  @moduletag :fast

  setup do
    stop_cartographer()
    on_exit(&stop_cartographer/0)
    :ok
  end

  test "single-node opts start only the passive CapabilityRegistry" do
    {:ok, _sup} = Cartographer.start_link(scout_enabled: false, cluster_keeper_enabled: false)

    child_ids = Supervisor.which_children(Arbor.Cartographer.Supervisor) |> Enum.map(&elem(&1, 0))

    assert child_ids == [CapabilityRegistry]
    assert Process.whereis(Scout) == nil
    assert Process.whereis(ClusterKeeper) == nil

    # Scout-backed facade calls fall back to on-demand detection.
    assert {:ok, tags} = Cartographer.my_capabilities()
    assert is_list(tags)
    assert {:ok, _hardware} = Cartographer.detect_hardware()
    assert {:error, :scout_not_running} = Cartographer.register_capabilities([:test_mode])
  end

  test "application config disables Scout and ClusterKeeper when no opts are given" do
    previous = Application.get_all_env(:arbor_cartographer)

    on_exit(fn ->
      for key <- [:scout_enabled, :cluster_keeper_enabled] do
        case Keyword.fetch(previous, key) do
          {:ok, value} -> Application.put_env(:arbor_cartographer, key, value)
          :error -> Application.delete_env(:arbor_cartographer, key)
        end
      end
    end)

    Application.put_env(:arbor_cartographer, :scout_enabled, false)
    Application.put_env(:arbor_cartographer, :cluster_keeper_enabled, false)

    {:ok, _sup} = Cartographer.start_link([])

    assert Process.whereis(CapabilityRegistry) != nil
    assert Process.whereis(Scout) == nil
    assert Process.whereis(ClusterKeeper) == nil
    assert Cartographer.healthy?()
  end

  test "Scout and ClusterKeeper still start by default" do
    {:ok, _sup} =
      Cartographer.start_link(
        introspection_interval: :timer.hours(1),
        load_update_interval: :timer.hours(1)
      )

    assert Process.whereis(Scout) != nil
    assert Process.whereis(ClusterKeeper) != nil
  end

  defp stop_cartographer do
    case Process.whereis(Arbor.Cartographer.Supervisor) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        try do
          Supervisor.stop(pid, :normal)
        catch
          :exit, _ -> :ok
        end

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5_000 -> :ok
        end
    end
  end
end
