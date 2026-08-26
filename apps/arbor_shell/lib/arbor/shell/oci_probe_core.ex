defmodule Arbor.Shell.OciProbeCore do
  @moduledoc """
  Pure OCI/Podman inspect-output projection core.

  Accepts bounded raw `podman image inspect` JSON plus host architecture and
  returns inspect evidence for `OciAdmissionCore`. Performs no IO, process
  execution, filesystem access, environment reads, Application config reads,
  GenServer calls, ETS, time, randomness, or logging.
  """

  @logical_request_keys [:system_architecture, :image_inspect_json]
  @allowed_request_keys MapSet.new(
                          @logical_request_keys ++
                            Enum.map(@logical_request_keys, &Atom.to_string/1)
                        )

  @max_arch_bytes 128
  @max_image_json_bytes 262_144
  @max_map_keys 64
  @max_label_keys 32
  @max_label_key_bytes 256
  @max_label_value_bytes 1_024
  @max_status_bytes 64

  @digest_re ~r/\Asha256:[0-9a-f]{64}\z/
  @linux_arch_re ~r/\A(?:x86_64|amd64|aarch64|arm64)(?:-[\w.-]*)?-linux(?:-[\w.-]*)?\z/
  @linux_uname_re ~r/\A(?:x86_64|amd64|aarch64|arm64)\z/

  @type projection :: %{
          host_platform: %{os: String.t(), architecture: String.t()},
          guest_platform: String.t(),
          inspect: map()
        }

  @doc """
  Project bounded raw probe outputs into inspect evidence for admission.
  """
  @spec project(term()) :: {:ok, projection()} | {:error, term()}
  def project(input) when is_map(input) do
    with :ok <-
           validate_closed_keys(input, @allowed_request_keys, @logical_request_keys, :request),
         {:ok, arch} <-
           require_bounded_utf8_field(
             input,
             :system_architecture,
             @max_arch_bytes,
             :missing_system_architecture,
             :invalid_system_architecture,
             :system_architecture_too_long
           ),
         {:ok, host_architecture, guest_platform} <- parse_system_architecture(arch),
         {:ok, inspect_json} <-
           require_bounded_binary_field(
             input,
             :image_inspect_json,
             @max_image_json_bytes,
             :missing_image_inspect_json,
             :invalid_image_inspect_json,
             :image_inspect_json_too_long
           ),
         {:ok, inspect} <- parse_image_inspect_json(inspect_json) do
      {:ok,
       %{
         host_platform: %{os: "linux", architecture: host_architecture},
         guest_platform: guest_platform,
         inspect: inspect
       }}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  def project(_input), do: {:error, :invalid_request}

  @doc """
  JSON-clean view of a projection (no raw inspect bytes).
  """
  @spec show(projection()) :: map()
  def show(%{host_platform: host, guest_platform: guest_platform, inspect: inspect}) do
    %{
      "host_platform" => %{
        "os" => host.os,
        "architecture" => host.architecture
      },
      "guest_platform" => guest_platform,
      "inspect" => inspect
    }
  end

  defp parse_system_architecture(arch) do
    trimmed =
      arch
      |> to_string()
      |> String.trim()
      |> String.downcase()

    cond do
      String.contains?(trimmed, "darwin") or String.contains?(trimmed, "apple") ->
        {:error, :unsupported_host_os}

      String.contains?(trimmed, "freebsd") or String.contains?(trimmed, "windows") ->
        {:error, :unsupported_host_os}

      Regex.match?(@linux_uname_re, trimmed) ->
        map_host_architecture(trimmed)

      Regex.match?(@linux_arch_re, trimmed) ->
        map_host_architecture(hd(String.split(trimmed, "-", parts: 2)))

      String.contains?(trimmed, "linux") ->
        cond do
          String.starts_with?(trimmed, "x86_64") or String.starts_with?(trimmed, "amd64") ->
            map_host_architecture("x86_64")

          String.starts_with?(trimmed, "aarch64") or String.starts_with?(trimmed, "arm64") ->
            map_host_architecture("aarch64")

          true ->
            {:error, :unsupported_system_architecture}
        end

      true ->
        {:error, :unsupported_host_os}
    end
  end

  defp map_host_architecture(arch) when arch in ["x86_64", "amd64"],
    do: {:ok, "x86_64", "linux/amd64"}

  defp map_host_architecture(arch) when arch in ["aarch64", "arm64"],
    do: {:ok, "arm64", "linux/arm64"}

  defp map_host_architecture(_arch), do: {:error, :unsupported_system_architecture}

  defp parse_image_inspect_json(raw) do
    with :ok <- require_valid_utf8(raw),
         {:ok, decoded} <- decode_json(raw, :invalid_image_inspect_json),
         {:ok, resource} <- unwrap_inspect_resource(decoded),
         :ok <- require_map(resource, :invalid_image_inspect_json),
         :ok <- require_map_key_budget(resource),
         {:ok, digest} <- fetch_digest(resource),
         {:ok, labels} <- fetch_labels(resource),
         {:ok, architecture} <- fetch_inspect_architecture(resource),
         {:ok, os} <- fetch_inspect_os(resource) do
      inspect_map = %{
        "Digest" => digest,
        "Labels" => labels,
        "Architecture" => architecture,
        "Os" => os
      }

      {:ok, put_optional_id(inspect_map, resource)}
    end
  end

  defp put_optional_id(inspect_map, resource) do
    id = json_get(resource, "Id") || json_get(resource, "id")

    case admit_optional_sha256(id) do
      {:ok, id} -> Map.put(inspect_map, "Id", id)
      :skip -> inspect_map
    end
  end

  defp admit_optional_sha256(value) when is_binary(value) do
    if Regex.match?(@digest_re, value), do: {:ok, value}, else: :skip
  end

  defp admit_optional_sha256(_value), do: :skip

  defp unwrap_inspect_resource(resource) when is_map(resource), do: {:ok, resource}

  defp unwrap_inspect_resource([resource]) when is_map(resource), do: {:ok, resource}

  defp unwrap_inspect_resource(list) when is_list(list) do
    if length(list) == 1 and is_map(hd(list)) do
      {:ok, hd(list)}
    else
      {:error, :invalid_image_inspect_array}
    end
  end

  defp unwrap_inspect_resource(_), do: {:error, :invalid_image_inspect_json}

  defp fetch_digest(resource) do
    digest = json_get(resource, "Digest") || json_get(resource, "digest")
    id = json_get(resource, "Id") || json_get(resource, "id")

    cond do
      is_binary(digest) ->
        admit_sha256_digest(digest)

      is_binary(id) ->
        admit_sha256_digest(id)

      true ->
        {:error, :missing_inspect_digest}
    end
  end

  defp admit_sha256_digest(value) do
    if Regex.match?(@digest_re, value),
      do: {:ok, value},
      else: {:error, :inspect_digest_not_sha256}
  end

  defp fetch_labels(resource) do
    case json_get(resource, "Labels") || json_get(resource, "labels") do
      nil ->
        {:ok, %{}}

      labels when is_map(labels) ->
        project_labels_map(labels)

      _other ->
        {:error, :invalid_image_labels}
    end
  end

  defp project_labels_map(labels) when is_map(labels) do
    if map_size(labels) > @max_label_keys do
      {:error, :too_many_image_labels}
    else
      Enum.reduce_while(labels, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        key = stringify_label_key(key)

        if is_binary(key) and is_binary(value) do
          with :ok <- bounded_string(key, @max_label_key_bytes, :image_label_key_too_long),
               :ok <- bounded_string(value, @max_label_value_bytes, :image_label_value_too_long),
               :ok <- require_valid_utf8(key),
               :ok <- require_valid_utf8(value),
               :ok <- reject_control_char(key, :unsafe_image_label_key),
               :ok <- reject_control_char(value, :unsafe_image_label_value) do
            {:cont, {:ok, Map.put(acc, key, value)}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:halt, {:error, :invalid_image_labels}}
        end
      end)
    end
  end

  defp stringify_label_key(key) when is_binary(key), do: key
  defp stringify_label_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_label_key(_key), do: nil

  defp fetch_inspect_architecture(resource) do
    case json_get(resource, "Architecture") || json_get(resource, "architecture") do
      value when is_binary(value) ->
        with :ok <- bounded_string(value, @max_status_bytes, :inspect_architecture_too_long),
             :ok <- require_valid_utf8(value),
             :ok <- reject_control_char(value, :unsafe_inspect_architecture) do
          {:ok, value}
        end

      nil ->
        {:error, :missing_inspect_architecture}

      _other ->
        {:error, :invalid_inspect_architecture}
    end
  end

  defp fetch_inspect_os(resource) do
    case json_get(resource, "Os") || json_get(resource, "os") do
      "linux" ->
        {:ok, "linux"}

      value when is_binary(value) ->
        {:error, :inspect_os_not_linux}

      nil ->
        {:error, :missing_inspect_os}

      _other ->
        {:error, :invalid_inspect_os}
    end
  end

  defp json_get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> json_get_atom_alias(map, key)
    end
  end

  defp json_get_atom_alias(map, "Digest"), do: Map.get(map, :Digest)
  defp json_get_atom_alias(map, "digest"), do: Map.get(map, :digest)
  defp json_get_atom_alias(map, "Id"), do: Map.get(map, :Id)
  defp json_get_atom_alias(map, "id"), do: Map.get(map, :id)
  defp json_get_atom_alias(map, "Labels"), do: Map.get(map, :Labels)
  defp json_get_atom_alias(map, "labels"), do: Map.get(map, :labels)
  defp json_get_atom_alias(map, "Architecture"), do: Map.get(map, :Architecture)
  defp json_get_atom_alias(map, "architecture"), do: Map.get(map, :architecture)
  defp json_get_atom_alias(map, "Os"), do: Map.get(map, :Os)
  defp json_get_atom_alias(map, "os"), do: Map.get(map, :os)
  defp json_get_atom_alias(_map, _key), do: nil

  defp validate_closed_keys(map, allowed, logical, scope) when is_map(map) do
    keys = Map.keys(map)

    cond do
      map_size(map) > @max_map_keys ->
        {:error, :map_too_large}

      Enum.any?(keys, &(not MapSet.member?(allowed, &1))) ->
        {:error, {:unsupported_keys, scope}}

      duplicate_aliases?(keys, logical) ->
        {:error, {:duplicate_key_alias, scope}}

      true ->
        :ok
    end
  end

  defp duplicate_aliases?(keys, logical) do
    key_set = MapSet.new(keys)

    Enum.any?(logical, fn atom_key ->
      MapSet.member?(key_set, atom_key) and MapSet.member?(key_set, Atom.to_string(atom_key))
    end)
  end

  defp require_bounded_utf8_field(map, key, max, missing, invalid, too_long) do
    case get_field(map, key) do
      nil ->
        {:error, missing}

      value when is_list(value) ->
        require_bounded_utf8_field(
          Map.put(map, key, List.to_string(value)),
          key,
          max,
          missing,
          invalid,
          too_long
        )

      value when is_binary(value) ->
        with :ok <- require_valid_utf8(value),
             :ok <- bounded_string(value, max, too_long) do
          if value == "", do: {:error, missing}, else: {:ok, value}
        end

      _other ->
        {:error, invalid}
    end
  end

  defp require_bounded_binary_field(map, key, max, missing, invalid, too_long) do
    case get_field(map, key) do
      nil ->
        {:error, missing}

      value when is_binary(value) ->
        if byte_size(value) > max, do: {:error, too_long}, else: {:ok, value}

      _other ->
        {:error, invalid}
    end
  end

  defp require_map(value, _error) when is_map(value), do: :ok
  defp require_map(_value, error), do: {:error, error}

  defp require_map_key_budget(map) when is_map(map) do
    if map_size(map) > @max_map_keys, do: {:error, :map_too_large}, else: :ok
  end

  defp decode_json(raw, invalid) do
    case Jason.decode(raw) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, invalid}
    end
  end

  defp bounded_string(value, max, too_long) when is_binary(value) do
    if byte_size(value) > max, do: {:error, too_long}, else: :ok
  end

  defp require_valid_utf8(value) when is_binary(value) do
    if String.valid?(value), do: :ok, else: {:error, :invalid_utf8}
  end

  defp reject_control_char(value, error) when is_binary(value) do
    if Regex.match?(~r/[\x00-\x1F\x7F]/u, value), do: {:error, error}, else: :ok
  end

  defp get_field(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
