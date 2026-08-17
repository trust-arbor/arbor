defmodule Arbor.Commands.SafeRecoveryArtifact.InputEvidence do
  @moduledoc false

  # Impure observation of every fixed first-party/config/build input consumed
  # by the C3c0 child-project build: the SourcePolicy-selected Git blobs at
  # HEAD plus the pinned native overlay file. Reads Git objects only -- it
  # never compiles, never acquires a trusted-build lease, and never nests any
  # trusted-build.

  alias Arbor.Commands.ImmutableGitSource.Git
  alias Arbor.Commands.SafeRecoveryArtifact.{Overlay, SourcePolicy}

  @max_file_bytes 16_777_216
  @max_total_bytes 268_435_456
  @max_listing_bytes 16_777_216
  @oid_pattern ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @ls_tree_record ~r/\A([0-7]{6}) (blob|tree) ([0-9a-f]{40}|[0-9a-f]{64})\t(.+)\z/s

  @doc """
  Observe the complete fixed input set at HEAD.

  `overlay` is `:production` (bind the pinned native overlay via the
  production descriptor) or `{:expected, size, sha256}` (test seam values).
  Returns the bound HEAD identity plus one `%{"path" => path, "sha256" =>
  sha256}` row per input, sorted by path.
  """
  @spec observe(String.t(), pos_integer(), :production | {:expected, pos_integer(), String.t()}) ::
          {:ok,
           %{commit: String.t(), tree: String.t(), object_format: String.t(), inputs: [map()]}}
          | {:error, term()}
  def observe(root, timeout_ms, overlay)
      when is_binary(root) and is_integer(timeout_ms) and timeout_ms > 0 do
    with {:ok, head} <- bind_head(root, timeout_ms),
         {:ok, blobs} <- list_commit_blobs(root, head.commit, timeout_ms),
         {:ok, selected} <- select_inputs(blobs),
         {:ok, digests} <- selected_digests(root, selected, blobs, timeout_ms),
         {:ok, overlay_input} <- bind_overlay(root, overlay) do
      {:ok,
       %{
         commit: head.commit,
         tree: head.tree,
         object_format: head.object_format,
         inputs: Enum.sort_by([overlay_input | digests], & &1["path"])
       }}
    end
  end

  def observe(_root, _timeout_ms, _overlay), do: {:error, :invalid_opts}

  # -- HEAD binding ----------------------------------------------------------

  defp bind_head(root, timeout_ms) do
    with {:ok, commit} <- git_oid(root, ["rev-parse", "--verify", "HEAD^{commit}"], timeout_ms),
         {:ok, tree} <- git_oid(root, ["rev-parse", "--verify", "HEAD^{tree}"], timeout_ms),
         {:ok, format} <- object_format(commit, tree) do
      {:ok, %{commit: commit, tree: tree, object_format: format}}
    else
      _other -> {:error, :invalid_head}
    end
  end

  defp git_oid(root, args, timeout_ms) do
    case Git.run(root, args, timeout_ms) do
      {:ok, output} ->
        oid = output |> String.trim() |> String.downcase()

        if Regex.match?(@oid_pattern, oid), do: {:ok, oid}, else: {:error, :invalid_head}

      {:error, _reason} ->
        {:error, :invalid_head}
    end
  end

  defp object_format(commit, tree) do
    cond do
      byte_size(commit) == 40 and byte_size(tree) == 40 -> {:ok, "sha1"}
      byte_size(commit) == 64 and byte_size(tree) == 64 -> {:ok, "sha256"}
      true -> {:error, :mixed_object_format}
    end
  end

  # -- selection --------------------------------------------------------------

  defp list_commit_blobs(root, commit, timeout_ms) do
    case Git.run(root, ["ls-tree", "-r", "-z", "--full-tree", commit], timeout_ms,
           max_output_bytes: @max_listing_bytes
         ) do
      {:ok, listing} -> parse_blob_listing(listing)
      {:error, _reason} -> {:error, :selection_listing_failed}
    end
  end

  defp parse_blob_listing(listing) do
    listing
    |> :binary.split(<<0>>, [:global])
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
      case parse_ls_tree_record(record) do
        {:ok, :tree} -> {:cont, {:ok, acc}}
        {:ok, blob} -> {:cont, {:ok, [blob | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp parse_ls_tree_record(record) do
    case Regex.run(@ls_tree_record, record) do
      [_, _mode, "tree", _oid, _path] ->
        {:ok, :tree}

      [_, mode, "blob", oid, path] ->
        {:ok, %{path: path, mode: mode, oid: String.downcase(oid)}}

      _other ->
        {:error, :invalid_path}
    end
  end

  defp select_inputs(blobs) do
    case SourcePolicy.select(blobs) do
      {:ok, selected} -> {:ok, selected}
      {:error, reason} -> {:error, {:selection_failed, reason}}
    end
  end

  # -- content digests --------------------------------------------------------

  defp selected_digests(root, selected, blobs, timeout_ms) do
    by_path = Map.new(blobs, &{&1.path, &1})

    requests =
      selected
      |> Enum.map(fn path -> %{oid: Map.fetch!(by_path, path).oid, type: "blob"} end)
      |> Enum.uniq_by(& &1.oid)

    case Git.read_objects(root, requests, timeout_ms,
           max_object_bytes: @max_file_bytes,
           max_total_bytes: @max_total_bytes
         ) do
      {:ok, objects} ->
        digests_for(selected, by_path, objects)

      {:error, "object_attestation_failed"} ->
        {:error, :total_byte_limit}

      {:error, "git_object_request_limit"} ->
        {:error, :file_limit}

      {:error, _reason} ->
        {:error, :selected_object_unreadable}
    end
  end

  defp digests_for(selected, by_path, objects) do
    selected
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      oid = Map.fetch!(by_path, path).oid

      case Map.fetch(objects, oid) do
        {:ok, %{type: "blob", content: content}} ->
          {:cont, {:ok, [%{"path" => path, "sha256" => sha256_hex(content)} | acc]}}

        _other ->
          {:halt, {:error, :selected_object_unreadable}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp bind_overlay(root, :production), do: bind_overlay_input(Overlay.bind(root))

  defp bind_overlay(root, {:expected, size, sha256}),
    do: bind_overlay_input(Overlay.bind_expected(root, size, sha256))

  defp bind_overlay(_root, _other), do: {:error, :invalid_opts}

  defp bind_overlay_input({:ok, %{path: path, sha256: digest}}) when is_binary(digest),
    do: {:ok, %{"path" => path, "sha256" => digest}}

  defp bind_overlay_input({:error, reason}), do: {:error, reason}
  defp bind_overlay_input(_other), do: {:error, :overlay_missing}

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
