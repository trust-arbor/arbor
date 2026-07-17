defmodule Arbor.Shell.RuntimeConfigLoader do
  @moduledoc false

  alias Arbor.Shell.Config
  alias Arbor.Shell.TrustedPath
  alias Arbor.Shell.TrustedPath.Identity

  @max_document_bytes 64 * 1024
  @read_chunk_bytes 8 * 1024
  @top_level_keys MapSet.new([
                    "apple_container",
                    "linux_dependency_baseline",
                    "image_policy",
                    "unit_journal_path"
                  ])
  @config_keys [
    :apple_container,
    :linux_dependency_baseline,
    :apple_container_image_policy,
    :apple_container_unit_journal_path
  ]

  @type config :: %{
          apple_container: map(),
          linux_dependency_baseline: map(),
          apple_container_image_policy: map(),
          apple_container_unit_journal_path: String.t()
        }

  @spec load(String.t()) :: {:ok, config()} | {:error, atom() | tuple()}
  def load(path), do: load_with_trusted_path(path, TrustedPath)

  # Test-only injection point. Production callers use load/1, which is always
  # bound to Arbor.Shell.TrustedPath.
  @doc false
  @spec load_with_trusted_path(String.t(), module()) ::
          {:ok, config()} | {:error, atom() | tuple()}
  def load_with_trusted_path(path, trusted_path) when is_atom(trusted_path) do
    with {:ok, canonical_path} <- validate_locator(path, trusted_path),
         :ok <- reject_obviously_oversized(canonical_path),
         {:ok, identity} <- pin_file(canonical_path, trusted_path),
         :ok <- enforce_document_size(identity),
         {:ok, contents} <- read_bounded(canonical_path),
         :ok <- verify_file(identity, trusted_path),
         {:ok, values} <- decode_document(contents) do
      {:ok, values}
    end
  end

  defp validate_locator(path, trusted_path) when is_binary(path) do
    cond do
      String.trim(path) == "" ->
        {:error, :config_locator_blank}

      true ->
        with {:ok, path} <- Config.validate_unit_journal_path(path),
             {:ok, canonical} <- trusted_path.canonicalize_absolute(path) do
          if canonical == path,
            do: {:ok, canonical},
            else: {:error, :config_locator_noncanonical}
        else
          {:error, :relative_path} -> {:error, :config_locator_relative}
          {:error, :path_not_found} -> {:error, :config_file_missing}
          {:error, _reason} -> {:error, :config_locator_noncanonical}
        end
    end
  end

  defp validate_locator(_path, _trusted_path), do: {:error, :config_locator_malformed}

  defp pin_file(path, trusted_path) do
    case trusted_path.pin_root_owned_regular_file(path) do
      {:ok, identity} -> {:ok, identity}
      {:error, :path_not_found} -> {:error, :config_file_missing}
      {:error, :not_a_regular_file} -> {:error, :config_file_not_regular}
      {:error, :untrusted_path} -> {:error, :config_file_untrusted}
      {:error, :file_too_large} -> {:error, :config_file_too_large}
      {:error, _reason} -> {:error, :config_file_untrusted}
    end
  end

  defp reject_obviously_oversized(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size}} when size > @max_document_bytes ->
        {:error, :config_file_too_large}

      {:ok, _stat} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp enforce_document_size(%Identity{type: :regular, size: size})
       when is_integer(size) and size > @max_document_bytes,
       do: {:error, :config_file_too_large}

  defp enforce_document_size(%Identity{type: :regular, size: size})
       when is_integer(size) and size >= 0 and size <= @max_document_bytes,
       do: :ok

  defp enforce_document_size(_identity), do: {:error, :config_file_untrusted}

  defp verify_file(identity, trusted_path) do
    case trusted_path.verify_pinned(identity) do
      :ok -> :ok
      {:error, _reason} -> {:error, :config_file_changed}
      _other -> {:error, :config_file_changed}
    end
  end

  defp read_bounded(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, io} ->
        try do
          read_chunks(io, [], 0)
        after
          :file.close(io)
        end

      {:error, _reason} ->
        {:error, :config_file_unreadable}
    end
  end

  defp read_chunks(io, chunks, size) do
    case :file.read(io, @read_chunk_bytes) do
      :eof ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:ok, chunk} ->
        new_size = size + byte_size(chunk)

        if new_size > @max_document_bytes do
          {:error, :config_file_too_large}
        else
          read_chunks(io, [chunk | chunks], new_size)
        end

      {:error, _reason} ->
        {:error, :config_file_unreadable}
    end
  end

  defp decode_document(contents) do
    case Jason.decode(contents, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{} = document} -> materialize_object(document, true)
      {:ok, _other} -> {:error, :config_schema_malformed}
      {:error, _reason} -> {:error, :config_file_invalid_json}
    end
  end

  defp materialize_object(%Jason.OrderedObject{values: values}, top_level?) do
    with :ok <- reject_duplicate_keys(values),
         {:ok, materialized} <- materialize_pairs(values) do
      if top_level?, do: validate_top_level(materialized), else: {:ok, materialized}
    end
  end

  defp materialize_pairs(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case materialize(value) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp materialize(%Jason.OrderedObject{} = object), do: materialize_object(object, false)

  defp materialize(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case materialize(value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp materialize(value), do: {:ok, value}

  defp reject_duplicate_keys(values) do
    keys = Enum.map(values, &elem(&1, 0))

    if length(keys) == MapSet.size(MapSet.new(keys)) do
      :ok
    else
      {:error, :config_schema_duplicate_key}
    end
  end

  defp validate_top_level(document) do
    keys = Map.keys(document) |> MapSet.new()

    cond do
      keys != @top_level_keys ->
        if MapSet.subset?(@top_level_keys, keys),
          do: {:error, :config_schema_extra_key},
          else: {:error, :config_schema_missing_key}

      true ->
        validate_nested(document)
    end
  end

  defp validate_nested(document) do
    values = %{
      :apple_container => Map.fetch!(document, "apple_container"),
      :linux_dependency_baseline => Map.fetch!(document, "linux_dependency_baseline"),
      :apple_container_image_policy => Map.fetch!(document, "image_policy"),
      :apple_container_unit_journal_path => Map.fetch!(document, "unit_journal_path")
    }

    validate_with_config(values)
  end

  defp validate_with_config(values) do
    previous =
      Map.new(@config_keys, fn key ->
        {key, Application.get_env(:arbor_shell, key)}
      end)

    try do
      Enum.each(values, fn {key, value} -> Application.put_env(:arbor_shell, key, value) end)

      with {:ok, apple_container} <- Config.apple_container(),
           {:ok, linux_dependency_baseline} <- Config.linux_dependency_baseline(),
           {:ok, image_policy} <- Config.apple_container_image_policy(),
           {:ok, unit_journal_path} <- Config.apple_container_unit_journal_path() do
        {:ok,
         %{
           apple_container: apple_container,
           linux_dependency_baseline: linux_dependency_baseline,
           apple_container_image_policy: image_policy,
           apple_container_unit_journal_path: unit_journal_path
         }}
      else
        {:error, reason} -> {:error, {:config_nested_malformed, reason}}
      end
    after
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:arbor_shell, key)
        {key, value} -> Application.put_env(:arbor_shell, key, value)
      end)
    end
  end
end
