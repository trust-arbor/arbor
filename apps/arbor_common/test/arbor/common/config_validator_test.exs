defmodule Arbor.Common.ConfigValidatorTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.ConfigValidator

  @moduletag :fast

  describe "validate/2" do
    setup do
      # Use a test app that won't conflict with real apps
      app = :config_validator_test_app

      on_exit(fn ->
        # Clean up any config we set
        Application.delete_env(app, :port)
        Application.delete_env(app, :host)
        Application.delete_env(app, :debug)
      end)

      {:ok, app: app}
    end

    test "returns ok for valid config", %{app: app} do
      Application.put_env(app, :port, 8080)
      Application.put_env(app, :host, "localhost")

      schema =
        Zoi.map(
          %{
            "port" => Zoi.integer() |> Zoi.min(1) |> Zoi.max(65535),
            "host" => Zoi.string()
          },
          coerce: true
        )

      assert {:ok, validated} = ConfigValidator.validate(app, schema)
      assert validated["port"] == 8080
      assert validated["host"] == "localhost"
    end

    test "returns error for invalid config", %{app: app} do
      Application.put_env(app, :port, 0)

      schema =
        Zoi.map(
          %{
            "port" => Zoi.integer() |> Zoi.min(1) |> Zoi.max(65535)
          },
          coerce: true
        )

      assert {:error, errors} = ConfigValidator.validate(app, schema)
      assert length(errors) > 0
      assert Enum.any?(errors, fn e -> e.field =~ "port" end)
    end

    test "handles missing required fields", %{app: app} do
      # Don't set any config

      schema =
        Zoi.map(
          %{
            "port" => Zoi.integer()
          },
          coerce: true
        )

      assert {:error, _errors} = ConfigValidator.validate(app, schema)
    end

    test "accepts optional fields when missing", %{app: app} do
      Application.put_env(app, :port, 8080)

      schema =
        Zoi.map(
          %{
            "port" => Zoi.integer(),
            "debug" => Zoi.boolean() |> Zoi.optional()
          },
          coerce: true
        )

      assert {:ok, validated} = ConfigValidator.validate(app, schema)
      assert validated["port"] == 8080
    end
  end

  describe "validate!/2" do
    setup do
      app = :config_validator_bang_test_app

      on_exit(fn ->
        Application.delete_env(app, :port)
      end)

      {:ok, app: app}
    end

    test "returns :ok for valid config", %{app: app} do
      Application.put_env(app, :port, 8080)

      schema =
        Zoi.map(
          %{
            "port" => Zoi.integer() |> Zoi.min(1)
          },
          coerce: true
        )

      assert :ok = ConfigValidator.validate!(app, schema)
    end

    test "raises for invalid config", %{app: app} do
      Application.put_env(app, :port, -1)

      schema =
        Zoi.map(
          %{
            "port" => Zoi.integer() |> Zoi.min(1)
          },
          coerce: true
        )

      assert_raise RuntimeError, ~r/Invalid configuration/, fn ->
        ConfigValidator.validate!(app, schema)
      end
    end
  end

  describe "from_spec/1" do
    test "builds schema from spec" do
      spec = %{
        "port" => {:integer, min: 1, max: 65535, required: true},
        "host" => {:string, []},
        "debug" => {:boolean, []}
      }

      schema = ConfigValidator.from_spec(spec)

      # Test with valid data
      assert {:ok, _} =
               Zoi.parse(schema, %{
                 "port" => 8080,
                 "host" => "localhost",
                 "debug" => true
               })
    end

    test "builds enum schema" do
      spec = %{
        "log_level" => {:enum, values: ["debug", "info", "warn", "error"]}
      }

      schema = ConfigValidator.from_spec(spec)

      assert {:ok, validated} = Zoi.parse(schema, %{"log_level" => "info"})
      assert validated["log_level"] == "info"

      assert {:error, _} = Zoi.parse(schema, %{"log_level" => "invalid"})
    end
  end
end
