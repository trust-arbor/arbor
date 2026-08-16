defmodule Arbor.Shell.TrustedBuild.Request do
  @moduledoc false

  @request_schema "arbor.shell.trusted_build.request.v1"
  @source_schema "arbor.shell.trusted_build.source.v1"
  @request_keys ["schema", "source"]
  @source_keys ["schema", "identity"]
  @identity_keys ["path", "type", "device", "minor_device", "inode"]
  @max_path_bytes 4_096

  @type identity :: %{
          path: String.t(),
          type: :directory,
          device: non_neg_integer(),
          minor_device: non_neg_integer(),
          inode: non_neg_integer()
        }

  @type admitted :: %{identity: identity()}

  @spec admit(term()) :: {:ok, admitted()} | {:error, :invalid_trusted_build_request}
  def admit(request) when is_map(request) and not is_struct(request) do
    with :ok <- closed_map(request, @request_keys),
         :ok <- exact_string(request["schema"], @request_schema),
         {:ok, source} <- admit_source(request["source"]) do
      {:ok, %{identity: source}}
    else
      _other -> {:error, :invalid_trusted_build_request}
    end
  end

  def admit(_request), do: {:error, :invalid_trusted_build_request}

  defp admit_source(source) when is_map(source) and not is_struct(source) do
    with :ok <- closed_map(source, @source_keys),
         :ok <- exact_string(source["schema"], @source_schema),
         {:ok, identity} <- admit_identity(source["identity"]) do
      {:ok, identity}
    end
  end

  defp admit_source(_source), do: :error

  defp admit_identity(identity) when is_map(identity) and not is_struct(identity) do
    with :ok <- closed_map(identity, @identity_keys),
         path when is_binary(path) <- identity["path"],
         :ok <- admit_identity_path(path),
         "directory" <- identity["type"],
         device when is_integer(device) and device >= 0 <- identity["device"],
         minor when is_integer(minor) and minor >= 0 <- identity["minor_device"],
         inode when is_integer(inode) and inode >= 0 <- identity["inode"] do
      {:ok,
       %{
         path: path,
         type: :directory,
         device: device,
         minor_device: minor,
         inode: inode
       }}
    else
      _other -> :error
    end
  end

  defp admit_identity(_identity), do: :error

  defp admit_identity_path(path) do
    segments = Path.split(path)

    cond do
      path == "" -> :error
      not String.valid?(path) -> :error
      String.contains?(path, <<0>>) -> :error
      byte_size(path) > @max_path_bytes -> :error
      Path.type(path) != :absolute -> :error
      Path.expand(path) != path -> :error
      Enum.any?(segments, &(&1 in [".", ".."])) -> :error
      true -> :ok
    end
  end

  defp exact_string(value, expected) when value == expected, do: :ok
  defp exact_string(_value, _expected), do: :error

  defp closed_map(map, keys) do
    map_keys = Map.keys(map)

    cond do
      map_keys -- keys != [] -> :error
      keys -- map_keys != [] -> :error
      Enum.any?(map_keys, &(not is_binary(&1))) -> :error
      true -> :ok
    end
  end
end
