defmodule Arbor.Security.StartupTimeoutConfigTest do
  use ExUnit.Case, async: false

  alias Arbor.Security.Config

  @config_key :startup_timeout_ms

  setup do
    previous = Application.fetch_env(:arbor_security, @config_key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_security, @config_key, value)
        :error -> Application.delete_env(:arbor_security, @config_key)
      end
    end)

    Application.delete_env(:arbor_security, @config_key)
    :ok
  end

  test "startup readiness timeout scales from the declared inventory with floor and cap" do
    for {hydration_limit, expected_timeout} <- [
          {1, 30_000},
          {10_000, 30_000},
          {10_001, 30_003},
          {50_000, 150_000},
          {100_000, 300_000},
          {1_000_000, 300_000}
        ] do
      assert {:ok, ^expected_timeout} = Config.startup_timeout_ms(hydration_limit)
    end
  end

  test "operator override remains bounded to the same finite range" do
    for {override, expected_timeout} <- [
          {1, 30_000},
          {60_000, 60_000},
          {1_000_000, 300_000}
        ] do
      Application.put_env(:arbor_security, @config_key, override)
      assert {:ok, ^expected_timeout} = Config.startup_timeout_ms(100_000)
    end
  end

  test "malformed override and hydration limits fail closed" do
    Application.put_env(:arbor_security, @config_key, "60 seconds")
    assert {:error, :invalid_startup_timeout} = Config.startup_timeout_ms(10_000)

    Application.delete_env(:arbor_security, @config_key)

    for invalid <- [0, -1, nil, 10.5, "10000"] do
      assert {:error, :invalid_startup_timeout} = Config.startup_timeout_ms(invalid)
    end
  end
end
