defmodule Arbor.Shell.ExecutablePolicy do
  @moduledoc false

  use GenServer

  alias Arbor.Shell.TrustedPath

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
          executables_by_path: %{String.t() => Executable.t()}
        }

  # Exact absolute paths for Apple read-only/control-plane probe commands.
  # These are pinned individually into executables_by_path only — never by
  # scanning their parent directories and never into executables_by_name —
  # so a standalone /usr/local/bin/container is resolvable by absolute path
  # when /usr/local/bin is omitted from the service PATH, without granting
  # generic basename authority or authorizing siblings.
  @apple_fixed_executable_paths [
    "/usr/local/bin/container",
    "/usr/bin/codesign",
    "/bin/launchctl",
    "/usr/bin/id",
    "/usr/bin/sw_vers"
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  @spec apple_fixed_executable_paths() :: [String.t()]
  def apple_fixed_executable_paths, do: @apple_fixed_executable_paths

  # Same-module test seam for merge/pin logic with temporary fixture paths.
  # Production init always supplies `@apple_fixed_executable_paths` only —
  # never Application env or caller-nominated fixed path lists.
  @doc false
  @spec __merge_fixed_executables_for_test__(
          %{String.t() => Executable.t()},
          %{String.t() => Executable.t()},
          [String.t()]
        ) :: {%{String.t() => Executable.t()}, %{String.t() => Executable.t()}}
  def __merge_fixed_executables_for_test__(by_name, by_path, fixed_paths)
      when is_map(by_name) and is_map(by_path) and is_list(fixed_paths) do
    merge_fixed_executables(by_name, by_path, fixed_paths)
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

    if search_paths == [] do
      {:stop, :no_trusted_executable_paths}
    else
      {executables_by_name, executables_by_path} = pin_executables(search_paths)

      # Exact fixed Apple control paths only — never from opts/Application env.
      {executables_by_name, executables_by_path} =
        merge_fixed_executables(
          executables_by_name,
          executables_by_path,
          @apple_fixed_executable_paths
        )

      {:ok,
       %{
         search_paths: search_paths,
         child_path: Enum.join(search_paths, ":"),
         executables_by_name: executables_by_name,
         executables_by_path: executables_by_path
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
    with {:ok, canonical} <- TrustedPath.canonicalize_absolute(command) do
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

  # Pin each exact fixed absolute path into executables_by_path only.
  # Missing or untrusted paths are omitted so non-macOS / Homebrew-only hosts
  # still start; the Apple probe fails closed later when resolve misses.
  # executables_by_name is left exactly as established by trusted PATH
  # discovery — fixed paths must never become generic basename authority.
  defp merge_fixed_executables(by_name, by_path, fixed_paths)
       when is_map(by_name) and is_map(by_path) and is_list(fixed_paths) do
    Enum.reduce(fixed_paths, {by_name, by_path}, fn path, {names, paths} ->
      case pin_fixed_executable(path) do
        {:ok, %Executable{} = executable} ->
          {names, Map.put(paths, executable.path, executable)}

        {:error, _reason} ->
          {names, paths}
      end
    end)
  end

  defp pin_fixed_executable(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      name = Path.basename(path)

      case executable_identity(path, name) do
        {:ok, %Executable{path: pinned_path} = executable} ->
          # Accept TrustedPath canonicalization when it names the same file.
          if pinned_path == path or paths_equivalent?(path, pinned_path) do
            {:ok, %{executable | name: name}}
          else
            {:error, :executable_not_found}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :executable_not_found}
    end
  end

  defp pin_fixed_executable(_path), do: {:error, :executable_not_found}

  defp paths_equivalent?(left, right)
       when is_binary(left) and is_binary(right) do
    case {TrustedPath.canonicalize_absolute(left), TrustedPath.canonicalize_absolute(right)} do
      {{:ok, a}, {:ok, b}} -> a == b
      _ -> false
    end
  end

  defp executable_identity(candidate, name) do
    case TrustedPath.pin_root_owned_regular_file(candidate, executable: true) do
      {:ok, %TrustedPath.Identity{} = identity} ->
        {:ok,
         %Executable{
           name: name,
           path: identity.path,
           device: identity.device,
           inode: identity.inode,
           size: identity.size,
           mtime: identity.mtime,
           ctime: identity.ctime,
           mode: identity.mode,
           sha256: identity.sha256
         }}

      {:error, _reason} ->
        {:error, :executable_not_found}
    end
  end

  # Relative PATH entries are expanded against the service CWD at policy
  # construction, matching historical resolve behavior, then pinned only when
  # the resulting absolute directory is root-owned and not group/other writable.
  defp trusted_directory(path) when is_binary(path) do
    absolute =
      case Path.type(path) do
        :absolute -> path
        _ -> Path.expand(path)
      end

    case TrustedPath.pin_root_owned_directory(absolute) do
      {:ok, %TrustedPath.Identity{path: canonical}} -> {:ok, canonical}
      {:error, _reason} -> {:error, :untrusted_executable_directory}
    end
  end

  defp trusted_directory(_path), do: {:error, :untrusted_executable_directory}

  defp identity(executable) do
    Map.take(executable, [:device, :inode, :size, :mtime, :ctime, :mode, :sha256])
  end
end
