defmodule Arbor.AI.AcpSession.GrokSandbox do
  @moduledoc false

  import Bitwise

  alias Arbor.Common.SafePath
  alias Toml

  defmodule Authority do
    @moduledoc false

    @enforce_keys [
      :owner,
      :reference,
      :repository_root,
      :worktree_root,
      :common_dir,
      :gitdir,
      :snapshot
    ]
    defstruct @enforce_keys
  end

  defmodule ProfileLease do
    @moduledoc false

    @enforce_keys [
      :profile_path,
      :backup_path,
      :generated_binding,
      :had_backup,
      :profile_dir_created
    ]
    defstruct @enforce_keys
  end

  @expected_grok_command [
    "grok",
    "--sandbox",
    "strict",
    "--no-memory",
    "--no-subagents",
    "--disable-web-search",
    "--deny",
    "MCPTool(*)",
    "--deny",
    "Bash(*)",
    "--disallowed-tools",
    "execute",
    "agent",
    "--no-leader",
    "--model",
    "grok-4.5",
    "stdio"
  ]

  @grok_command_with_bound_mcp [
    "grok",
    "--sandbox",
    "strict",
    "--no-memory",
    "--no-subagents",
    "--disable-web-search",
    "--disallowed-tools",
    "execute",
    "--deny",
    "Bash(*)",
    "agent",
    "--no-leader",
    "--model",
    "grok-4.5",
    "stdio"
  ]

  @sandbox_command_index 2
  @profile_name_prefix "arbor-grok-strict"
  @profile_filename "sandbox.toml"
  @backup_filename ".sandbox.toml.arbor-backup"
  @profile_marker "# Managed transiently by Arbor."
  @max_metadata_bytes 4_096
  @max_profile_bytes 65_536
  @ambient_mcp_relative_paths [
    [".grok", "config.toml"],
    [".mcp.json"],
    [".cursor", "mcp.json"],
    [".grok", "plugins"],
    [".claude", "plugins"]
  ]

  @opaque authority :: %Authority{}

  @doc false
  @spec adopt_authority(pid(), term()) ::
          {:ok, authority()} | {:error, term()}
  def adopt_authority(prior_owner, authority) when is_pid(prior_owner) do
    with {:ok, %Authority{} = authority} <- normalize_authority(authority),
         :ok <- verify_authority(authority, prior_owner, authority.worktree_root) do
      {:ok,
       %Authority{
         authority
         | owner: self(),
           reference: make_ref()
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def adopt_authority(_prior_owner, _authority), do: {:error, :invalid_grok_worktree_authority}

  @doc false
  @spec bind(String.t(), String.t()) :: {:ok, authority()} | {:error, term()}
  def bind(repository_root, worktree_root)
      when is_binary(repository_root) and is_binary(worktree_root) do
    with {:ok, repository_root} <- canonical_directory(repository_root),
         {:ok, worktree_root} <- canonical_directory(worktree_root),
         {:ok, expected_common_dir} <- repository_common_dir(repository_root),
         {:ok, metadata} <- linked_worktree_metadata(worktree_root),
         true <- metadata.common_dir == expected_common_dir,
         :ok <- reject_preexisting_backup(worktree_root),
         {:ok, snapshot} <- capture_snapshot(repository_root, metadata) do
      {:ok,
       %Authority{
         owner: self(),
         reference: make_ref(),
         repository_root: repository_root,
         worktree_root: worktree_root,
         common_dir: metadata.common_dir,
         gitdir: metadata.gitdir,
         snapshot: snapshot
       }}
    else
      false -> {:error, :grok_worktree_repository_mismatch}
      :standalone -> {:error, :grok_linked_worktree_required}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_grok_worktree_authority}
    end
  end

  def bind(_repository_root, _worktree_root),
    do: {:error, :invalid_grok_worktree_authority}

  @doc false
  @spec with_launch(atom(), keyword(), String.t() | nil, term(), pid() | nil, function()) ::
          {:ok, term()}
          | {:error, term()}
          | {:error, {:grok_sandbox_cleanup_failed, term()}, term()}
  def with_launch(provider, client_opts, cwd, authority, owner, fun) do
    with_launch(provider, client_opts, cwd, authority, owner, [], fun)
  end

  @doc false
  @spec with_launch(
          atom(),
          keyword(),
          String.t() | nil,
          term(),
          pid() | nil,
          [map()],
          function()
        ) ::
          {:ok, term()}
          | {:error, term()}
          | {:error, {:grok_sandbox_cleanup_failed, term()}, term()}
  def with_launch(provider, client_opts, _cwd, _authority, _owner, _mcp_servers, fun)
      when provider != :grok and is_list(client_opts) and is_function(fun, 1) do
    {:ok, fun.(client_opts)}
  end

  def with_launch(:grok, client_opts, cwd, authority, owner, mcp_servers, fun)
      when is_list(client_opts) and is_binary(cwd) and is_function(fun, 1) do
    with :ok <- validate_client_opts(client_opts),
         :ok <- validate_bound_mcp_servers(mcp_servers),
         {:ok, worktree_root} <- canonical_directory(cwd),
         :ok <- reject_ambient_mcp_sources(worktree_root),
         {:ok, kind} <- repository_kind(worktree_root) do
      case kind do
        :standalone ->
          with :ok <- reject_unexpected_authority(authority) do
            run_standalone_launch(client_opts, worktree_root, mcp_servers, fun)
          end

        {:linked, metadata} ->
          with :ok <- verify_authority(authority, owner, worktree_root, metadata) do
            run_linked_launch(client_opts, authority, mcp_servers, fun)
          end
      end
    end
  end

  def with_launch(:grok, _client_opts, _cwd, _authority, _owner, _mcp_servers, _fun),
    do: {:error, :invalid_grok_launch}

  def with_launch(_provider, _client_opts, _cwd, _authority, _owner, _mcp_servers, _fun),
    do: {:error, :invalid_acp_client_options}

  defp run_linked_launch(client_opts, %Authority{} = authority, mcp_servers, fun) do
    with_profile_lock(authority.worktree_root, fn ->
      do_run_linked_launch(client_opts, authority, mcp_servers, fun)
    end)
  end

  defp run_standalone_launch(client_opts, worktree_root, mcp_servers, fun) do
    with_profile_lock(worktree_root, fn ->
      with :ok <- reject_ambient_mcp_sources(worktree_root),
           {:ok, profile_name} <- profile_name(worktree_root),
           {:ok, profile_content} <- profile_content(profile_name, worktree_root, []),
           :ok <- reject_global_profile_collision(profile_name, client_opts),
           :ok <- reject_preexisting_backup(worktree_root),
           :ok <- recover_orphaned_profile(worktree_root, profile_content),
           {:ok, lease} <- install_profile(worktree_root, profile_content) do
        execute_profiled_launch(
          client_opts,
          profile_name,
          lease,
          fn -> :ok end,
          mcp_servers,
          fun
        )
      end
    end)
  end

  defp with_profile_lock(worktree_root, fun) do
    # :global lock IDs are {shared_resource, requester}; different session PIDs
    # therefore contend on the worktree resource instead of sharing a lock.
    lock_id = {{__MODULE__, worktree_root}, self()}

    case :global.set_lock(lock_id, [node()], 0) do
      true ->
        try do
          fun.()
        after
          :global.del_lock(lock_id, [node()])
        end

      false ->
        {:error, :grok_sandbox_profile_busy}
    end
  end

  defp do_run_linked_launch(client_opts, authority, mcp_servers, fun) do
    with :ok <- verify_authority(authority, authority.owner, authority.worktree_root),
         :ok <- reject_ambient_mcp_sources(authority.worktree_root),
         {:ok, profile_name} <- profile_name(authority.common_dir),
         {:ok, profile_content} <-
           profile_content(profile_name, authority.worktree_root, [authority.common_dir]),
         :ok <- reject_global_profile_collision(profile_name, client_opts),
         :ok <- reject_preexisting_backup(authority.worktree_root),
         :ok <- recover_orphaned_profile(authority.worktree_root, profile_content),
         {:ok, lease} <- install_profile(authority.worktree_root, profile_content) do
      execute_profiled_launch(
        client_opts,
        profile_name,
        lease,
        fn -> verify_authority(authority, authority.owner, authority.worktree_root) end,
        mcp_servers,
        fun
      )
    end
  end

  defp execute_profiled_launch(client_opts, profile_name, lease, verify, mcp_servers, fun) do
    result =
      with :ok <- verify.() do
        prepared_opts =
          Keyword.put(
            client_opts,
            :command,
            profiled_command(profile_name, mcp_servers)
          )

        fun.(prepared_opts)
      end

    case restore_profile(lease) do
      :ok -> {:ok, result}
      {:error, reason} -> {:error, {:grok_sandbox_cleanup_failed, reason}, result}
    end
  rescue
    exception ->
      _ = restore_profile(lease)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      _ = restore_profile(lease)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp validate_client_opts(client_opts) do
    cond do
      not Keyword.keyword?(client_opts) ->
        {:error, :invalid_acp_client_options}

      Keyword.get(client_opts, :command) != @expected_grok_command ->
        {:error, :grok_sandbox_command_mismatch}

      Keyword.has_key?(client_opts, :cd) ->
        {:error, :grok_sandbox_cwd_override_forbidden}

      Keyword.has_key?(client_opts, :adapter) or Keyword.has_key?(client_opts, :adapter_opts) ->
        {:error, :grok_sandbox_native_transport_required}

      true ->
        :ok
    end
  end

  defp validate_bound_mcp_servers(servers) when is_list(servers) do
    if Enum.all?(servers, &is_map/1),
      do: :ok,
      else: {:error, :invalid_grok_bound_mcp_servers}
  end

  defp validate_bound_mcp_servers(_servers),
    do: {:error, :invalid_grok_bound_mcp_servers}

  defp profiled_command(profile_name, []) do
    List.replace_at(@expected_grok_command, @sandbox_command_index, profile_name)
  end

  defp profiled_command(profile_name, [_server | _rest]) do
    List.replace_at(@grok_command_with_bound_mcp, @sandbox_command_index, profile_name)
  end

  defp reject_ambient_mcp_sources(worktree_root) do
    Enum.reduce_while(@ambient_mcp_relative_paths, :ok, fn relative, :ok ->
      case File.lstat(Path.join([worktree_root | relative])) do
        {:error, :enoent} -> {:cont, :ok}
        _other -> {:halt, {:error, :grok_ambient_mcp_configuration_forbidden}}
      end
    end)
  end

  defp reject_unexpected_authority(nil), do: :ok
  defp reject_unexpected_authority(_authority), do: {:error, :unexpected_grok_sandbox_authority}

  defp verify_authority(authority, expected_owner, worktree_root, metadata \\ nil)

  defp verify_authority(
         %Authority{owner: owner, reference: reference} = authority,
         expected_owner,
         worktree_root,
         metadata
       )
       when is_pid(owner) and is_reference(reference) and owner == expected_owner and
              is_pid(expected_owner) do
    with true <- Process.alive?(owner),
         true <- authority.worktree_root == worktree_root,
         {:ok, current_metadata} <- current_metadata(metadata, worktree_root),
         true <- current_metadata.common_dir == authority.common_dir,
         true <- current_metadata.gitdir == authority.gitdir,
         {:ok, current_common_dir} <- repository_common_dir(authority.repository_root),
         true <- current_common_dir == authority.common_dir,
         {:ok, snapshot} <- capture_snapshot(authority.repository_root, current_metadata),
         true <- snapshot == authority.snapshot do
      :ok
    else
      false -> {:error, :grok_worktree_authority_changed}
      :standalone -> {:error, :grok_worktree_authority_changed}
      {:error, _reason} -> {:error, :grok_worktree_authority_changed}
      _other -> {:error, :grok_worktree_authority_changed}
    end
  end

  defp verify_authority(_authority, _expected_owner, _worktree_root, _metadata),
    do: {:error, :grok_linked_worktree_authority_required}

  defp normalize_authority(%Authority{} = authority), do: {:ok, authority}
  defp normalize_authority(_authority), do: {:error, :invalid_grok_worktree_authority}

  defp current_metadata(nil, worktree_root), do: linked_worktree_metadata(worktree_root)
  defp current_metadata(metadata, _worktree_root), do: {:ok, metadata}

  defp repository_kind(worktree_root) do
    dot_git = Path.join(worktree_root, ".git")

    case File.lstat(dot_git) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, :standalone}
      {:ok, %File.Stat{type: :regular}} -> linked_kind(worktree_root)
      {:error, :enoent} -> reject_nested_repository_cwd(worktree_root)
      _other -> {:error, :invalid_grok_git_metadata}
    end
  end

  defp reject_nested_repository_cwd(worktree_root) do
    if git_metadata_in_ancestor?(Path.dirname(worktree_root)),
      do: {:error, :grok_repository_root_required},
      else: {:ok, :standalone}
  end

  defp git_metadata_in_ancestor?(path) do
    parent = Path.dirname(path)

    case File.lstat(Path.join(path, ".git")) do
      {:error, :enoent} when parent != path -> git_metadata_in_ancestor?(parent)
      {:error, :enoent} -> false
      _other -> true
    end
  end

  defp linked_kind(worktree_root) do
    case linked_worktree_metadata(worktree_root) do
      {:ok, metadata} -> {:ok, {:linked, metadata}}
      {:error, _reason} = error -> error
    end
  end

  defp repository_common_dir(repository_root) do
    dot_git = Path.join(repository_root, ".git")

    case File.lstat(dot_git) do
      {:ok, %File.Stat{type: :directory}} -> canonical_directory(dot_git)
      {:ok, %File.Stat{type: :regular}} -> linked_common_dir(repository_root)
      _other -> {:error, :invalid_grok_repository_root}
    end
  end

  defp linked_common_dir(repository_root) do
    case linked_worktree_metadata(repository_root) do
      {:ok, metadata} -> {:ok, metadata.common_dir}
      _other -> {:error, :invalid_grok_repository_root}
    end
  end

  defp linked_worktree_metadata(worktree_root) do
    dot_git = Path.join(worktree_root, ".git")

    with {:ok, pointer} <- read_bounded_regular(dot_git, @max_metadata_bytes),
         {:ok, gitdir_path} <- parse_gitdir(pointer.content),
         {:ok, gitdir} <- resolve_relative_directory(gitdir_path, Path.dirname(dot_git)),
         {:ok, commondir} <-
           read_bounded_regular(Path.join(gitdir, "commondir"), @max_metadata_bytes),
         {:ok, common_path} <- parse_single_path(commondir.content),
         {:ok, common_dir} <- resolve_relative_directory(common_path, gitdir),
         true <- Path.dirname(gitdir) == Path.join(common_dir, "worktrees"),
         {:ok, backlink} <-
           read_bounded_regular(Path.join(gitdir, "gitdir"), @max_metadata_bytes),
         {:ok, backlink_path} <- parse_single_path(backlink.content),
         {:ok, canonical_backlink} <- resolve_existing_path(backlink_path, gitdir),
         true <- canonical_backlink == dot_git do
      {:ok,
       %{
         dot_git: dot_git,
         gitdir: gitdir,
         common_dir: common_dir,
         commondir_file: Path.join(gitdir, "commondir"),
         backlink_file: Path.join(gitdir, "gitdir")
       }}
    else
      false -> {:error, :invalid_grok_worktree_linkage}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_grok_worktree_linkage}
    end
  end

  defp capture_snapshot(repository_root, metadata) do
    paths = %{
      repository_root: {:directory, repository_root},
      worktree_dot_git: {:file, metadata.dot_git},
      gitdir: {:directory, metadata.gitdir},
      common_dir: {:directory, metadata.common_dir},
      commondir_file: {:file, metadata.commondir_file},
      backlink_file: {:file, metadata.backlink_file}
    }

    Enum.reduce_while(paths, {:ok, %{}}, fn {name, {kind, path}}, {:ok, snapshot} ->
      result =
        case kind do
          :directory -> directory_binding(path)
          :file -> file_binding(path, @max_metadata_bytes)
        end

      case result do
        {:ok, binding} -> {:cont, {:ok, Map.put(snapshot, name, binding)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp canonical_directory(path) do
    with true <- valid_path_string?(path),
         {:ok, canonical} <- SafePath.resolve_real(Path.expand(path)),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(canonical) do
      {:ok, canonical}
    else
      _other -> {:error, :invalid_grok_directory}
    end
  end

  defp resolve_relative_directory(path, relative_to) do
    path
    |> Path.expand(relative_to)
    |> canonical_directory()
  end

  defp resolve_existing_path(path, relative_to) do
    expanded = Path.expand(path, relative_to)

    if valid_path_string?(expanded) do
      case SafePath.resolve_real(expanded) do
        {:ok, canonical} -> {:ok, canonical}
        {:error, _reason} -> {:error, :invalid_grok_worktree_linkage}
      end
    else
      {:error, :invalid_grok_worktree_linkage}
    end
  end

  defp parse_gitdir(content) do
    with "gitdir: " <> path <- trim_one_line(content),
         true <- valid_path_string?(path) do
      {:ok, path}
    else
      _other -> {:error, :invalid_grok_gitdir_pointer}
    end
  end

  defp parse_single_path(content) do
    path = trim_one_line(content)

    if valid_path_string?(path),
      do: {:ok, path},
      else: {:error, :invalid_grok_metadata_path}
  end

  defp trim_one_line(content) when is_binary(content) do
    cond do
      String.ends_with?(content, "\r\n") ->
        binary_part(content, 0, byte_size(content) - 2)

      String.ends_with?(content, "\n") ->
        binary_part(content, 0, byte_size(content) - 1)

      true ->
        content
    end
  end

  defp valid_path_string?(path) do
    is_binary(path) and path != "" and String.valid?(path) and
      not String.contains?(path, [<<0>>, "\n", "\r"])
  end

  defp profile_name(common_dir) do
    digest = :crypto.hash(:sha256, common_dir)

    {:ok,
     @profile_name_prefix <>
       "-" <> (Base.encode16(digest, case: :lower) |> String.slice(0, 24))}
  end

  defp profile_content(profile_name, worktree_root, read_only_paths) do
    denied_paths =
      [
        Path.join([worktree_root, ".grok", @profile_filename]),
        Path.join([worktree_root, ".grok", @backup_filename])
      ] ++ Enum.map(@ambient_mcp_relative_paths, &Path.join([worktree_root | &1]))

    with {:ok, read_only} <- toml_array(read_only_paths),
         {:ok, denied} <- toml_array(denied_paths) do
      read_only_line = if read_only_paths == [], do: [], else: ["read_only = #{read_only}"]

      {:ok,
       ([
          @profile_marker,
          "[profiles.#{profile_name}]",
          ~s(extends = "strict")
        ] ++
          read_only_line ++
          [
            "deny = #{denied}",
            ""
          ])
       |> Enum.join("\n")}
    end
  end

  defp toml_array(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, encoded} ->
      case toml_string(value) do
        {:ok, escaped} -> {:cont, {:ok, [~s("#{escaped}") | encoded]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, "[" <> (encoded |> Enum.reverse() |> Enum.join(", ")) <> "]"}
      {:error, _reason} = error -> error
    end
  end

  defp toml_string(value) when is_binary(value) do
    if String.valid?(value) and not contains_control_character?(value) do
      {:ok,
       value
       |> String.replace("\\", "\\\\")
       |> String.replace("\"", "\\\"")}
    else
      {:error, :unsafe_grok_profile_path}
    end
  end

  defp toml_string(_value), do: {:error, :unsafe_grok_profile_path}

  defp contains_control_character?(value) do
    value
    |> String.to_charlist()
    |> Enum.any?(fn codepoint -> codepoint < 0x20 or codepoint == 0x7F end)
  end

  defp reject_global_profile_collision(profile_name, client_opts) do
    with {:ok, grok_home} <- effective_grok_home(client_opts) do
      profile_path = Path.join(grok_home, @profile_filename)

      case File.lstat(profile_path) do
        {:error, :enoent} ->
          :ok

        {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_profile_bytes ->
          with {:ok, raw} <- File.read(profile_path),
               {:ok, decoded} <- Toml.decode(raw, keys: :strings),
               profiles when is_map(profiles) <- Map.get(decoded, "profiles", %{}) do
            if Map.has_key?(profiles, profile_name),
              do: {:error, :grok_global_profile_conflict},
              else: :ok
          else
            _other -> {:error, :invalid_grok_global_profile}
          end

        _other ->
          {:error, :invalid_grok_global_profile}
      end
    end
  end

  defp effective_grok_home(client_opts) do
    env = Keyword.get(client_opts, :env, [])

    Enum.find_value(env, System.get_env("GROK_HOME"), fn
      {"GROK_HOME", value} when is_binary(value) and value != "" -> value
      _other -> nil
    end)
    |> case do
      nil ->
        {:ok, Path.expand("~/.grok")}

      path when is_binary(path) ->
        if valid_path_string?(path) and Path.type(path) == :absolute,
          do: {:ok, Path.expand(path)},
          else: {:error, :invalid_grok_home}
    end
  end

  defp recover_orphaned_profile(worktree_root, generated_content) do
    profile_path = Path.join([worktree_root, ".grok", @profile_filename])
    backup_path = Path.join([worktree_root, ".grok", @backup_filename])

    case {regular_file_state(profile_path), regular_file_state(backup_path)} do
      {{:ok, _profile}, {:ok, _backup}} ->
        {:error, :ambiguous_grok_profile_recovery}

      {:missing, {:ok, _backup}} ->
        {:error, :ambiguous_grok_profile_recovery}

      {{:ok, profile}, :missing} ->
        if profile.content == generated_content do
          with :ok <- File.rm(profile_path),
               do: remove_empty_recovered_profile_dir(Path.dirname(profile_path))
        else
          :ok
        end

      {:missing, :missing} ->
        :ok

      _other ->
        {:error, :invalid_grok_profile_recovery_state}
    end
  end

  defp reject_preexisting_backup(worktree_root) do
    backup_path = Path.join([worktree_root, ".grok", @backup_filename])

    case File.lstat(backup_path) do
      {:error, :enoent} -> :ok
      _other -> {:error, :ambiguous_grok_profile_recovery}
    end
  end

  defp remove_empty_recovered_profile_dir(profile_dir) do
    case File.ls(profile_dir) do
      {:ok, []} -> File.rmdir(profile_dir)
      {:ok, _entries} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:grok_profile_dir_restore_failed, reason}}
    end
  end

  defp install_profile(worktree_root, generated_content) do
    profile_dir = Path.join(worktree_root, ".grok")
    profile_path = Path.join(profile_dir, @profile_filename)
    backup_path = Path.join(profile_dir, @backup_filename)

    with {:ok, profile_dir_created} <- ensure_profile_dir(profile_dir) do
      case do_install_profile(
             profile_dir,
             profile_path,
             backup_path,
             generated_content,
             profile_dir_created
           ) do
        {:ok, _lease} = success ->
          success

        {:error, reason} ->
          cleanup_result =
            with :ok <- rollback_profile_install(profile_path, backup_path, generated_content),
                 do: cleanup_failed_profile_dir(profile_dir, profile_dir_created)

          case cleanup_result do
            :ok ->
              {:error, reason}

            {:error, cleanup_reason} ->
              {:error, {:grok_profile_install_rollback_failed, reason, cleanup_reason}}
          end
      end
    end
  end

  defp do_install_profile(
         profile_dir,
         profile_path,
         backup_path,
         generated_content,
         profile_dir_created
       ) do
    with {:ok, had_backup} <- move_existing_profile(profile_path, backup_path),
         :ok <- write_generated_profile(profile_dir, profile_path, generated_content),
         {:ok, generated_binding} <- file_binding(profile_path, @max_profile_bytes) do
      {:ok,
       %ProfileLease{
         profile_path: profile_path,
         backup_path: backup_path,
         generated_binding: generated_binding,
         had_backup: had_backup,
         profile_dir_created: profile_dir_created
       }}
    end
  end

  defp cleanup_failed_profile_dir(_profile_dir, false), do: :ok

  defp cleanup_failed_profile_dir(profile_dir, true) do
    case File.ls(profile_dir) do
      {:ok, []} -> File.rmdir(profile_dir)
      {:ok, _entries} -> {:error, :grok_profile_dir_not_empty}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:grok_profile_dir_restore_failed, reason}}
    end
  end

  defp ensure_profile_dir(profile_dir) do
    case File.lstat(profile_dir) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, false}

      {:error, :enoent} ->
        case File.mkdir(profile_dir) do
          :ok -> {:ok, true}
          {:error, reason} -> {:error, {:grok_profile_dir_create_failed, reason}}
        end

      _other ->
        {:error, :invalid_grok_profile_root}
    end
  end

  defp move_existing_profile(profile_path, backup_path) do
    case {regular_file_state(profile_path), File.lstat(backup_path)} do
      {:missing, {:error, :enoent}} ->
        {:ok, false}

      {{:ok, _profile}, {:error, :enoent}} ->
        case File.rename(profile_path, backup_path) do
          :ok -> {:ok, true}
          {:error, reason} -> {:error, {:grok_profile_backup_failed, reason}}
        end

      _other ->
        {:error, :invalid_grok_profile_install_state}
    end
  end

  defp write_generated_profile(profile_dir, profile_path, content) do
    temp_path =
      Path.join(
        profile_dir,
        ".sandbox.toml.arbor-" <>
          Base.encode16(:crypto.strong_rand_bytes(12), case: :lower) <> ".tmp"
      )

    result =
      with :ok <- write_exclusive(temp_path, content),
           :ok <- File.chmod(temp_path, 0o600),
           :ok <- File.rename(temp_path, profile_path) do
        :ok
      else
        {:error, reason} -> {:error, {:grok_profile_write_failed, reason}}
      end

    _ = File.rm(temp_path)
    result
  end

  defp write_exclusive(path, content) do
    File.open(path, [:write, :binary, :exclusive], fn io -> IO.binwrite(io, content) end)
    |> case do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore_profile(%ProfileLease{} = lease) do
    with {:ok, current_binding} <- file_binding(lease.profile_path, @max_profile_bytes),
         true <- current_binding == lease.generated_binding,
         :ok <- File.rm(lease.profile_path),
         :ok <- maybe_restore_backup(lease),
         :ok <- maybe_remove_profile_dir(lease) do
      :ok
    else
      false -> {:error, :grok_generated_profile_changed}
      {:error, _reason} = error -> error
      _other -> {:error, :grok_profile_restore_failed}
    end
  end

  defp maybe_restore_backup(%ProfileLease{had_backup: true} = lease) do
    case File.rename(lease.backup_path, lease.profile_path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:grok_profile_restore_failed, reason}}
    end
  end

  defp maybe_restore_backup(%ProfileLease{had_backup: false}), do: :ok

  defp maybe_remove_profile_dir(%ProfileLease{profile_dir_created: true, profile_path: path}) do
    profile_dir = Path.dirname(path)

    case File.ls(profile_dir) do
      {:ok, []} ->
        case File.rmdir(profile_dir) do
          :ok -> :ok
          {:error, reason} -> {:error, {:grok_profile_dir_restore_failed, reason}}
        end

      {:ok, _entries} ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:grok_profile_dir_restore_failed, reason}}
    end
  end

  defp maybe_remove_profile_dir(%ProfileLease{profile_dir_created: false}), do: :ok

  defp rollback_profile_install(profile_path, backup_path, generated_content) do
    with :ok <- remove_generated_for_rollback(profile_path, generated_content),
         do: restore_backup_for_rollback(profile_path, backup_path)
  end

  defp remove_generated_for_rollback(profile_path, generated_content) do
    case regular_file_state(profile_path) do
      {:ok, %{content: ^generated_content}} -> File.rm(profile_path)
      :missing -> :ok
      _other -> {:error, :ambiguous_grok_profile_rollback}
    end
  end

  defp restore_backup_for_rollback(profile_path, backup_path) do
    case {File.lstat(profile_path), File.lstat(backup_path)} do
      {{:error, :enoent}, {:ok, %File.Stat{type: :regular}}} ->
        File.rename(backup_path, profile_path)

      {_profile, {:error, :enoent}} ->
        :ok

      _other ->
        {:error, :ambiguous_grok_profile_rollback}
    end
  end

  defp regular_file_state(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :missing

      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_profile_bytes ->
        read_bounded_regular(path, @max_profile_bytes)

      _other ->
        {:error, :invalid_file}
    end
  end

  defp directory_binding(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok,
         %{
           type: stat.type,
           major_device: stat.major_device,
           minor_device: stat.minor_device,
           inode: stat.inode
         }}

      _other ->
        {:error, :invalid_grok_directory_binding}
    end
  end

  defp file_binding(path, max_bytes) do
    with {:ok, file} <- read_bounded_regular(path, max_bytes) do
      {:ok,
       %{
         identity: file.identity,
         sha256: :crypto.hash(:sha256, file.content)
       }}
    end
  end

  defp read_bounded_regular(path, max_bytes) do
    with {:ok, %File.Stat{type: :regular, size: size} = before} <- File.lstat(path),
         true <- size <= max_bytes,
         {:ok, content} <- File.read(path),
         true <- byte_size(content) <= max_bytes,
         {:ok, %File.Stat{type: :regular} = after_stat} <- File.lstat(path),
         true <- stat_identity(before) == stat_identity(after_stat) do
      {:ok, %{content: content, identity: stat_identity(after_stat)}}
    else
      _other -> {:error, :invalid_or_racing_grok_file}
    end
  end

  defp stat_identity(stat) do
    %{
      type: stat.type,
      mode: stat.mode &&& 0o7777,
      size: stat.size,
      mtime: stat.mtime,
      ctime: stat.ctime,
      major_device: stat.major_device,
      minor_device: stat.minor_device,
      inode: stat.inode
    }
  end
end
