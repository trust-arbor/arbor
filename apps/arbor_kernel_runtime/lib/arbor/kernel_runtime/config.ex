defmodule Arbor.KernelRuntime.Config do
  @moduledoc """
  Owner-scoped application env for KernelRuntime.

  Values live under `config :arbor_kernel, kernel_runtime: [...]`. The
  closed start profile defaults to `:full`.
  """

  @namespace :kernel_runtime

  @doc """
  Closed start profile (`:full` or `:activation_only`).

  Missing defaults to `:full`. Unknown or malformed values are returned
  as configured so `Application.start` can fail closed.
  """
  @spec start_profile() :: term()
  def start_profile, do: get(:start_profile, :full)

  @required_boot_profile_keys [
    :expected_payload_digests,
    :expected_profile_id,
    :expected_release_id,
    :expected_revocation_input_id,
    :manifest_bytes,
    :min_boot_epoch,
    :revoked_platform_key_ids,
    :revoked_signer_key_ids,
    :signature_bytes,
    :trusted_signers
  ]

  # P1A-1-consistent cardinality and byte ceilings. Recovery hashes this
  # map without calling Envelope, so Config must refuse unbounded input.
  @max_boot_profile_bytes 16_384
  @max_list 32
  @max_id_bytes 128
  @max_digest_bytes 64
  @max_epoch 1_000_000_000
  @trusted_signer_keys ["key_id", "public_key", "signer_id"]
  @payload_digest_keys ["id", "sha256"]

  @doc """
  Closed installer/OS stage-zero boot-profile input.

  Admits atom-keyed keyword lists or maps under `:boot_profile`. Nested
  trusted-signer and payload maps stay string-keyed. `:now` is not a
  contract key. Missing configuration is `:absent`. Production supplies
  the same keys from installer-produced sys.config.
  """
  @spec boot_profile_stage_zero() :: {:ok, map()} | {:error, :absent | :malformed_stage_zero}
  def boot_profile_stage_zero do
    case Application.fetch_env(:arbor_kernel, @namespace) do
      :error ->
        {:error, :absent}

      {:ok, config} ->
        admit_boot_profile(fetch_boot_profile(config))
    end
  end

  defp get(key, default) when is_atom(key) do
    case Application.fetch_env(:arbor_kernel, @namespace) do
      :error -> default
      {:ok, config} -> fetch_namespace_key(config, key, default)
    end
  end

  defp fetch_namespace_key(config, key, default) when is_list(config) do
    if Keyword.keyword?(config) do
      Keyword.get(config, key, default)
    else
      raise ArgumentError, malformed_namespace_message()
    end
  end

  defp fetch_namespace_key(%{__struct__: _}, _key, _default) do
    raise ArgumentError, malformed_namespace_message()
  end

  defp fetch_namespace_key(%{} = config, key, default) do
    Map.get(config, key, default)
  end

  defp fetch_namespace_key(_config, _key, _default) do
    raise ArgumentError, malformed_namespace_message()
  end

  defp malformed_namespace_message do
    "Arbor.KernelRuntime.Config malformed :arbor_kernel :kernel_runtime namespace"
  end

  defp fetch_boot_profile(config) when is_list(config) do
    if Keyword.keyword?(config) do
      if Keyword.has_key?(config, :boot_profile) do
        {:ok, Keyword.fetch!(config, :boot_profile)}
      else
        :absent
      end
    else
      {:error, :malformed_stage_zero}
    end
  end

  defp fetch_boot_profile(%{__struct__: _}) do
    {:error, :malformed_stage_zero}
  end

  defp fetch_boot_profile(%{} = config) do
    if Map.has_key?(config, :boot_profile) do
      {:ok, Map.fetch!(config, :boot_profile)}
    else
      :absent
    end
  end

  defp fetch_boot_profile(_config) do
    {:error, :malformed_stage_zero}
  end

  defp admit_boot_profile(:absent), do: {:error, :absent}
  defp admit_boot_profile({:error, :malformed_stage_zero} = error), do: error

  defp admit_boot_profile({:ok, value}) do
    case normalize_boot_profile(value) do
      {:ok, map} -> admit_boot_profile_map(map)
      :error -> {:error, :malformed_stage_zero}
    end
  end

  defp normalize_boot_profile(list) when is_list(list) do
    if Keyword.keyword?(list) do
      keys = Keyword.keys(list)
      map = Map.new(list)

      if length(keys) == map_size(map) do
        {:ok, map}
      else
        :error
      end
    else
      :error
    end
  end

  defp normalize_boot_profile(%{__struct__: _}), do: :error

  defp normalize_boot_profile(%{} = map) do
    if Enum.all?(Map.keys(map), &is_atom/1) do
      {:ok, map}
    else
      :error
    end
  end

  defp normalize_boot_profile(_), do: :error

  defp admit_boot_profile_map(map) do
    actual = Map.keys(map)

    cond do
      Enum.sort(actual) != Enum.sort(@required_boot_profile_keys) ->
        {:error, :malformed_stage_zero}

      true ->
        with :ok <- bounded_bytes(map[:manifest_bytes]),
             :ok <- bounded_bytes(map[:signature_bytes]),
             :ok <- binary_id(map[:expected_release_id]),
             :ok <- binary_id(map[:expected_profile_id]),
             :ok <- binary_id(map[:expected_revocation_input_id]),
             :ok <- positive_epoch(map[:min_boot_epoch]),
             :ok <- binary_list(map[:revoked_signer_key_ids]),
             :ok <- binary_list(map[:revoked_platform_key_ids]),
             :ok <- trusted_signers(map[:trusted_signers]),
             :ok <- payload_digests(map[:expected_payload_digests]) do
          {:ok,
           %{
             "manifest_bytes" => map[:manifest_bytes],
             "signature_bytes" => map[:signature_bytes],
             "trusted_signers" => map[:trusted_signers],
             "expected_release_id" => map[:expected_release_id],
             "expected_profile_id" => map[:expected_profile_id],
             "expected_revocation_input_id" => map[:expected_revocation_input_id],
             "expected_payload_digests" => map[:expected_payload_digests],
             "min_boot_epoch" => map[:min_boot_epoch],
             "revoked_signer_key_ids" => map[:revoked_signer_key_ids],
             "revoked_platform_key_ids" => map[:revoked_platform_key_ids]
           }}
        else
          :error -> {:error, :malformed_stage_zero}
        end
    end
  end

  defp bounded_bytes(bytes) when is_binary(bytes) do
    bounded_string(bytes, @max_boot_profile_bytes)
  end

  defp bounded_bytes(_), do: :error

  defp binary_id(value), do: bounded_string(value, @max_id_bytes)

  defp positive_epoch(value) when is_integer(value) and value >= 1 and value <= @max_epoch do
    :ok
  end

  defp positive_epoch(_), do: :error

  defp binary_list(list) do
    case take_proper_list(list, @max_list) do
      {:ok, items} ->
        Enum.reduce_while(items, :ok, fn item, :ok ->
          if bounded_string(item, @max_digest_bytes) == :ok do
            {:cont, :ok}
          else
            {:halt, :error}
          end
        end)

      :error ->
        :error
    end
  end

  defp trusted_signers(list) do
    case take_proper_list(list, @max_list) do
      {:ok, items} ->
        Enum.reduce_while(items, :ok, fn item, :ok ->
          if trusted_signer(item) == :ok do
            {:cont, :ok}
          else
            {:halt, :error}
          end
        end)

      :error ->
        :error
    end
  end

  defp trusted_signer(map) do
    with :ok <- exact_string_keys(map, @trusted_signer_keys),
         :ok <- bounded_string(map["signer_id"], @max_id_bytes),
         :ok <- bounded_string(map["key_id"], @max_digest_bytes) do
      bounded_string(map["public_key"], @max_digest_bytes)
    end
  end

  defp payload_digests(list) do
    case take_proper_list(list, @max_list) do
      {:ok, []} ->
        :error

      {:ok, items} ->
        Enum.reduce_while(items, :ok, fn item, :ok ->
          if payload_digest(item) == :ok do
            {:cont, :ok}
          else
            {:halt, :error}
          end
        end)

      :error ->
        :error
    end
  end

  defp payload_digest(map) do
    with :ok <- exact_string_keys(map, @payload_digest_keys),
         :ok <- bounded_string(map["id"], @max_id_bytes) do
      bounded_string(map["sha256"], @max_digest_bytes)
    end
  end

  defp exact_string_keys(map, keys) when is_map(map) and not is_struct(map) do
    actual = Map.keys(map)

    if Enum.all?(actual, &is_binary/1) and Enum.sort(actual) == Enum.sort(keys) do
      :ok
    else
      :error
    end
  end

  defp exact_string_keys(_, _), do: :error

  defp bounded_string(value, max) when is_binary(value) and max > 0 do
    size = byte_size(value)

    if size >= 1 and size <= max do
      :ok
    else
      :error
    end
  end

  defp bounded_string(_, _), do: :error

  defp take_proper_list(list, max) when is_list(list) and is_integer(max) and max >= 0 do
    take_proper_list(list, max, 0, [])
  end

  defp take_proper_list(_, _), do: :error

  defp take_proper_list([], _max, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp take_proper_list([head | tail], max, count, acc) do
    if count >= max do
      :error
    else
      take_proper_list(tail, max, count + 1, [head | acc])
    end
  end

  defp take_proper_list(_, _, _, _), do: :error
end
