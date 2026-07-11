defmodule Arbor.Shell.ExecutablePolicy do
  @moduledoc false

  use GenServer

  import Bitwise

  @max_symlinks 40

  defmodule Executable do
    @moduledoc false

    @enforce_keys [
      :name,
      :path,
      :device,
      :inode,
      :size,
      :mtime,
      :ctime,
      :mode,
      :sha256
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            name: String.t(),
            path: String.t(),
            device: non_neg_integer(),
            inode: non_neg_integer(),
            size: non_neg_integer(),
            mtime: non_neg_integer(),
            ctime: non_neg_integer(),
            mode: non_neg_integer(),
            sha256: String.t()
          }
  end

  @type state :: %{
          search_paths: [String.t()],
          child_path: String.t(),
          owner_uids: MapSet.t(non_neg_integer())
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec resolve(String.t()) :: {:ok, Executable.t()} | {:error, term()}
  def resolve(command) when is_binary(command) do
    call({:resolve, command})
  end

  def resolve(_command), do: {:error, :executable_not_found}

  @spec resolve_agent(String.t(), String.t()) ::
          {:ok, Executable.t()} | {:error, term()}
  def resolve_agent(raw_command, command_name)
      when is_binary(raw_command) and is_binary(command_name) do
    with {:ok, pinned} <- resolve(command_name) do
      cond do
        raw_command == command_name ->
          {:ok, pinned}

        Path.type(raw_command) == :absolute ->
          case resolve(raw_command) do
            {:ok, candidate} ->
              if same_identity?(candidate, pinned),
                do: {:ok, pinned},
                else: {:error, {:agent_executable_path_not_allowed, raw_command}}

            _other ->
              {:error, {:agent_executable_path_not_allowed, raw_command}}
          end

        true ->
          {:error, {:agent_executable_path_not_allowed, raw_command}}
      end
    else
      {:error, :executable_not_found} -> {:error, {:executable_not_found, command_name}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec child_path() :: {:ok, String.t()} | {:error, :executable_policy_unavailable}
  def child_path do
    call(:child_path)
  end

  @spec same_identity?(Executable.t(), Executable.t()) :: boolean()
  def same_identity?(%Executable{} = left, %Executable{} = right) do
    Map.take(left, [:device, :inode, :size, :mtime, :ctime, :mode, :sha256]) ==
      Map.take(right, [:device, :inode, :size, :mtime, :ctime, :mode, :sha256])
  end

  @impl true
  def init(opts) do
    startup_path = Keyword.get(opts, :startup_path, System.get_env("PATH", ""))

    configured_paths =
      Keyword.get_lazy(opts, :search_paths, fn ->
        Application.get_env(:arbor_shell, :trusted_executable_paths)
      end)

    requested_paths =
      case configured_paths do
        paths when is_list(paths) -> paths
        _ -> String.split(startup_path, ":", trim: true)
      end

    owner_uids = trusted_owner_uids()

    search_paths =
      requested_paths
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()
      |> Enum.filter(&trusted_directory?(&1, owner_uids))

    if search_paths == [] do
      {:stop, :no_trusted_executable_paths}
    else
      {:ok,
       %{
         search_paths: search_paths,
         child_path: Enum.join(search_paths, ":"),
         owner_uids: owner_uids
       }}
    end
  end

  @impl true
  def handle_call(:child_path, _from, state) do
    {:reply, {:ok, state.child_path}, state}
  end

  def handle_call({:resolve, command}, _from, state) do
    {:reply, do_resolve(command, state), state}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported_executable_policy_request}, state}
  end

  defp call(request) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :executable_policy_unavailable}
      _pid -> GenServer.call(__MODULE__, request)
    end
  catch
    :exit, _ -> {:error, :executable_policy_unavailable}
  end

  defp do_resolve(command, state) do
    cond do
      command == "" or String.contains?(command, <<0>>) ->
        {:error, :executable_not_found}

      Path.type(command) == :absolute ->
        resolve_absolute(command, state)

      Path.basename(command) != command ->
        {:error, :executable_not_found}

      true ->
        Enum.find_value(state.search_paths, {:error, :executable_not_found}, fn directory ->
          candidate = Path.join(directory, command)

          case executable_identity(candidate, command, state.owner_uids) do
            {:ok, executable} -> {:ok, executable}
            {:error, _reason} -> false
          end
        end)
    end
  end

  defp resolve_absolute(command, state) do
    expanded = Path.expand(command)
    basename = Path.basename(expanded)

    direct_allowed? =
      Enum.any?(state.search_paths, fn directory -> Path.dirname(expanded) == directory end)

    cond do
      direct_allowed? ->
        executable_identity(expanded, basename, state.owner_uids)

      true ->
        with {:ok, pinned} <- do_resolve(basename, state),
             {:ok, candidate} <- executable_identity(expanded, basename, state.owner_uids),
             true <- same_identity?(candidate, pinned) do
          {:ok, pinned}
        else
          _ -> {:error, :executable_not_found}
        end
    end
  end

  defp executable_identity(candidate, name, owner_uids) do
    with {:ok, canonical} <- canonical_path(candidate),
         true <- Path.type(canonical) == :absolute,
         {:ok, %File.Stat{} = stat} <- File.stat(canonical, time: :posix),
         true <- stat.type == :regular,
         true <- executable_mode?(stat.mode),
         true <- trusted_file_owner?(stat, owner_uids),
         {:ok, contents} <- File.read(canonical),
         {:ok, %File.Stat{} = after_stat} <- File.stat(canonical, time: :posix),
         true <- stable_stat?(stat, after_stat) do
      {:ok,
       %Executable{
         name: name,
         path: canonical,
         device: stat.major_device,
         inode: stat.inode,
         size: stat.size,
         mtime: stat.mtime,
         ctime: stat.ctime,
         mode: stat.mode,
         sha256: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
       }}
    else
      _ -> {:error, :executable_not_found}
    end
  end

  defp stable_stat?(left, right) do
    Map.take(left, [:type, :size, :mode, :major_device, :inode, :mtime, :ctime]) ==
      Map.take(right, [:type, :size, :mode, :major_device, :inode, :mtime, :ctime])
  end

  defp executable_mode?(mode), do: (mode &&& 0o111) != 0

  defp trusted_file_owner?(%File.Stat{uid: uid, mode: mode}, owner_uids) do
    MapSet.member?(owner_uids, uid) and (mode &&& 0o002) == 0
  end

  defp trusted_directory?(path, owner_uids) do
    with {:ok, canonical} <- canonical_path(path),
         {:ok, %File.Stat{type: :directory, uid: uid, mode: mode}} <-
           File.stat(canonical, time: :posix) do
      MapSet.member?(owner_uids, uid) and (mode &&& 0o002) == 0
    else
      _ -> false
    end
  end

  defp trusted_owner_uids do
    home_uid =
      with home when is_binary(home) <- System.user_home(),
           {:ok, %File.Stat{uid: uid}} <- File.stat(home) do
        uid
      else
        _ -> nil
      end

    [0, home_uid]
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp canonical_path(path), do: resolve_links(Path.expand(path), 0)

  defp resolve_links(_path, count) when count > @max_symlinks,
    do: {:error, :too_many_symlinks}

  defp resolve_links(path, count) do
    parts = Path.split(path)
    walk_parts(parts, "/", count)
  end

  defp walk_parts([], current, _count), do: {:ok, Path.expand(current)}

  defp walk_parts([part | rest], current, count) when part in ["/", ""] do
    walk_parts(rest, current, count)
  end

  defp walk_parts([part | rest], current, count) do
    candidate = Path.join(current, part)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(candidate) do
          target =
            if Path.type(target) == :absolute,
              do: target,
              else: Path.expand(target, Path.dirname(candidate))

          resolve_links(Path.join([target | rest]), count + 1)
        end

      {:ok, _stat} ->
        walk_parts(rest, candidate, count)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
