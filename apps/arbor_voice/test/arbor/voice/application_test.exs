defmodule Arbor.Voice.ApplicationTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "the application supervisor is running" do
    pid = Process.whereis(Arbor.Voice.Supervisor)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "the Registry starts under the app supervisor and is usable" do
    assert Process.whereis(Arbor.Voice.Registry) |> is_pid()

    {:ok, _owner} = Registry.register(Arbor.Voice.Registry, :application_test_probe, :ok)
    assert Registry.lookup(Arbor.Voice.Registry, :application_test_probe) != []
  end
end
