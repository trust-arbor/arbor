defmodule Mix.Tasks.Arbor.HelpersOsMonTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Arbor.Helpers

  @moduletag :fast

  test "stop_os_mon is a no-op when os_mon is not started" do
    _ = Application.stop(:os_mon)
    assert Helpers.stop_os_mon() == :ok
  end

  test "stop_os_mon stops a started os_mon without port-exit noise" do
    {:ok, started} = Application.ensure_all_started(:os_mon)
    on_exit(fn -> Enum.each(Enum.reverse(started), &Application.stop/1) end)

    output =
      capture_io(:stderr, fn ->
        assert Helpers.stop_os_mon() == :ok
      end)

    refute output =~ "Erlang has closed"
    refute output =~ "memsup"
    refute output =~ "cpu_sup"
    refute :os_mon in Enum.map(Application.started_applications(), &elem(&1, 0))
  end

  test "install_mix_shutdown_hooks registers a Mix-VM os_mon stop" do
    source =
      File.read!(
        Path.expand(
          "../../../../lib/mix/tasks/arbor/arbor_helpers.ex",
          Path.dirname(__ENV__.file)
        )
      )

    assert source =~ "def install_mix_shutdown_hooks"
    assert source =~ "System.at_exit"
    assert source =~ "stop_os_mon()"
  end

  test "rpc_result/5 is a bounded result-preserving Mix RPC facade" do
    assert function_exported?(Helpers, :rpc_result, 4)
    assert function_exported?(Helpers, :rpc_result, 5)

    source =
      File.read!(
        Path.expand(
          "../../../../lib/mix/tasks/arbor/arbor_helpers.ex",
          Path.dirname(__ENV__.file)
        )
      )

    assert source =~ "def rpc_result(node, mod, fun, args, timeout)"
    assert source =~ ":rpc.call(node, @remote_call, :apply_quiet, [mod, fun, args], timeout)"
  end
end
