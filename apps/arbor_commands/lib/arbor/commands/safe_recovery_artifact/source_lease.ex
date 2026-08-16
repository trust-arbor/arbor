defmodule Arbor.Commands.SafeRecoveryArtifact.SourceLease do
  @moduledoc false

  alias Arbor.Commands.SafeRecoveryArtifact.{Encode, Overlay, SourcePolicy}

  @schema "arbor.packaging.safe_recovery_source_lease.v1"
  @lease_keys [
    "schema",
    "commit",
    "tree",
    "object_format",
    "reconstructed_tree",
    "build_inputs",
    "source_root",
    "overlay_path",
    "identity"
  ]
  @identity_keys ["path", "type", "device", "minor_device", "inode"]
  @oid_sha1 ~r/\A[0-9a-f]{40}\z/
  @oid_sha256 ~r/\A[0-9a-f]{64}\z/
  @max_path_bytes 4_096
  @max_inputs 5_000

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec build(map()) :: {:ok, map()} | {:error, term()}
  def build(attrs) when is_map(attrs), do: attrs |> lease_from_attrs() |> admit()

  def build(_attrs), do: {:error, :invalid_opts}

  @doc false
  @spec build_for_test(map()) :: {:ok, map()} | {:error, term()}
  def build_for_test(attrs) when is_map(attrs) do
    attrs
    |> lease_from_attrs()
    |> admit_for_test()
  end

  def build_for_test(_attrs), do: {:error, :invalid_opts}

  @spec admit(term()) :: {:ok, map()} | {:error, term()}
  def admit(lease) when is_map(lease) and not is_struct(lease),
    do: admit_lease(lease, :production)

  def admit(_lease), do: {:error, :invalid_opts}

  @doc false
  @spec admit_for_test(term()) :: {:ok, map()} | {:error, term()}
  def admit_for_test(lease) when is_map(lease) and not is_struct(lease),
    do: admit_lease(lease, :test)

  def admit_for_test(_lease), do: {:error, :invalid_opts}

  @spec owned_identity(map()) :: map()
  def owned_identity(%{"identity" => identity}) do
    %{
      path: identity["path"],
      type: :directory,
      device: identity["device"],
      minor_device: identity["minor_device"],
      inode: identity["inode"]
    }
  end

  @spec expected_source_root(String.t()) :: String.t()
  def expected_source_root(identity_path) when is_binary(identity_path),
    do: Path.join(identity_path, "source")

  @spec expected_overlay_path(String.t()) :: String.t()
  def expected_overlay_path(identity_path) when is_binary(identity_path),
    do: Path.join(identity_path, Overlay.staging_rel())

  defp lease_from_attrs(attrs) do
    %{
      "schema" => @schema,
      "commit" => attrs["commit"],
      "tree" => attrs["tree"],
      "object_format" => attrs["object_format"],
      "reconstructed_tree" => attrs["reconstructed_tree"],
      "build_inputs" => attrs["build_inputs"],
      "source_root" => attrs["source_root"],
      "overlay_path" => attrs["overlay_path"],
      "identity" => stringify_identity(attrs["identity"])
    }
  end

  defp admit_lease(lease, kind) do
    with :ok <- Encode.validate_closed_map(lease, @lease_keys),
         :ok <- exact_schema(lease),
         :ok <- admit_git(lease),
         {:ok, identity} <- admit_identity(lease["identity"]),
         :ok <- admit_bound_paths(lease, identity),
         :ok <- admit_build_inputs(lease["build_inputs"], kind) do
      {:ok, %{lease | "identity" => identity}}
    end
  end

  defp stringify_identity(%{
         path: path,
         type: :directory,
         device: device,
         minor_device: minor_device,
         inode: inode
       }) do
    %{
      "path" => path,
      "type" => "directory",
      "device" => device,
      "minor_device" => minor_device,
      "inode" => inode
    }
  end

  defp stringify_identity(identity) when is_map(identity), do: identity

  defp exact_schema(%{"schema" => @schema}), do: :ok
  defp exact_schema(_lease), do: {:error, :invalid_opts}

  defp admit_git(lease) do
    format = lease["object_format"]
    commit = lease["commit"]
    tree = lease["tree"]
    reconstructed = lease["reconstructed_tree"]

    regex =
      case format do
        "sha1" -> @oid_sha1
        "sha256" -> @oid_sha256
        _other -> nil
      end

    cond do
      regex == nil ->
        {:error, :invalid_head}

      not (is_binary(commit) and Regex.match?(regex, commit)) ->
        {:error, :invalid_head}

      not (is_binary(tree) and Regex.match?(regex, tree)) ->
        {:error, :invalid_head}

      reconstructed != tree ->
        {:error, :reconstructed_source_mismatch}

      true ->
        :ok
    end
  end

  defp admit_bound_paths(lease, identity) do
    path = identity["path"]
    expected_source = expected_source_root(path)
    expected_overlay = expected_overlay_path(path)

    cond do
      lease["source_root"] != expected_source -> {:error, :invalid_opts}
      lease["overlay_path"] != expected_overlay -> {:error, :invalid_opts}
      true -> :ok
    end
  end

  defp admit_build_inputs(inputs, kind) when is_list(inputs) do
    case Encode.take_proper_list(inputs, @max_inputs) do
      {:ok, items} ->
        with :ok <- admit_each_input(items) do
          finish_build_inputs(items, kind)
        end

      {:error, :unbounded} ->
        {:error, :file_limit}

      {:error, _reason} = error ->
        error
    end
  end

  defp admit_build_inputs(_inputs, _kind), do: {:error, :invalid_opts}

  defp finish_build_inputs(items, kind) do
    paths = Enum.map(items, & &1["path"])
    overlay_path = Overlay.logical_path()
    {overlay_facts, source_facts} = Enum.split_with(items, &(&1["path"] == overlay_path))
    source_paths = Enum.map(source_facts, & &1["path"])
    required = SourcePolicy.required_files()
    excluded = SourcePolicy.excluded_paths()

    cond do
      paths != Enum.sort(paths) ->
        {:error, :invalid_path}

      length(Enum.uniq(paths)) != length(paths) ->
        {:error, :duplicate_path}

      overlay_facts == [] ->
        {:error, :missing_required_input}

      kind == :production and hd(overlay_facts)["sha256"] != Overlay.sha256() ->
        {:error, :overlay_digest_mismatch}

      Enum.any?(source_facts, fn fact ->
        path = fact["path"]
        not SourcePolicy.selected_path?(path) or MapSet.member?(excluded, path)
      end) ->
        {:error, :extra_required_input}

      Enum.any?(required, &(&1 not in source_paths)) ->
        {:error, :missing_required_input}

      length(source_facts) > SourcePolicy.max_source_rows() or length(items) > @max_inputs ->
        {:error, :file_limit}

      true ->
        :ok
    end
  end

  defp admit_each_input([]), do: :ok

  defp admit_each_input([item | rest]) do
    with {:ok, admitted} <- Encode.admit_closed_map(item, ["path", "sha256"]),
         :ok <- Encode.valid_path?(admitted["path"]),
         :ok <- Encode.valid_digest?(admitted["sha256"]) do
      admit_each_input(rest)
    end
  end

  defp admit_identity(identity) when is_map(identity) and not is_struct(identity) do
    with :ok <- Encode.validate_closed_map(identity, @identity_keys),
         :ok <- admit_identity_fields(identity) do
      {:ok, identity}
    end
  end

  defp admit_identity(_identity), do: {:error, :invalid_opts}

  defp admit_identity_fields(%{
         "path" => path,
         "type" => "directory",
         "device" => device,
         "minor_device" => minor_device,
         "inode" => inode
       })
       when is_binary(path) and is_integer(device) and device >= 0 and is_integer(minor_device) and
              minor_device >= 0 and is_integer(inode) and inode >= 0 do
    admit_identity_path(path)
  end

  defp admit_identity_fields(_identity), do: {:error, :invalid_opts}

  defp admit_identity_path(path) do
    segments = Path.split(path)

    cond do
      Path.type(path) != :absolute ->
        {:error, :invalid_opts}

      not String.valid?(path) or String.contains?(path, <<0>>) ->
        {:error, :invalid_opts}

      byte_size(path) > @max_path_bytes ->
        {:error, :invalid_opts}

      Path.expand(path) != path ->
        {:error, :invalid_opts}

      Enum.any?(segments, &(&1 in [".", ".."])) ->
        {:error, :invalid_opts}

      true ->
        :ok
    end
  end
end
