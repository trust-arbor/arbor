defmodule Arbor.Shell.HandleRelativeInodeCore do
  @moduledoc false

  @max_root_bytes 4_096
  @max_rel_bytes 1_024
  @max_component_bytes 255
  @max_depth 48
  @max_payload 16_777_216
  @max_argv_bytes 65_536
  @timeout_ms 30_000
  @max_output 65_536

  @root_keys [:path, :type, :device, :minor_device, :inode, :mode, :uid, :gid, :size, :nlink]
  @node_keys [:type, :device, :minor_device, :inode, :mode, :uid, :gid, :size, :nlink]
  @observe_keys [:operation, :root, :source_relative_path, :source_ancestors, :source_leaf]
  @stage_keys [
    :operation,
    :root,
    :stage_relative_path,
    :stage_ancestors,
    :stage_name,
    :mode,
    :payload
  ]
  @relocate_keys [
    :operation,
    :root,
    :source_relative_path,
    :source_ancestors,
    :source_leaf,
    :source_name,
    :destination_relative_path,
    :destination_ancestors,
    :destination_name
  ]
  @stage_modes MapSet.new([0o600, 0o644, 0o755])
  @max_u64 0xFFFF_FFFF_FFFF_FFFF

  @spec admit(term()) :: {:ok, map()} | {:error, atom()}
  def admit(%{operation: :observe} = request), do: admit_op(request, @observe_keys, :observe)
  def admit(%{operation: :stage} = request), do: admit_op(request, @stage_keys, :stage)
  def admit(%{operation: :relocate} = request), do: admit_op(request, @relocate_keys, :relocate)
  def admit(_request), do: {:error, :invalid_request}

  defp admit_op(request, keys, operation) do
    with true <- exact_keys?(request, keys),
         {:ok, root_path, packed_root} <- admit_root(request.root),
         {:ok, argv, payload, names} <- build_argv(operation, request, root_path, packed_root),
         :ok <- bound_argv(argv) do
      {:ok,
       %{
         operation: operation,
         argv: argv,
         payload: payload,
         timeout_ms: @timeout_ms,
         max_output: @max_output,
         names: names,
         mutating?: operation != :observe
       }}
    else
      false -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_argv(:observe, request, root_path, packed_root) do
    with {:ok, rel, comps} <- admit_relative(request.source_relative_path),
         {:ok, ancestors} <- admit_ancestors(request.source_ancestors, length(comps) - 1),
         {:ok, packed_leaf} <- pack_node(request.source_leaf) do
      packed_anc = ancestors

      argv =
        [
          "handle-relative-inode",
          "observe",
          root_path,
          packed_root,
          rel,
          Integer.to_string(length(packed_anc))
        ] ++
          packed_anc ++ [packed_leaf]

      {:ok, argv, <<>>, %{root_path: root_path, source_relative_path: rel}}
    end
  end

  defp build_argv(:stage, request, root_path, packed_root) do
    with {:ok, rel, comps} <- admit_relative(request.stage_relative_path),
         {:ok, ancestors} <- admit_ancestors(request.stage_ancestors, length(comps) - 1),
         {:ok, name} <- admit_name(request.stage_name, List.last(comps)),
         {:ok, mode} <- admit_stage_mode(request.mode),
         {:ok, payload} <- admit_payload(request.payload) do
      packed_anc = ancestors

      argv =
        [
          "handle-relative-inode",
          "stage",
          root_path,
          packed_root,
          rel,
          Integer.to_string(length(packed_anc))
        ] ++
          packed_anc ++ [name, Integer.to_string(mode), Integer.to_string(byte_size(payload))]

      {:ok, argv, payload, %{root_path: root_path, stage_relative_path: rel, stage_name: name}}
    end
  end

  defp build_argv(:relocate, request, root_path, packed_root) do
    with {:ok, src_rel, src_comps} <- admit_relative(request.source_relative_path),
         {:ok, src_anc} <- admit_ancestors(request.source_ancestors, length(src_comps) - 1),
         {:ok, packed_leaf} <- pack_reg_node(request.source_leaf),
         {:ok, src_name} <- admit_name(request.source_name, List.last(src_comps)),
         {:ok, dst_rel, dst_comps} <- admit_relative(request.destination_relative_path),
         {:ok, dst_anc} <- admit_ancestors(request.destination_ancestors, length(dst_comps) - 1),
         {:ok, dst_name} <- admit_name(request.destination_name, List.last(dst_comps)),
         :ok <- reject_same_name(src_comps, src_name, dst_comps, dst_name) do
      packed_src = src_anc
      packed_dst = dst_anc

      argv =
        [
          "handle-relative-inode",
          "relocate",
          root_path,
          packed_root,
          src_rel,
          Integer.to_string(length(packed_src))
        ] ++
          packed_src ++
          [packed_leaf, src_name, dst_rel, Integer.to_string(length(packed_dst))] ++
          packed_dst ++ [dst_name]

      {:ok, argv, <<>>,
       %{
         root_path: root_path,
         source_relative_path: src_rel,
         source_name: src_name,
         destination_relative_path: dst_rel,
         destination_name: dst_name
       }}
    end
  end

  defp reject_same_name(src_comps, src_name, dst_comps, dst_name) do
    if src_comps == dst_comps and src_name == dst_name do
      {:error, :invalid_request}
    else
      :ok
    end
  end

  defp admit_root(root) do
    with true <- exact_keys?(root, @root_keys),
         :ok <- require_type(root.type, :directory),
         {:ok, packed} <- pack_node(Map.take(root, @node_keys)),
         {:ok, path} <- admit_root_path(root.path) do
      {:ok, path, packed}
    else
      false -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp admit_root_path("/"), do: {:ok, "/"}

  defp admit_root_path(path) when is_binary(path) do
    cond do
      byte_size(path) < 2 or byte_size(path) > @max_root_bytes ->
        {:error, :invalid_path}

      :binary.at(path, 0) != ?/ ->
        {:error, :invalid_path}

      :binary.last(path) == ?/ ->
        {:error, :invalid_path}

      :binary.match(path, <<0>>) != :nomatch ->
        {:error, :invalid_path}

      true ->
        case split_root_components(path) do
          :ok -> {:ok, path}
          :error -> {:error, :invalid_path}
        end
    end
  end

  defp admit_root_path(_path), do: {:error, :invalid_request}

  defp split_root_components(path) do
    [_empty | rest] = :binary.split(path, "/", [:global])

    if rest != [] and Enum.all?(rest, &valid_component?/1) do
      :ok
    else
      :error
    end
  end

  defp admit_relative(path) when is_binary(path) do
    cond do
      byte_size(path) < 1 or byte_size(path) > @max_rel_bytes ->
        {:error, :invalid_path}

      :binary.at(path, 0) == ?/ ->
        {:error, :invalid_path}

      :binary.last(path) == ?/ ->
        {:error, :invalid_path}

      :binary.match(path, <<0>>) != :nomatch ->
        {:error, :invalid_path}

      true ->
        comps = :binary.split(path, "/", [:global])

        if comps != [] and length(comps) <= @max_depth and Enum.all?(comps, &valid_component?/1) do
          {:ok, path, comps}
        else
          {:error, :invalid_path}
        end
    end
  end

  defp admit_relative(_path), do: {:error, :invalid_request}

  defp valid_component?(comp)
       when is_binary(comp) and byte_size(comp) >= 1 and byte_size(comp) <= @max_component_bytes do
    comp != "." and comp != ".." and :binary.match(comp, <<0>>) == :nomatch and
      :binary.match(comp, "\n") == :nomatch and :binary.match(comp, "\r") == :nomatch
  end

  defp valid_component?(_comp), do: false

  defp admit_ancestors(list, expected) when is_list(list) and length(list) == expected do
    list
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      case pack_dir_node(node) do
        {:ok, packed} -> {:cont, {:ok, [packed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, packed} -> {:ok, Enum.reverse(packed)}
      other -> other
    end
  end

  defp admit_ancestors(_list, _expected), do: {:error, :invalid_request}

  defp admit_name(name, expected) when is_binary(name) and name == expected, do: {:ok, name}
  defp admit_name(_name, _expected), do: {:error, :invalid_request}

  defp admit_stage_mode(mode) when is_integer(mode) do
    if MapSet.member?(@stage_modes, mode), do: {:ok, mode}, else: {:error, :invalid_request}
  end

  defp admit_stage_mode(_mode), do: {:error, :invalid_request}

  defp admit_payload(payload) when is_binary(payload) and byte_size(payload) <= @max_payload,
    do: {:ok, payload}

  defp admit_payload(_payload), do: {:error, :invalid_request}

  defp pack_dir_node(node) when is_map(node) do
    case Map.get(node, :type) do
      :directory -> pack_node(node)
      :regular -> {:error, :invalid_type}
      _other -> pack_node(node)
    end
  end

  defp pack_dir_node(_node), do: {:error, :invalid_request}

  defp pack_reg_node(node) when is_map(node) do
    case Map.get(node, :type) do
      :regular -> pack_node(node)
      :directory -> {:error, :invalid_type}
      _other -> pack_node(node)
    end
  end

  defp pack_reg_node(_node), do: {:error, :invalid_request}

  defp require_type(type, type), do: :ok
  defp require_type(_got, _want), do: {:error, :invalid_type}

  defp pack_node(node) do
    with true <- exact_keys?(node, @node_keys),
         {:ok, type} <- admit_type(node.type),
         {:ok, mode} <- admit_uint(node.mode),
         {:ok, uid} <- admit_uint(node.uid),
         {:ok, gid} <- admit_uint(node.gid),
         {:ok, size} <- admit_uint(node.size),
         {:ok, nlink} <- admit_uint(node.nlink),
         {:ok, device} <- admit_uint(node.device),
         {:ok, minor} <- admit_uint(node.minor_device),
         {:ok, inode} <- admit_uint(node.inode),
         :ok <- admit_regular_nlink(type, nlink) do
      packed =
        Enum.join(
          [
            Atom.to_string(type),
            Integer.to_string(mode),
            Integer.to_string(uid),
            Integer.to_string(gid),
            Integer.to_string(size),
            Integer.to_string(nlink),
            Integer.to_string(device),
            Integer.to_string(minor),
            Integer.to_string(inode)
          ],
          ":"
        )

      {:ok, packed}
    else
      false -> {:error, :invalid_request}
      {:error, reason} -> {:error, reason}
    end
  end

  defp admit_regular_nlink(:regular, 1), do: :ok
  defp admit_regular_nlink(:regular, _nlink), do: {:error, :hardlink_rejected}
  defp admit_regular_nlink(:directory, _nlink), do: :ok

  defp admit_type(:directory), do: {:ok, :directory}
  defp admit_type(:regular), do: {:ok, :regular}
  defp admit_type(_type), do: {:error, :invalid_request}

  defp admit_uint(n) when is_integer(n) and n >= 0 and n <= @max_u64, do: {:ok, n}
  defp admit_uint(_n), do: {:error, :invalid_request}

  defp exact_keys?(map, keys) when is_map(map) do
    MapSet.new(Map.keys(map)) == MapSet.new(keys)
  end

  defp exact_keys?(_map, _keys), do: false

  defp bound_argv(argv) do
    total = Enum.reduce(argv, 0, fn token, acc -> acc + byte_size(token) + 1 end)

    if total <= @max_argv_bytes, do: :ok, else: {:error, :invalid_request}
  end
end
