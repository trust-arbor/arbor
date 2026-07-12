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
          executables_by_name: %{String.t() => Executable.t()},
          executables_by_path: %{String.t() => Executable.t()},
          spawn_backend: module() | nil,
          spawn_manifest: %{String.t() => map()}
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

  @spec verify_pinned(Executable.t()) :: :ok | {:error, :executable_not_pinned}
  def verify_pinned(%Executable{} = executable) do
    call({:verify_pinned, executable})
  end

  def verify_pinned(_executable), do: {:error, :executable_not_pinned}

  @spec spawn_tool(String.t()) :: {:ok, module(), map()} | {:error, term()}
  def spawn_tool(name) when is_binary(name), do: call({:spawn_tool, name})
  def spawn_tool(_name), do: {:error, :spawn_executable_not_manifested}

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
    identity(left) == identity(right)
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

    search_paths =
      requested_paths
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&trusted_directory/1)
      |> Enum.flat_map(fn
        {:ok, path} -> [path]
        {:error, _reason} -> []
      end)
      |> Enum.uniq()

    spawn_backend =
      Keyword.get(opts, :spawn_backend, Application.get_env(:arbor_shell, :spawn_backend))

    configured_spawn_manifest =
      Keyword.get(
        opts,
        :spawn_manifest,
        Application.get_env(:arbor_shell, :spawn_executable_manifest, %{})
      )

    if search_paths == [] do
      {:stop, :no_trusted_executable_paths}
    else
      with :ok <- validate_spawn_backend(spawn_backend),
           {:ok, spawn_manifest} <- pin_spawn_manifest(configured_spawn_manifest) do
        {executables_by_name, executables_by_path} = pin_executables(search_paths)

        {:ok,
         %{
           search_paths: search_paths,
           child_path: Enum.join(search_paths, ":"),
           executables_by_name: executables_by_name,
           executables_by_path: executables_by_path,
           spawn_backend: spawn_backend,
           spawn_manifest: spawn_manifest
         }}
      end
    end
  end

  @impl true
  def handle_call(:child_path, _from, state) do
    {:reply, {:ok, state.child_path}, state}
  end

  def handle_call({:resolve, command}, _from, state) do
    {:reply, do_resolve(command, state), state}
  end

  def handle_call({:verify_pinned, %Executable{} = executable}, _from, state) do
    result =
      case Map.get(state.executables_by_path, executable.path) do
        %Executable{} = pinned ->
          if same_identity?(pinned, executable), do: :ok, else: {:error, :executable_not_pinned}

        nil ->
          {:error, :executable_not_pinned}
      end

    {:reply, result, state}
  end

  def handle_call({:spawn_tool, name}, _from, state) do
    result =
      case {state.spawn_backend, Map.get(state.spawn_manifest, name)} do
        {nil, _entry} -> {:error, {:spawn_backend_unavailable, :not_configured}}
        {_backend, nil} -> {:error, {:spawn_executable_not_manifested, name}}
        {backend, entry} -> {:ok, backend, entry}
      end

    {:reply, result, state}
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
        case Map.get(state.executables_by_name, command) do
          %Executable{} = executable -> {:ok, executable}
          nil -> {:error, :executable_not_found}
        end
    end
  end

  defp resolve_absolute(command, state) do
    with {:ok, canonical} <- canonical_path(command) do
      case Map.get(state.executables_by_path, canonical) do
        %Executable{} = executable ->
          {:ok, executable}

        nil ->
          basename = Path.basename(canonical)

          case Map.get(state.executables_by_name, basename) do
            %Executable{path: ^canonical} = executable -> {:ok, executable}
            _other -> {:error, :executable_not_found}
          end
      end
    else
      _ -> {:error, :executable_not_found}
    end
  end

  defp pin_executables(search_paths) do
    Enum.reduce(search_paths, {%{}, %{}}, fn directory, {by_name, by_path} ->
      directory
      |> File.ls()
      |> case do
        {:ok, entries} -> Enum.sort(entries)
        {:error, _reason} -> []
      end
      |> Enum.reduce({by_name, by_path}, fn name, {names, paths} ->
        case executable_identity(Path.join(directory, name), name) do
          {:ok, executable} ->
            {
              Map.put_new(names, name, executable),
              Map.put_new(paths, executable.path, executable)
            }

          {:error, _reason} ->
            {names, paths}
        end
      end)
    end)
  end

  defp validate_spawn_backend(nil), do: :ok
  defp validate_spawn_backend(backend) when is_atom(backend), do: :ok
  defp validate_spawn_backend(_backend), do: {:stop, :invalid_spawn_backend}

  defp pin_spawn_manifest(manifest) when is_map(manifest) do
    Enum.reduce_while(manifest, {:ok, %{}}, fn
      {name, entry}, {:ok, pinned} when is_binary(name) and is_map(entry) ->
        case pin_spawn_entry(name, entry) do
          {:ok, pinned_entry} -> {:cont, {:ok, Map.put(pinned, name, pinned_entry)}}
          {:error, reason} -> {:halt, {:stop, reason}}
        end

      _entry, _acc ->
        {:halt, {:stop, :invalid_spawn_executable_manifest}}
    end)
  end

  defp pin_spawn_manifest(_manifest), do: {:stop, :invalid_spawn_executable_manifest}

  defp pin_spawn_entry(name, entry) do
    path = Map.get(entry, :path) || Map.get(entry, "path")
    expected_digest = Map.get(entry, :sha256) || Map.get(entry, "sha256")

    with true <- is_binary(path) and Path.type(path) == :absolute,
         true <-
           is_binary(expected_digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, expected_digest),
         {:ok, canonical} <- canonical_path(path),
         {:ok, %File.Stat{} = stat} <- File.stat(canonical, time: :posix),
         true <- stat.type == :regular and executable_mode?(stat.mode),
         {:ok, contents} <- File.read(canonical),
         ^expected_digest <- :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower),
         {:ok, %File.Stat{} = after_stat} <- File.stat(canonical, time: :posix),
         true <- stable_stat?(stat, after_stat) do
      {:ok,
       %{
         name: name,
         path: canonical,
         sha256: expected_digest,
         device: stat.major_device,
         inode: stat.inode,
         size: stat.size,
         mode: stat.mode,
         mtime: stat.mtime,
         ctime: stat.ctime
       }}
    else
      _other -> {:error, {:invalid_spawn_executable_manifest_entry, name}}
    end
  end

  defp executable_identity(candidate, name) do
    with {:ok, canonical} <- canonical_path(candidate),
         true <- Path.type(canonical) == :absolute,
         :ok <- trusted_path_chain(canonical),
         {:ok, %File.Stat{} = stat} <- File.stat(canonical, time: :posix),
         true <- stat.type == :regular,
         true <- executable_mode?(stat.mode),
         true <- trusted_file?(stat),
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

  # Agent processes share the service account's filesystem authority. A
  # user-owned PATH directory is therefore mutable by the same principal and
  # cannot anchor an executable identity. Root ownership plus no group/other
  # write permission leaves replacement under operator authority only.
  defp trusted_file?(%File.Stat{uid: 0, mode: mode}), do: (mode &&& 0o022) == 0
  defp trusted_file?(_stat), do: false

  defp trusted_directory(path) do
    with {:ok, canonical} <- canonical_path(path),
         :ok <- trusted_path_chain(canonical),
         {:ok, %File.Stat{type: :directory, uid: 0, mode: mode}} <-
           File.stat(canonical, time: :posix),
         true <- (mode &&& 0o022) == 0 do
      {:ok, canonical}
    else
      _ -> {:error, :untrusted_executable_directory}
    end
  end

  defp trusted_path_chain(path) do
    path
    |> Path.dirname()
    |> directory_chain()
    |> Enum.reduce_while(:ok, fn directory, :ok ->
      case File.stat(directory, time: :posix) do
        {:ok, %File.Stat{type: :directory, uid: 0, mode: mode}} when (mode &&& 0o022) == 0 ->
          {:cont, :ok}

        _other ->
          {:halt, {:error, :untrusted_executable_directory}}
      end
    end)
  end

  defp directory_chain(path) do
    path
    |> Path.split()
    |> Enum.reduce({[], "/"}, fn
      "/", {directories, current} ->
        {directories, current}

      part, {directories, current} ->
        next = Path.join(current, part)
        {[next | directories], next}
    end)
    |> elem(0)
    |> then(&["/" | Enum.reverse(&1)])
    |> Enum.uniq()
  end

  defp identity(executable) do
    Map.take(executable, [:device, :inode, :size, :mtime, :ctime, :mode, :sha256])
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
