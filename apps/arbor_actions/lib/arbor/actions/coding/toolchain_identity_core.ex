defmodule Arbor.Actions.Coding.ToolchainIdentityCore do
  @moduledoc """
  Pure construction and canonicalization for coding toolchain identity.

  The facade supplies observations from the loaded runtime. This module only
  validates bounded JSON-clean values and binds a deterministic digest.
  """

  @schema_version 1
  @max_path_bytes 4_096
  @max_text_bytes 128
  @max_observation_bytes 16_384
  @digest_fields ~w(
    schema_version platform architecture otp_release elixir_version
    mix_wrapper_path runtime_roots
  )
  @runtime_root_fields ~w(erlang_root elixir_root)

  @type observation :: %{required(String.t()) => term()}

  @doc "Return the accepted toolchain identity schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Validate observations and return a bounded JSON-clean identity map."
  @spec new(map()) :: {:ok, map()} | {:error, :invalid_toolchain_identity}
  def new(observation) when is_map(observation) and not is_struct(observation) do
    with :ok <- validate_observation(observation),
         canonical = canonical_json(observation),
         true <- byte_size(canonical) <= @max_observation_bytes do
      digest = sha256(canonical)
      {:ok, Map.put(observation, "identity_digest", digest)}
    else
      _ -> {:error, :invalid_toolchain_identity}
    end
  rescue
    _ -> {:error, :invalid_toolchain_identity}
  catch
    _, _ -> {:error, :invalid_toolchain_identity}
  end

  def new(_observation), do: {:error, :invalid_toolchain_identity}

  @doc false
  @spec canonical_json(map()) :: String.t()
  def canonical_json(value), do: IO.iodata_to_binary(do_canonical_json(value))

  defp validate_observation(observation) do
    with :ok <- validate_exact_keys(observation, @digest_fields),
         true <- observation["schema_version"] == @schema_version,
         :ok <- validate_text(observation["platform"], @max_text_bytes),
         :ok <- validate_text(observation["architecture"], @max_text_bytes),
         :ok <- validate_text(observation["otp_release"], @max_text_bytes),
         :ok <- validate_text(observation["elixir_version"], @max_text_bytes),
         :ok <- validate_path(observation["mix_wrapper_path"]),
         :ok <- validate_runtime_roots(observation["runtime_roots"]),
         true <- json_clean?(observation) do
      :ok
    else
      _ -> {:error, :invalid_toolchain_identity}
    end
  end

  defp validate_runtime_roots(roots) when is_map(roots) and not is_struct(roots) do
    with :ok <- validate_exact_keys(roots, @runtime_root_fields),
         :ok <- validate_path(roots["erlang_root"]),
         :ok <- validate_path(roots["elixir_root"]) do
      :ok
    else
      _ -> {:error, :invalid_toolchain_identity}
    end
  end

  defp validate_runtime_roots(_roots), do: {:error, :invalid_toolchain_identity}

  defp validate_exact_keys(map, expected) do
    keys = Map.keys(map)

    if Enum.all?(keys, &is_binary/1) and Enum.sort(keys) == Enum.sort(expected),
      do: :ok,
      else: {:error, :invalid_toolchain_identity}
  end

  defp validate_path(path) do
    with :ok <- validate_text(path, @max_path_bytes),
         true <- Path.type(path) == :absolute do
      :ok
    else
      _ -> {:error, :invalid_toolchain_identity}
    end
  end

  defp validate_text(value, max_bytes)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes do
    if String.valid?(value) and printable?(value),
      do: :ok,
      else: {:error, :invalid_toolchain_identity}
  end

  defp validate_text(_value, _max_bytes), do: {:error, :invalid_toolchain_identity}

  defp printable?(value) do
    value
    |> String.to_charlist()
    |> Enum.all?(&(&1 >= 0x20 and &1 != 0x7F))
  end

  defp json_clean?(map) when is_map(map) and not is_struct(map) do
    Enum.all?(map, fn
      {key, value} when is_binary(key) -> json_clean?(value)
      _ -> false
    end)
  end

  defp json_clean?(value) when is_list(value), do: Enum.all?(value, &json_clean?/1)

  defp json_clean?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_clean?(_value), do: false

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp do_canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, item} -> [Jason.encode!(key), ":", do_canonical_json(item)] end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp do_canonical_json(value) when is_list(value),
    do: ["[", Enum.intersperse(Enum.map(value, &do_canonical_json/1), ","), "]"]

  defp do_canonical_json(value), do: Jason.encode!(value)
end
