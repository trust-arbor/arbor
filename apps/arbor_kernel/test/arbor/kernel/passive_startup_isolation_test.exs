defmodule Arbor.Kernel.PassiveStartupIsolationTest do
  @moduledoc """
  K4B: `:arbor_kernel` is the passive protocol/schema owner. Its application
  metadata must not declare a callback, registered process, runtime owner, or
  retired physical application dependency.

  Process-state assertions belong to the isolated startup-footprint probe: the
  umbrella test runner has already started `:arbor_kernel_runtime`, so ambient
  process absence cannot prove that starting the passive app caused nothing.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  @retired_apps [:arbor_contracts, :arbor_common, :arbor_signals, :arbor_monitor]

  test "application declaration is passive and excludes all active or retired owners" do
    assert :ok = ensure_loaded(:arbor_kernel)
    assert Application.spec(:arbor_kernel, :mod) in [nil, []]
    assert Application.spec(:arbor_kernel, :registered) in [nil, []]

    applications = Application.spec(:arbor_kernel, :applications) || []

    refute :arbor_kernel_runtime in applications

    for retired <- @retired_apps do
      refute retired in applications
    end
  end

  defp ensure_loaded(app) do
    case Application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, ^app}} -> :ok
    end
  end
end
