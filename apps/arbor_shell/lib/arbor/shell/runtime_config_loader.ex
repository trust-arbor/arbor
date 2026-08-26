defmodule Arbor.Shell.RuntimeConfigLoader do
  @moduledoc false

  alias Arbor.Shell.Config
  alias Arbor.Shell.TrustedPath
  alias Arbor.Shell.TrustedPath.Identity

  @max_document_bytes 64 * 1024
  @read_chunk_bytes 8 * 1024
  @apple_top_level_keys MapSet.new([
                          "apple_container",
                          "linux_dependency_baseline",
                          "image_policy",
                          "unit_journal_path"
                        ])
  @oci_top_level_keys MapSet.new([
                        "runtime",
                        "linux_dependency_baseline",
                        "image_policy",
                        "unit_journal_path"
                      ])
  @apple_config_keys [
    :apple_container,
    :linux_dependency_baseline,
    :apple_container_image_policy,
    :apple_container_unit_journal_path
  ]
  @oci_config_keys [
    :linux_dependency_baseline,
    :oci_image_policy,
    :apple_container_unit_journal_path
  ]

  @type apple_config :: %{
          kind: :apple,
          apple_container: map(),
          linux_dependency_baseline: map(),
          apple_container_image_policy: map(),
          apple_container_unit_journal_path: String.t()
        }

  @type oci_config :: %{
          kind: :oci,
          linux_dependency_baseline: map(),
          oci_image_policy: map(),
          apple_container_unit_journal_path: String.t()
        }

  @type config :: apple_config() | oci_config()

  @spec load(String.t()) :: {:ok, config()} | {:error, atom() | tuple()}
  def load(path), do: load_with_trusted_path(path, TrustedPath, :root_owned)

  @doc """
  Load an operator-owned validation-runtime document.

  Uses `TrustedPath.pin_operator_owned_regular_file/1`. The Apple/root-owned
  `load/1` path is unchanged.
  """
  @spec load_operator_owned(String.t()) :: {:ok, config()} | {:error, atom() | tuple()}
  def load_operator_owned(path), do: load_with_trusted_path(path, TrustedPath, :operator_owned)

  @doc """
  Re-admit the boot-pinned document and return its `kind`.

  Selection is the TrustedPath-pinned document, not an Application-env kind
  atom. Missing locator/family or a pin/schema failure is a stable error so
  callers default to Apple Container.
  """
  @spec admit_kind() :: {:ok, :apple | :oci} | {:error, atom() | tuple()}
  def admit_kind, do: admit_kind_with_trusted_path(TrustedPath)

  # Test-only injection point. Production callers use admit_kind/0.
  @doc false
  @spec admit_kind_with_trusted_path(module()) ::
          {:ok, :apple | :oci} | {:error, atom() | tuple()}
  def admit_kind_with_trusted_path(trusted_path) when is_atom(trusted_path) do
    with {:ok, path} <- Config.validation_runtime_config_path(),
         {:ok, family} <- Config.validation_runtime_pin_family() do
      case load_with_trusted_path(path, trusted_path, family) do
        {:ok, %{kind: kind}} when kind in [:apple, :oci] -> {:ok, kind}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Test-only injection point. Production callers use load/1, which is always
  # bound to Arbor.Shell.TrustedPath.
  @doc false
  @spec load_with_trusted_path(String.t(), module()) ::
          {:ok, config()} | {:error, atom() | tuple()}
  def load_with_trusted_path(path, trusted_path) when is_atom(trusted_path) do
    load_with_trusted_path(path, trusted_path, :root_owned)
  end

  @doc false
  @spec load_with_trusted_path(String.t(), module(), :root_owned | :operator_owned) ::
          {:ok, config()} | {:error, atom() | tuple()}
  def load_with_trusted_path(path, trusted_path, pin_family)
      when is_atom(trusted_path) and pin_family in [:root_owned, :operator_owned] do
    with {:ok, canonical_path} <- validate_locator(path, trusted_path),
         :ok <- reject_obviously_oversized(canonical_path),
         {:ok, identity} <- pin_file(canonical_path, trusted_path, pin_family),
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

  defp pin_file(path, trusted_path, :root_owned) do
    map_pin_error(trusted_path.pin_root_owned_regular_file(path))
  end

  defp pin_file(path, trusted_path, :operator_owned) do
    map_pin_error(trusted_path.pin_operator_owned_regular_file(path))
  end

  defp map_pin_error(result) do
    case result do
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
    case Map.get(document, "runtime") do
      "oci" ->
        validate_oci_top_level(document)

      nil ->
        validate_apple_top_level(document)

      _other ->
        {:error, :config_schema_unknown_runtime}
    end
  end

  defp validate_apple_top_level(document) do
    keys = Map.keys(document) |> MapSet.new()

    cond do
      keys != @apple_top_level_keys ->
        if MapSet.subset?(@apple_top_level_keys, keys),
          do: {:error, :config_schema_extra_key},
          else: {:error, :config_schema_missing_key}

      true ->
        validate_apple_nested(document)
    end
  end

  defp validate_oci_top_level(document) do
    keys = Map.keys(document) |> MapSet.new()

    cond do
      Map.has_key?(document, "apple_container") ->
        {:error, :config_schema_apple_only_key}

      keys != @oci_top_level_keys ->
        if MapSet.subset?(@oci_top_level_keys, keys),
          do: {:error, :config_schema_extra_key},
          else: {:error, :config_schema_missing_key}

      true ->
        validate_oci_nested(document)
    end
  end

  defp validate_apple_nested(document) do
    values = %{
      apple_container: Map.fetch!(document, "apple_container"),
      linux_dependency_baseline: Map.fetch!(document, "linux_dependency_baseline"),
      apple_container_image_policy: Map.fetch!(document, "image_policy"),
      apple_container_unit_journal_path: Map.fetch!(document, "unit_journal_path")
    }

    validate_with_config(@apple_config_keys, values, :apple)
  end

  defp validate_oci_nested(document) do
    image_policy = Map.fetch!(document, "image_policy")

    with :ok <- reject_apple_only_image_policy_keys(image_policy) do
      values = %{
        linux_dependency_baseline: Map.fetch!(document, "linux_dependency_baseline"),
        oci_image_policy: image_policy,
        apple_container_unit_journal_path: Map.fetch!(document, "unit_journal_path")
      }

      validate_with_config(@oci_config_keys, values, :oci)
    end
  end

  defp reject_apple_only_image_policy_keys(image_policy) when is_map(image_policy) do
    if Map.has_key?(image_policy, "vminit_image") or
         Map.has_key?(image_policy, "vminit_manifest_digest") or
         Map.has_key?(image_policy, :vminit_image) or
         Map.has_key?(image_policy, :vminit_manifest_digest) do
      {:error, :config_schema_apple_only_key}
    else
      :ok
    end
  end

  defp reject_apple_only_image_policy_keys(_image_policy),
    do: {:error, {:config_nested_malformed, :oci_image_policy_config_malformed}}

  defp validate_with_config(config_keys, values, kind) do
    previous =
      Map.new(config_keys, fn key ->
        {key, Application.get_env(:arbor_shell, key)}
      end)

    try do
      Enum.each(values, fn {key, value} -> Application.put_env(:arbor_shell, key, value) end)
      finish_validated_config(kind)
    after
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:arbor_shell, key)
        {key, value} -> Application.put_env(:arbor_shell, key, value)
      end)
    end
  end

  defp finish_validated_config(:apple) do
    with {:ok, apple_container} <- Config.apple_container(),
         {:ok, linux_dependency_baseline} <- Config.linux_dependency_baseline(),
         {:ok, image_policy} <- Config.apple_container_image_policy(),
         {:ok, unit_journal_path} <- Config.apple_container_unit_journal_path() do
      {:ok,
       %{
         kind: :apple,
         apple_container: apple_container,
         linux_dependency_baseline: linux_dependency_baseline,
         apple_container_image_policy: image_policy,
         apple_container_unit_journal_path: unit_journal_path
       }}
    else
      {:error, reason} -> {:error, {:config_nested_malformed, reason}}
    end
  end

  defp finish_validated_config(:oci) do
    with {:ok, linux_dependency_baseline} <- Config.linux_dependency_baseline(),
         {:ok, image_policy} <- Config.oci_image_policy(),
         {:ok, unit_journal_path} <- Config.apple_container_unit_journal_path() do
      {:ok,
       %{
         kind: :oci,
         linux_dependency_baseline: linux_dependency_baseline,
         oci_image_policy: image_policy,
         apple_container_unit_journal_path: unit_journal_path
       }}
    else
      {:error, reason} -> {:error, {:config_nested_malformed, reason}}
    end
  end
end
