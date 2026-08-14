defmodule Arbor.Signals.ConfigTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Signals.Config

  setup do
    original = Application.get_env(:arbor_signals, :durable_sink_module, :unset)

    on_exit(fn -> restore(:durable_sink_module, original) end)

    :ok
  end

  test "durable sink seam defaults to nil" do
    Application.delete_env(:arbor_signals, :durable_sink_module)
    assert Config.durable_sink_module() == nil
  end

  test "durable sink seam returns the configured module" do
    Application.put_env(:arbor_signals, :durable_sink_module, __MODULE__.FakeSink)
    assert Config.durable_sink_module() == __MODULE__.FakeSink
  end

  test "durable sink seam returns invalid env raw" do
    Application.put_env(:arbor_signals, :durable_sink_module, "not-a-module")
    assert Config.durable_sink_module() == "not-a-module"

    Application.put_env(:arbor_signals, :durable_sink_module, true)
    assert Config.durable_sink_module() == true
  end

  defp restore(key, :unset), do: Application.delete_env(:arbor_signals, key)
  defp restore(key, value), do: Application.put_env(:arbor_signals, key, value)

  defmodule FakeSink do
  end
end
