defmodule Mix.Tasks.Arbor.Orchestrate do
  @shortdoc "Run multi-agent orchestration with parallel ACP sessions"
  @moduledoc """
  Spawns parallel ACP coding agents to work on a goal, optionally merging results.

  ## Usage

      mix arbor.orchestrate "Build authentication system" --agents claude,codex
      mix arbor.orchestrate "Fix all credo warnings" --agents claude --no-plan
      mix arbor.orchestrate --pipeline specs/pipelines/multi-agent-orchestrate.dot

  ## Options

    - `--agents` — comma-separated agent list: claude, codex, gemini, opencode, goose (default: claude)
    - `--parallel` — max concurrent branches (default: agent count)
    - `--workdir` — base working directory for agents (default: project root)
    - `--pipeline` — use an existing DOT file instead of generating one
    - `--merge` — auto-merge completed worktree branches into current branch
    - `--no-plan` — skip planning phase, send goal directly to all agents
    - `--no-worktree` — skip worktree creation (agents work in workdir directly)
    - `--logs-root` — directory for pipeline logs
    - `--set key=value` — set initial context values (repeatable)
    - `--cleanup` — remove worktrees after completion
  """

  use Mix.Task

  import Arbor.Orchestrator.Mix.Helpers

  alias Arbor.Orchestrator.Templates.Orchestrate, as: OrchestrateTemplate
  alias Mix.Tasks.Arbor.HandsHelpers, as: Hands

  @known_agents ~w(claude codex gemini opencode goose aider cline)

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          agents: :string,
          parallel: :integer,
          workdir: :string,
          pipeline: :string,
          merge: :boolean,
          no_plan: :boolean,
          no_worktree: :boolean,
          logs_root: :string,
          set: :keep,
          cleanup: :boolean
        ],
        aliases: [n: :parallel]
      )

    Mix.Task.run("compile")
    ensure_orchestrator_started()
    ensure_ai_started()

    goal = parse_goal(positional, opts)
    agents = parse_agents(opts)
    use_worktree = !Keyword.get(opts, :no_worktree, false)
    base_workdir = resolve_workdir(opts)
    run_id = timestamp_id()

    info("\nOrchestration: #{goal}")
    info("  Agents: #{Enum.join(agents, ", ")}")
    info("  Worktrees: #{use_worktree}")
    info(String.duplicate("-", 50))

    # Set up worktrees
    branches = setup_branches(agents, base_workdir, use_worktree, run_id)

    # Get or generate the DOT pipeline
    dot_source = resolve_dot(goal, branches, opts)

    # Authenticate operator (human identity via OIDC or fallback)
    {agent_id, signer} = authenticate_operator()

    # Build run options
    run_opts = build_run_opts(opts, run_id)

    # Thread authentication into run options
    run_opts =
      if signer do
        run_opts
        |> Keyword.put(:signer, signer)
        |> Keyword.update(:initial_values, %{"session.agent_id" => agent_id}, fn vals ->
          Map.put(vals, "session.agent_id", agent_id)
        end)
      else
        run_opts
      end

    # Execute
    case Arbor.Orchestrator.run(dot_source, run_opts) do
      {:ok, result} ->
        info("")
        success("Orchestration completed!")
        info("  Nodes completed: #{length(result.completed_nodes)}")
        print_branch_summary(branches, result)

        if Keyword.get(opts, :merge, false) do
          merge_branches(branches)
        end

        if Keyword.get(opts, :cleanup, false) do
          cleanup_branches(branches)
        end

      {:error, reason} ->
        error("\nOrchestration failed: #{inspect(reason)}")

        if Keyword.get(opts, :cleanup, false) do
          cleanup_branches(branches)
        end

        System.halt(1)
    end
  end

  # -- Parsing --

  defp parse_goal(positional, opts) do
    goal = Enum.join(positional, " ")

    cond do
      goal != "" ->
        goal

      opts[:pipeline] ->
        "Run pipeline: #{opts[:pipeline]}"

      true ->
        error("Usage: mix arbor.orchestrate \"goal\" --agents claude,codex [options]")
        System.halt(1)
    end
  end

  defp parse_agents(opts) do
    agents =
      opts
      |> Keyword.get(:agents, "claude")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    Enum.each(agents, fn agent ->
      unless agent in @known_agents do
        error("Unknown agent: #{agent}. Known: #{Enum.join(@known_agents, ", ")}")
        System.halt(1)
      end
    end)

    agents
  end

  defp resolve_workdir(opts) do
    case Keyword.get(opts, :workdir) do
      nil ->
        File.cwd!()

      dir ->
        resolved = Path.expand(dir)

        unless File.dir?(resolved) do
          error("Directory not found: #{resolved}")
          System.halt(1)
        end

        resolved
    end
  end

  # -- Branch setup --

  defp setup_branches(agents, base_workdir, use_worktree, run_id) do
    agents
    |> Enum.with_index()
    |> Enum.map(fn {agent, idx} ->
      branch_name = "orch-#{run_id}-#{agent}-#{idx}"

      workdir =
        if use_worktree do
          case Hands.create_worktree(branch_name) do
            {:ok, wt_path} ->
              info("  Created worktree: #{branch_name}")
              wt_path

            {:error, reason} ->
              error("Failed to create worktree for #{branch_name}: #{reason}")
              System.halt(1)
          end
        else
          base_workdir
        end

      %{
        name: "branch_#{idx}",
        agent: agent,
        workdir: workdir,
        worktree_name: branch_name,
        use_worktree: use_worktree,
        tools: "file_read,file_write,file_search,file_glob,shell"
      }
    end)
  end

  # -- DOT resolution --

  defp resolve_dot(goal, branches, opts) do
    case Keyword.get(opts, :pipeline) do
      path when is_binary(path) ->
        unless File.exists?(path) do
          error("Pipeline file not found: #{path}")
          System.halt(1)
        end

        File.read!(path)

      nil ->
        gen_opts = [
          max_parallel: Keyword.get(opts, :parallel, length(branches)),
          no_plan: Keyword.get(opts, :no_plan, false)
        ]

        OrchestrateTemplate.generate(goal, branches, gen_opts)
    end
  end

  # -- Run options --

  defp build_run_opts(opts, run_id) do
    logs_root = Keyword.get(opts, :logs_root, ".arbor/orchestrate/#{run_id}")
    initial_values = parse_set_opts(opts)

    run_opts =
      [
        logs_root: logs_root,
        on_event: &print_event/1,
        on_stream: &print_stream_event/1,
        cache: false
      ]

    run_opts =
      if initial_values != %{} do
        Keyword.put(run_opts, :initial_values, initial_values)
      else
        run_opts
      end

    run_opts
  end

  defp parse_set_opts(opts) do
    opts
    |> Keyword.get_values(:set)
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [key, value] ->
          Map.put(acc, key, maybe_parse_value(value))

        _ ->
          warn("Ignoring malformed --set: #{pair}")
          acc
      end
    end)
  end

  defp maybe_parse_value(value) do
    case Jason.decode(value) do
      {:ok, parsed} -> parsed
      {:error, _} -> value
    end
  end

  # -- Merge --

  defp merge_branches(branches) do
    worktree_branches = Enum.filter(branches, & &1.use_worktree)

    if worktree_branches == [] do
      info("\nNo worktrees to merge.")
      return_ok()
    end

    info("\nMerging branches...")

    Enum.each(worktree_branches, fn branch ->
      case merge_worktree(branch) do
        {:ok, _} ->
          success("  Merged: #{branch.worktree_name}")

        {:conflict, details} ->
          warn("  Conflict in #{branch.worktree_name}: #{inspect(details.files)}")

        {:error, reason} ->
          error("  Failed to merge #{branch.worktree_name}: #{reason}")
      end
    end)
  end

  defp merge_worktree(branch) do
    if Code.ensure_loaded?(Arbor.AI.AcpMerge) do
      apply(Arbor.AI.AcpMerge, :merge_worktree, [
        branch.workdir,
        "main",
        [cwd: File.cwd!()]
      ])
    else
      {:error, "AcpMerge not available"}
    end
  end

  # -- Cleanup --

  defp cleanup_branches(branches) do
    worktree_branches = Enum.filter(branches, & &1.use_worktree)

    if worktree_branches != [] do
      info("\nCleaning up worktrees...")

      Enum.each(worktree_branches, fn branch ->
        case Hands.remove_worktree(branch.worktree_name) do
          :ok ->
            Hands.delete_worktree_branch(branch.worktree_name, force: true)
            info("  Removed: #{branch.worktree_name}")

          {:error, reason} ->
            warn("  Failed to remove #{branch.worktree_name}: #{reason}")
        end
      end)
    end
  end

  # -- Output --

  defp print_branch_summary(branches, result) do
    parallel_results = get_in_context(result, "parallel.results")

    if is_list(parallel_results) do
      info("\n  Branch results:")

      Enum.zip(branches, parallel_results)
      |> Enum.each(fn {branch, res} ->
        status = Map.get(res, "status", "unknown")
        agent = branch.agent

        case status do
          "success" -> success("    #{agent}: completed")
          "fail" -> error("    #{agent}: failed")
          other -> info("    #{agent}: #{other}")
        end
      end)
    end
  end

  defp get_in_context(result, key) do
    case result do
      %{context: context} when is_map(context) -> Map.get(context, key)
      _ -> nil
    end
  end

  defp print_event(%{type: :parallel_started, branch_count: n}) do
    info("  Forking into #{n} parallel branches...")
  end

  defp print_event(%{type: :stage_started, node_id: id}) do
    info("  ▶ #{id}")
  end

  defp print_event(%{type: :stage_completed, node_id: id, status: status}) do
    case status do
      :success -> Mix.shell().info([:green, "  ✓ #{id}"])
      :skipped -> Mix.shell().info([:yellow, "  ⊘ #{id} (skipped)"])
      other -> info("  • #{id} (#{other})")
    end
  end

  defp print_event(%{type: :stage_failed, node_id: id, error: err}) do
    Mix.shell().error([:red, "  ✗ #{id}: #{err}"])
  end

  defp print_event(_), do: :ok

  defp print_stream_event(%{type: :tool_use, name: name}) do
    IO.write(" [#{name}]")
  end

  defp print_stream_event(%{type: :thinking}), do: IO.write(".")
  defp print_stream_event(_), do: :ok

  defp ensure_ai_started do
    Application.ensure_all_started(:arbor_ai)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp timestamp_id do
    {{y, m, d}, {h, min, s}} = :calendar.local_time()

    :io_lib.format("~4..0B~2..0B~2..0B-~2..0B~2..0B~2..0B", [y, m, d, h, min, s])
    |> IO.iodata_to_binary()
  end

  defp return_ok, do: :ok

  # -- Authentication --

  defp authenticate_operator do
    if oidc_available?() and oidc_enabled?() do
      authenticate_with_oidc()
    else
      warn("OIDC not configured — running without human identity authentication")
      {nil, nil}
    end
  end

  defp authenticate_with_oidc do
    # Try cached token first
    case apply(Arbor.Security.OIDC, :load_cached_token, []) do
      {:ok, cache_data} ->
        id_token = get_in(cache_data, ["token_response", "id_token"])

        case apply(Arbor.Security, :authenticate_oidc_token, [id_token]) do
          {:ok, agent_id, signer} ->
            success("Authenticated: #{agent_id}")
            {agent_id, signer}

          {:error, reason} ->
            warn("Cached token invalid (#{inspect(reason)}), starting device flow...")
            run_device_flow()
        end

      :expired ->
        # Try refresh
        try_refresh_or_device_flow()

      {:error, _} ->
        run_device_flow()
    end
  end

  defp try_refresh_or_device_flow do
    with {:ok, cache_data} <- apply(Arbor.Security.OIDC, :load_cached_token, []),
         refresh_token when is_binary(refresh_token) <-
           get_in(cache_data, ["token_response", "refresh_token"]),
         config when not is_nil(config) <- apply(Arbor.Security.OIDC.Config, :device_flow, []),
         {:ok, new_tokens} <-
           apply(Arbor.Security.OIDC.DeviceFlow, :refresh, [config, refresh_token]),
         id_token when is_binary(id_token) <- Map.get(new_tokens, "id_token"),
         {:ok, agent_id, signer} <- apply(Arbor.Security, :authenticate_oidc_token, [id_token]) do
      success("Re-authenticated via refresh: #{agent_id}")
      {agent_id, signer}
    else
      _ -> run_device_flow()
    end
  end

  defp run_device_flow do
    case apply(Arbor.Security, :authenticate_oidc, []) do
      {:ok, agent_id, signer} ->
        success("Authenticated: #{agent_id}")
        {agent_id, signer}

      {:error, reason} ->
        warn("OIDC authentication failed: #{inspect(reason)}")
        warn("Continuing without authentication")
        {nil, nil}
    end
  end

  defp oidc_available? do
    Code.ensure_loaded?(Arbor.Security.OIDC) and
      Code.ensure_loaded?(Arbor.Security.OIDC.Config)
  end

  defp oidc_enabled? do
    # Mix.Task.run("compile") can reload config, losing runtime.exs values.
    # Re-apply OIDC config from env vars if needed.
    ensure_oidc_config()

    apply(Arbor.Security.OIDC.Config, :enabled?, [])
  rescue
    _ -> false
  end

  defp ensure_oidc_config do
    case Application.get_env(:arbor_security, :oidc) do
      config when is_list(config) and config != [] ->
        :ok

      _ ->
        issuer = System.get_env("OIDC_ISSUER")
        client_id = System.get_env("OIDC_CLIENT_ID")

        if issuer && client_id do
          client_secret = System.get_env("OIDC_CLIENT_SECRET")

          scopes =
            case System.get_env("OIDC_SCOPES") do
              nil -> ["openid", "email", "profile"]
              s -> String.split(s, ",", trim: true) |> Enum.map(&String.trim/1)
            end

          provider = %{issuer: issuer, client_id: client_id, scopes: scopes}

          provider =
            if client_secret, do: Map.put(provider, :client_secret, client_secret), else: provider

          device_flow_enabled =
            case System.get_env("OIDC_DEVICE_FLOW") do
              val when val in ["false", "0", "no"] -> false
              _ -> true
            end

          config = [providers: [provider]]

          device_client_id = System.get_env("OIDC_DEVICE_CLIENT_ID") || client_id

          config =
            if device_flow_enabled,
              do:
                Keyword.put(config, :device_flow, %{
                  issuer: issuer,
                  client_id: device_client_id,
                  scopes: scopes
                }),
              else: config

          Application.put_env(:arbor_security, :oidc, config)
        end
    end
  end
end
