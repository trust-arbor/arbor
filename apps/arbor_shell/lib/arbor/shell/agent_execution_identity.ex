defmodule Arbor.Shell.AgentExecutionIdentity do
  @moduledoc false

  import Bitwise, only: [band: 2]
  alias Arbor.Common.SafePath

  @modules [
    Arbor.Shell,
    Arbor.Shell.AgentContainment,
    Arbor.Shell.ProcessGroup,
    Arbor.Shell.Executor,
    Arbor.Shell.PortSession,
    Arbor.Shell.Sandbox,
    Arbor.Shell.ExecutablePolicy,
    Arbor.Shell.AgentExecutionIdentity
  ]
  @stat_keys [
    :size,
    :type,
    :mtime,
    :ctime,
    :mode,
    :major_device,
    :minor_device,
    :inode,
    :uid,
    :gid
  ]
  @max_bytes 8_388_608

  def snapshot do
    with {:ok, before_modules} <- module_identities(),
         {:ok, native} <- native_identity(),
         {:ok, ^before_modules} <- module_identities() do
      {family, platform} = :os.type()

      {:ok,
       %{
         "schema_version" => 1,
         "policy_version" => "agent-cwd-seatbelt-v1",
         "os_family" => Atom.to_string(family),
         "platform" => Atom.to_string(platform),
         "supported" => platform == :darwin,
         "launcher" => native,
         "loaded_modules" => before_modules
       }}
    else
      _ -> {:error, :agent_execution_identity_unavailable}
    end
  rescue
    _ -> {:error, :agent_execution_identity_unavailable}
  catch
    _, _ -> {:error, :agent_execution_identity_unavailable}
  end

  defp module_identities do
    case Application.get_env(:arbor_shell, :agent_authorizer) do
      module when is_atom(module) and not is_nil(module) ->
        with true <- Code.ensure_loaded?(module),
             true <- function_exported?(module, :authorize_command, 3),
             true <- function_exported?(module, :authorize_filesystem, 5) do
          modules = Enum.uniq(@modules ++ [module])

          {:ok,
           Map.new(modules, fn mod ->
             true = Code.ensure_loaded?(mod)
             {Atom.to_string(mod), Base.encode16(mod.module_info(:md5), case: :lower)}
           end)}
        else
          _ -> {:error, :agent_authorizer_unavailable}
        end

      _ ->
        {:error, :agent_authorizer_unavailable}
    end
  end

  defp native_identity do
    path = :arbor_shell |> :code.priv_dir() |> to_string() |> Path.join("arbor_shell_launcher")

    with {:ok, canonical} <- SafePath.resolve_real(path),
         {:ok, io} <- :file.open(String.to_charlist(canonical), [:read, :raw, :binary]) do
      try do
        read_identity(io, canonical)
      after
        :file.close(io)
      end
    end
  end

  defp read_identity(io, path) do
    with {:ok, before_path} <- File.lstat(path, time: :posix),
         {:ok, before_fd} <- :file.read_file_info(io, time: :posix),
         before_fd <- File.Stat.from_record(before_fd),
         true <- before_path.type == :regular and before_path.size in 1..@max_bytes,
         true <- band(before_path.mode, 0o111) != 0,
         {:ok, bytes} <- :file.read(io, @max_bytes + 1),
         true <- byte_size(bytes) == before_path.size,
         :eof <- :file.read(io, 1),
         {:ok, 0} <- :file.position(io, :bof),
         {:ok, ^bytes} <- :file.read(io, @max_bytes + 1),
         :eof <- :file.read(io, 1),
         {:ok, after_fd} <- :file.read_file_info(io, time: :posix),
         {:ok, after_path} <- File.lstat(path, time: :posix),
         true <- same_stat?(before_path, before_fd),
         true <- same_stat?(before_path, File.Stat.from_record(after_fd)),
         true <- same_stat?(before_path, after_path) do
      {:ok,
       %{
         "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
         "size_bytes" => byte_size(bytes)
       }}
    else
      _ -> {:error, :launcher_identity_unavailable}
    end
  end

  defp same_stat?(left, right), do: Map.take(left, @stat_keys) == Map.take(right, @stat_keys)
end
