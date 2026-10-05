defmodule Breeze.TerminalOwnershipTest do
  use ExUnit.Case, async: true

  defmodule Adapter do
    @behaviour Termite.Terminal.Adapter

    def start(opts) do
      observer = Keyword.fetch!(opts, :observer)
      {:ok, pid} = Agent.start(fn -> %{resizes: 0} end)

      terminal = %{
        observer: observer,
        pid: pid,
        reader: make_ref(),
        fail_resize_on: Keyword.get(opts, :fail_resize_on)
      }

      send(observer, {:adapter_started, terminal})
      {:ok, terminal}
    end

    def reader(terminal), do: {:ok, terminal.reader}

    def resize(terminal) do
      count =
        Agent.get_and_update(terminal.pid, fn state ->
          next = state.resizes + 1
          {next, %{state | resizes: next}}
        end)

      if count == terminal.fail_resize_on, do: raise("owned adapter resize witness")
      %{width: 60, height: 12}
    end

    def write(terminal, text) do
      send(terminal.observer, {:terminal_write, text})
      {:ok, terminal}
    end

    def stop(terminal) do
      Agent.stop(terminal.pid)
      send(terminal.observer, {:adapter_stopped, terminal.pid})
      :ok
    end
  end

  defmodule View do
    use Breeze.View
    def mount(_opts, term), do: {:ok, term}
    def render(assigns), do: ~H"<box>Owned terminal</box>"
  end

  defmodule FailedView do
    use Breeze.View
    def mount(_opts, _term), do: raise("test-owned failed mount")
    def render(assigns), do: ~H"<box>Unreachable</box>"
  end

  defp options(extra) do
    Keyword.merge(
      [
        view: View,
        terminal_opts: [adapter: Adapter, observer: self()],
        theme: Breeze.Theme.builtin(:greenscreen),
        logger: false,
        reload: false,
        inspector: false
      ],
      extra
    )
  end

  test "public session stop releases its created adapter once after restoring paste mode" do
    {:ok, session} = Breeze.Server.start_link(options([]))
    assert_receive {:adapter_started, terminal}
    assert Process.alive?(terminal.pid)
    assert :ok = Breeze.Server.stop(session)
    assert_receive {:terminal_write, "\e[?2004l"}
    assert_receive {:adapter_stopped, pid}
    assert pid == terminal.pid
    refute Process.alive?(pid)
    assert :ok = Breeze.Server.stop(session)
    refute_receive {:adapter_stopped, _}
  end

  test "public session stop restores a borrowed terminal without stopping its adapter" do
    terminal = Termite.Terminal.start(adapter: Adapter, observer: self())
    assert_receive {:adapter_started, adapter}
    {:ok, session} = Breeze.Server.start_link(options(terminal: terminal))
    assert :ok = Breeze.Server.stop(session)
    assert_receive {:terminal_write, "\e[?2004l"}
    refute_receive {:adapter_stopped, _}
    assert Process.alive?(adapter.pid)
    assert :ok = Termite.Terminal.stop(terminal)
    assert_receive {:adapter_stopped, pid}
    assert pid == adapter.pid
    refute Process.alive?(pid)
  end

  test "failed view startup restores and releases only its created adapter" do
    assert {:error, _reason} = Breeze.InputRouter.start(options(view: FailedView))
    assert_receive {:adapter_started, terminal}
    assert_receive {:terminal_write, "\e[?2004l"}
    assert_receive {:adapter_stopped, pid}
    assert pid == terminal.pid
    refute Process.alive?(pid)
    refute_receive {:adapter_stopped, _}
  end

  test "security regression: exit-handler registration failure releases the created adapter" do
    register = fn _callback -> raise "owned exit registration witness" end
    assert {:error, _} = Breeze.InputRouter.start(options(internal: [at_exit_register: register]))
    assert_receive {:adapter_started, adapter}
    cleanup_fixture_on_failure(adapter)
    assert_receive {:adapter_stopped, pid}
    assert pid == adapter.pid
    refute Process.alive?(pid)
    refute_receive {:adapter_stopped, _}
  end

  test "security regression: second resize failure releases the created adapter before mode setup" do
    opts = options(terminal_opts: [adapter: Adapter, observer: self(), fail_resize_on: 2])
    assert {:error, _} = Breeze.InputRouter.start(opts)
    assert_receive {:adapter_started, adapter}
    cleanup_fixture_on_failure(adapter)
    assert_receive {:adapter_stopped, pid}
    assert pid == adapter.pid
    refute Process.alive?(pid)
    refute_receive {:adapter_stopped, _}
  end

  test "exit-handler registration failure preserves a borrowed adapter" do
    terminal = Termite.Terminal.start(adapter: Adapter, observer: self())
    assert_receive {:adapter_started, adapter}
    cleanup_fixture_on_failure(adapter)
    register = fn _callback -> raise "borrowed exit registration witness" end

    assert {:error, _} =
             Breeze.InputRouter.start(
               options(terminal: terminal, internal: [at_exit_register: register])
             )

    refute_receive {:adapter_stopped, _}
    assert Process.alive?(adapter.pid)
    assert :ok = Termite.Terminal.stop(terminal)
    assert_receive {:adapter_stopped, pid}
    assert pid == adapter.pid
  end

  # On a red predecessor, dispose only this test-owned adapter after assertions.
  # No post-test disposal message contributes to a claimed cleanup witness.
  defp cleanup_fixture_on_failure(adapter) do
    on_exit(fn ->
      if Process.alive?(adapter.pid),
        do: Termite.Terminal.stop(%Termite.Terminal{adapter: {Adapter, adapter}})
    end)
  end
end
