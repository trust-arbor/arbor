defmodule Arbor.Common.ConfigValidator do
  @moduledoc """
  Validate Application config at startup using Zoi schemas.

  This module provides utilities for validating application configuration
  at startup time, failing fast if configuration is invalid rather than
  encountering runtime errors later.

  ## Usage

  In your Application.start/2:

      def start(_type, _args) do
        Arbor.Common.ConfigValidator.validate!(:my_app, MyApp.Config.schema())
        # ... rest of startup
      end

  Or with inline schema:

      def start(_type, _args) do
        Arbor.Common.ConfigValidator.validate!(:my_app, %{
          "port" => Zoi.integer() |> Zoi.min(1) |> Zoi.max(65535),
          "host" => Zoi.string() |> Zoi.optional()
        })
        # ... rest of startup
      end

  ## Schema Format

  Schemas should be Zoi map schemas with string keys matching the config
  key names (as they appear in config.exs).

  ## Error Handling

  On validation failure, raises a descriptive error that includes:
  - The application name
  - The specific fields that failed
  - The validation error messages

  This ensures configuration problems are caught immediately at startup
  rather than causing mysterious runtime failures.
  """

  require Logger

  @doc """
  Validate application config against a Zoi schema.

  Raises `RuntimeError` on validation failure with a descriptive message.

  ## Parameters

  - `app` - The application atom (e.g., `:arbor_ai`)
  - `schema` - A Zoi map schema

  ## Examples

      # Will raise if port is not configured or out of range
      ConfigValidator.validate!(:my_app, %{
        "port" => Zoi.integer() |> Zoi.min(1) |> Zoi.max(65535)
      })

  """
  @spec validate!(atom(), map()) :: :ok
  def validate!(app, schema) when is_atom(app) do
    config = Application.get_all_env(app)

    # Convert config keyword list to map with string keys for Zoi
    config_map = config_to_map(config)

    case Zoi.parse(schema, config_map) do
      {:ok, _validated} ->
        :ok

      {:error, errors} ->
        error_msg = format_config_errors(app, errors)
        Logger.error(error_msg)
        raise error_msg
    end
  end

  @doc """
  Validate application config, returning a result tuple.

  Use this variant when you want to handle validation failures gracefully
  rather than crashing on startup.

  ## Parameters

  - `app` - The application atom
  - `schema` - A Zoi map schema

  ## Returns

  - `{:ok, validated_config}` on success
  - `{:error, errors}` on failure

  """
  @spec validate(atom(), map()) :: {:ok, map()} | {:error, [map()]}
  def validate(app, schema) when is_atom(app) do
    config = Application.get_all_env(app)
    config_map = config_to_map(config)

    case Zoi.parse(schema, config_map) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, errors} ->
        {:error, format_errors(errors)}
    end
  end

  @doc """
  Create a Zoi schema from a simple spec map.

  This is a convenience helper for building schemas from a declarative spec.
  Useful when you don't want to build Zoi schemas directly.

  ## Spec Format

  ```elixir
  %{
    "port" => {:integer, min: 1, max: 65535, required: true},
    "host" => {:string, default: "localhost"},
    "debug" => {:boolean, default: false},
    "log_level" => {:enum, values: [:debug, :info, :warn, :error], default: :info}
  }
  ```

  ## Supported Types

  - `:string` - String value
  - `:integer` - Integer value
  - `:float` - Float/number value
  - `:boolean` - Boolean value
  - `:atom` - Atom value (validates against existing atoms only)
  - `:enum` - One of specified values (requires `values:` option)

  ## Options

  - `:required` - Field is required (default: false)
  - `:default` - Default value if not set
  - `:min` - Minimum value (for integers/floats) or length (for strings)
  - `:max` - Maximum value or length
  - `:values` - Allowed values (for enum type)

  """
  @spec from_spec(map()) :: map()
  def from_spec(spec) when is_map(spec) do
    fields =
      Enum.map(spec, fn {key, {type, opts}} ->
        {to_string(key), build_field_schema(type, opts)}
      end)
      |> Map.new()

    Zoi.map(fields, coerce: true)
  end

  # Convert keyword list config to map with string keys
  defp config_to_map(config) when is_list(config) do
    Enum.reduce(config, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp build_field_schema(type, opts) do
    base = base_schema(type, opts)

    base
    |> maybe_add_min(opts[:min])
    |> maybe_add_max(opts[:max])
    |> maybe_add_optional(opts[:required])
  end

  defp base_schema(:string, _opts), do: Zoi.string()
  defp base_schema(:integer, _opts), do: Zoi.integer()
  defp base_schema(:float, _opts), do: Zoi.number()
  defp base_schema(:boolean, _opts), do: Zoi.boolean()
  defp base_schema(:atom, _opts), do: Zoi.atom()

  defp base_schema(:enum, opts) do
    values = Keyword.get(opts, :values, [])
    Zoi.enum(values)
  end

  defp maybe_add_min(schema, nil), do: schema
  defp maybe_add_min(schema, min), do: Zoi.min(schema, min)

  defp maybe_add_max(schema, nil), do: schema
  defp maybe_add_max(schema, max), do: Zoi.max(schema, max)

  defp maybe_add_optional(schema, true), do: schema
  defp maybe_add_optional(schema, _), do: Zoi.optional(schema)

  defp format_config_errors(app, errors) do
    error_lines =
      Enum.map(errors, fn error ->
        field = Enum.join(error.path, ".")
        "  - #{field}: #{error.message}"
      end)
      |> Enum.join("\n")

    """
    Invalid configuration for #{app}:

    #{error_lines}

    Please check your config/config.exs and ensure all required configuration is present.
    """
  end

  defp format_errors(errors) do
    Enum.map(errors, fn error ->
      %{
        field: Enum.join(error.path, "."),
        message: error.message
      }
    end)
  end
end
