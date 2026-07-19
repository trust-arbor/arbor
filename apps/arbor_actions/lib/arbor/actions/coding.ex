defmodule Arbor.Actions.Coding do
  @moduledoc """
  Coding-agent orchestration actions.

  These actions compose existing primitives into reviewable software-change
  workflows. The v0 path delegates implementation to an ACP coding agent, then
  validates and hands the result back as a human-reviewed branch/PR.

  Workspace lease primitives live under `Arbor.Actions.Coding.Workspace`
  (`acquire` / `inspect` / `release`) and are monitored by
  `Arbor.Actions.Coding.WorkspaceLeaseRegistry`.
  """

  defmodule ProduceReviewableChange do
    @moduledoc """
    Produce a reviewable code change in an isolated git worktree.

    The action acquires a monitored workspace lease (worktree/branch), starts an
    ACP coding-agent session in `permission_mode: :default`, asks it to implement
    the requested task, runs validation commands, and commits the result. It can
    optionally open a draft PR, but never merges its own work.

    On every normal return the worktree is retained. Owner-death / hard
    cancellation is handled by `WorkspaceLeaseRegistry`: child validation
    resources are cleaned, reused paths always survive, pristine owned
    worktrees are removed, and dirty or advanced-HEAD owned work is converted
    to the registry's bounded-TTL retained lease (exact task+principal
    reactivation), rather than destroyed.
    """

    use Jido.Action,
      name: "coding_produce_reviewable_change",
      description:
        "Delegate a task to an ACP coding agent and return a validated reviewable branch",
      category: "coding",
      tags: ["coding", "acp", "agent", "git", "pr"],
      schema: [
        task: [
          type: :string,
          required: true,
          doc: "Implementation task for the ACP coding agent"
        ],
        acp_agent: [
          type: :string,
          doc:
            "ACP provider/agent to run (default from :arbor_actions, :coding_default_acp_agent)"
        ],
        repo_path: [
          type: :string,
          required: true,
          doc: "Repository root path"
        ],
        base_ref: [
          type: :string,
          doc: "Git ref to branch from (default: HEAD)"
        ],
        branch_name: [
          type: :string,
          doc: "Branch name to create"
        ],
        worktree_base_dir: [
          type: :string,
          doc: "Directory where the temporary worktree should be created"
        ],
        validation_commands: [
          type: {:list, :string},
          doc:
            "Commands to run after the ACP coding agent edits. " <>
              "Omit for the default mix compile (shared host deps). " <>
              "Pass [] or skip_validation: true to skip validation."
        ],
        skip_validation: [
          type: :boolean,
          default: false,
          doc: "Skip post-edit validation entirely (smoke tests / docs-only diagnostics)"
        ],
        pr_title: [
          type: :string,
          doc: "Draft PR title"
        ],
        pr_body: [
          type: :string,
          doc: "Additional draft PR body"
        ],
        open_pr: [
          type: :boolean,
          default: false,
          doc: "Open a draft PR after committing the branch"
        ],
        submit_review: [
          type: :boolean,
          default: true,
          doc: "Submit the committed branch diff to the code-review council"
        ],
        model: [
          type: :string,
          doc: "ACP provider model override"
        ],
        allowed_tools: [
          type: {:list, :string},
          doc: "ACP adapter tool allowlist"
        ],
        disallowed_tools: [
          type: {:list, :string},
          doc: "ACP adapter tool denylist"
        ],
        timeout: [
          type: :non_neg_integer,
          doc: "Optional hard wall-clock cap for ACP implementation in milliseconds"
        ],
        inactivity_timeout_ms: [
          type: :non_neg_integer,
          doc: "ACP implementation inactivity timeout in milliseconds"
        ],
        review_timeout: [
          type: :non_neg_integer,
          doc: "Code-review council timeout in milliseconds"
        ],
        validation_timeout: [
          type: :non_neg_integer,
          doc: "Per-validation-command timeout in milliseconds"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.{Acp, Council, Git, Shell}
    alias Arbor.Actions.Coding.Workspace
    alias Arbor.Actions.Mix, as: MixActions

    @default_validation_commands ["./bin/mix compile --warnings-as-errors"]
    @default_timeout 900_000
    @default_validation_timeout 300_000
    @default_approval_timeout 60_000
    @default_acp_agent "codex"

    def taint_roles do
      %{
        task: {:control, requires: [:prompt_injection]},
        acp_agent: :control,
        repo_path: {:control, requires: [:path_traversal]},
        base_ref: {:control, requires: [:command_injection]},
        branch_name: {:control, requires: [:command_injection]},
        worktree_base_dir: {:control, requires: [:path_traversal]},
        validation_commands: {:control, requires: [:command_injection]},
        skip_validation: :control,
        pr_title: {:control, requires: [:command_injection]},
        pr_body: {:control, requires: [:command_injection]},
        open_pr: :control,
        submit_review: :control,
        model: :control,
        allowed_tools: :control,
        disallowed_tools: :control,
        timeout: :data,
        inactivity_timeout_ms: :data,
        review_timeout: :data,
        validation_timeout: :data
      }
    end

    # The action sends source/task context to an external coding agent and may
    # optionally open a draft PR. Treat it as egress even though it also writes locally.
    def effect_class, do: :network_egress
    def egress_tier(_params, _context), do: :external_peer

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(%{task: task, repo_path: repo_path} = params, context) do
      Actions.emit_started(__MODULE__, %{repo_path: repo_path, task: task})

      # Workspace lease owns worktree lifecycle + owner-death cleanup (registry
      # monitor). On every normal return we retain so declined / no_changes /
      # validation_failed / success keep the worktree for inspection.
      with {:ok, workspace} <- acquire_workspace(params, context) do
        repo_root = map_value(workspace, :repo_path)
        worktree_path = map_value(workspace, :worktree_path)
        branch_name = map_value(workspace, :branch)
        workspace_id = map_value(workspace, :workspace_id)

        try do
          with {:ok, session} <- start_acp_session(worktree_path, params, context),
               {:ok, response} <- prompt_acp_agent(session, worktree_path, params, context) do
            maybe_close_session(session, context)

            case finish_change(
                   repo_root,
                   worktree_path,
                   branch_name,
                   response,
                   params,
                   context,
                   workspace
                 ) do
              {:ok, result} when is_map(result) ->
                {:ok, attach_response_usage_metrics(result, response)}

              other ->
                other
            end
          else
            {:error, reason} ->
              Actions.emit_failed(__MODULE__, reason)
              {:error, reason}
          end
        after
          release_workspace(workspace_id, "retain", context)
        end
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    def run(_params, _context), do: {:error, "task and repo_path are required"}

    defp acquire_workspace(params, context) do
      acquire_params =
        %{repo_path: get_param(params, :repo_path)}
        |> put_if_present(:base_ref, get_param(params, :base_ref))
        |> put_if_present(:branch_name, get_param(params, :branch_name))
        |> put_if_present(:worktree_base_dir, get_param(params, :worktree_base_dir))
        |> put_if_present(:task, get_param(params, :task))

      call_action(Workspace.Acquire, acquire_params, context)
    end

    defp release_workspace(workspace_id, mode, context) when is_binary(workspace_id) do
      _ =
        call_action(
          Workspace.Release,
          %{workspace_id: workspace_id, mode: mode},
          context
        )

      :ok
    end

    defp release_workspace(_workspace_id, _mode, _context), do: :ok

    defp finish_change(
           repo_root,
           worktree_path,
           branch_name,
           response,
           params,
           context,
           workspace
         ) do
      base_commit = map_value(workspace, :base_commit)
      inspection = Workspace.inspect_worktree(worktree_path, base_commit)

      cond do
        declined?(response) ->
          result = %{
            status: "declined",
            branch: branch_name,
            worktree_path: worktree_path,
            acp_agent: selected_acp_agent(params),
            response_text: response_text(response)
          }

          Actions.emit_completed(__MODULE__, result)
          {:ok, result}

        # Clean and HEAD still at acquire base: truly no reviewable change.
        not inspection.changed_from_base ->
          result = %{
            status: "no_changes",
            branch: branch_name,
            worktree_path: worktree_path,
            acp_agent: selected_acp_agent(params),
            response_text: response_text(response)
          }

          Actions.emit_completed(__MODULE__, result)
          {:ok, result}

        # Dirty worktree: wrapper owns the commit after validation.
        inspection.dirty == true ->
          complete_after_edits(
            repo_root,
            worktree_path,
            branch_name,
            response,
            params,
            context,
            workspace,
            :commit
          )

        # Clean but HEAD advanced (ACP worker already committed): adopt HEAD.
        true ->
          complete_after_edits(
            repo_root,
            worktree_path,
            branch_name,
            response,
            params,
            context,
            workspace,
            {:adopt, inspection.head_commit}
          )
      end
    end

    defp complete_after_edits(
           repo_root,
           worktree_path,
           branch_name,
           response,
           params,
           context,
           workspace,
           commit_mode
         ) do
      validation_context = put_workspace_id_context(context, workspace)

      with {:ok, before_binding} <-
             Arbor.Actions.Mix.committable_tree_binding(worktree_path),
           {:ok, validations} <- run_validations(worktree_path, params, validation_context),
           {:ok, after_binding} <-
             Arbor.Actions.Mix.committable_tree_binding(worktree_path),
           :ok <- assert_validation_tree_stable(before_binding, after_binding),
           {:ok, commit} <-
             resolve_reviewable_commit(repo_root, worktree_path, params, context, commit_mode),
           :ok <- assert_commit_matches_validated_tree(worktree_path, before_binding, commit) do
        result =
          finalize_committed_change(
            repo_root,
            worktree_path,
            branch_name,
            response,
            validations,
            params,
            context,
            commit,
            workspace
          )

        Actions.emit_completed(__MODULE__, result)
        {:ok, result}
      else
        {:validation_failed, validations} ->
          result = %{
            status: "validation_failed",
            repo_path: repo_root,
            worktree_path: worktree_path,
            branch: branch_name,
            acp_agent: selected_acp_agent(params),
            validation: validations,
            response_text: response_text(response)
          }

          Actions.emit_completed(__MODULE__, result)
          {:ok, result}

        {:error, :validation_tree_mutated} ->
          result = %{
            status: "validation_failed",
            repo_path: repo_root,
            worktree_path: worktree_path,
            branch: branch_name,
            acp_agent: selected_acp_agent(params),
            validation: [
              %{
                command: "validation_tree_binding",
                passed: false,
                exit_code: nil,
                stdout: "",
                stderr:
                  "committable tree mutated during validation; refusing commit without re-validation"
              }
            ],
            response_text: response_text(response)
          }

          Actions.emit_completed(__MODULE__, result)
          {:ok, result}

        {:pr_failed, reason, commit} ->
          result = %{
            status: "pr_failed",
            repo_path: repo_root,
            worktree_path: worktree_path,
            branch: branch_name,
            commit: commit[:commit_hash] || commit["commit_hash"],
            acp_agent: selected_acp_agent(params),
            error: reason,
            validation: [],
            response_text: response_text(response)
          }

          Actions.emit_completed(__MODULE__, result)
          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp resolve_reviewable_commit(repo_root, worktree_path, params, context, :commit) do
      commit_change(repo_root, worktree_path, params, context)
    end

    defp resolve_reviewable_commit(
           _repo_root,
           _worktree_path,
           _params,
           _context,
           {:adopt, head_commit}
         )
         when is_binary(head_commit) and head_commit != "" do
      {:ok, %{commit_hash: head_commit}}
    end

    defp resolve_reviewable_commit(_repo_root, _worktree_path, _params, _context, {:adopt, _}) do
      {:error, "ACP self-commit advanced HEAD but commit hash is unavailable"}
    end

    defp start_acp_session(worktree_path, params, context) do
      start_params =
        %{
          provider: selected_acp_agent(params),
          cwd: worktree_path,
          permission_mode: "default",
          timeout: positive_timeout(get_param(params, :timeout), @default_timeout)
        }
        |> put_if_present(:model, get_param(params, :model))
        |> put_if_present(:allowed_tools, get_param(params, :allowed_tools))
        |> put_if_present(:disallowed_tools, get_param(params, :disallowed_tools))

      call_action(Acp.StartSession, start_params, context)
    end

    defp prompt_acp_agent(session, worktree_path, params, context) do
      prompt_params =
        session
        |> session_handle_params()
        |> Map.put(:prompt, build_prompt(worktree_path, params))
        |> put_if_present(:timeout, positive_timeout_or_nil(get_param(params, :timeout)))
        |> put_if_present(
          :inactivity_timeout_ms,
          positive_timeout_or_nil(get_param(params, :inactivity_timeout_ms))
        )

      call_action(Acp.SendMessage, prompt_params, context)
    end

    # LLMs often pass timeout: 0 or timeout: 1 for optional fields; those would
    # abort GenServer.call / ACP create_session immediately. Require a floor.
    @min_sensible_timeout_ms 10_000

    defp positive_timeout(value, default) do
      case value do
        t when is_integer(t) and t >= @min_sensible_timeout_ms -> t
        _ -> default
      end
    end

    defp positive_timeout_or_nil(value) do
      case value do
        t when is_integer(t) and t >= @min_sensible_timeout_ms -> t
        _ -> nil
      end
    end

    defp maybe_close_session(session, context) do
      case session_handle_params(session) do
        params when map_size(params) > 0 ->
          call_action(Acp.CloseSession, params, context)

        _ ->
          :ok
      end

      :ok
    end

    # Prefer managed worker_session_id; fall back to legacy session_pid for
    # injected-test fakes. Never stringify a PID into a durable handle.
    defp session_handle_params(session) when is_map(session) do
      worker = session[:worker_session_id] || session["worker_session_id"]

      cond do
        is_binary(worker) and worker != "" ->
          %{worker_session_id: worker}

        true ->
          case session[:session_pid] || session["session_pid"] do
            nil -> %{}
            "" -> %{}
            pid -> %{session_pid: pid}
          end
      end
    end

    defp session_handle_params(_), do: %{}

    defp build_prompt(worktree_path, params) do
      validation =
        params
        |> validation_commands()
        |> Enum.map_join("\n", &"- #{&1}")

      """
      You are implementing an Arbor code change inside this git worktree:
      #{worktree_path}

      Task:
      #{get_param(params, :task)}

      Requirements:
      - Work only inside the provided worktree.
      - Produce a reviewable diff; do not merge, push, or open a PR yourself.
      - Add or update focused tests when behavior changes.
      - If the task is underspecified or unsafe, do not edit files and begin your response with `STATUS: declined`.
      - If you implemented the task, begin your response with `STATUS: implemented`.

      Validation commands Arbor will run after your turn:
      #{validation}
      """
    end

    defp declined?(response) do
      Regex.match?(~r/^\s*STATUS:\s*declined\b/im, response_text(response))
    end

    defp response_text(response), do: to_string(response[:text] || response["text"] || "")

    # Preserve already-returned ACP usage on the action result so the legacy
    # executor can surface it under metrics without a second provider call.
    defp attach_response_usage_metrics(result, response)
         when is_map(result) and is_map(response) do
      case response_usage(response) do
        usage when is_map(usage) and map_size(usage) > 0 ->
          metrics =
            result
            |> map_value(:metrics)
            |> case do
              existing when is_map(existing) and not is_struct(existing) -> existing
              _ -> %{}
            end

          Map.put(result, :metrics, Map.put(metrics, :usage, usage))

        _ ->
          result
      end
    end

    defp attach_response_usage_metrics(result, _response), do: result

    defp response_usage(response) when is_map(response) do
      case map_value(response, :usage) do
        usage when is_map(usage) and not is_struct(usage) and map_size(usage) > 0 -> usage
        _ -> nil
      end
    end

    defp response_usage(_response), do: nil

    defp run_validations(worktree_path, params, context) do
      commands = validation_commands(params)

      if commands == [] do
        {:ok, []}
      else
        validations =
          Enum.map(commands, fn command ->
            run_validation(worktree_path, command, params, context)
          end)

        if Enum.all?(validations, & &1.passed) do
          {:ok, validations}
        else
          {:validation_failed, validations}
        end
      end
    end

    defp run_validation(worktree_path, command, params, context) do
      # Same class of LLM footgun as ACP timeout: validation_timeout: 0/1 is
      # truthy in Elixir, so `|| @default` does not apply, and Shell.Executor
      # treats a tiny timeout as an immediate kill (exit_code 137).
      timeout =
        positive_timeout(get_param(params, :validation_timeout), @default_validation_timeout)

      invocation = validation_invocation(worktree_path, command, timeout, context)

      case run_validation_invocation(invocation, context) do
        {:ok, result} when is_map(result) ->
          validation_result(command, result)

        {:ok, :pending_approval, proposal_id} ->
          emit_awaiting_approval_signal(proposal_id, invocation.resource_uri, context, command)
          retry_validation_after_approval(command, invocation, proposal_id, context)

        {:error, reason} ->
          %{
            command: command,
            passed: false,
            exit_code: nil,
            stdout: "",
            stderr: to_string(reason)
          }
      end
    end

    defp validation_invocation(worktree_path, command, timeout, context) do
      case mix_action_invocation(worktree_path, command, timeout, context) do
        {:ok, invocation} ->
          invocation

        {:error, :workspace_id_required} ->
          %{
            kind: :missing_workspace,
            error: :workspace_id_required,
            resource_uri: "arbor://action/mix/compile"
          }

        {:error, :unsupported_mix_validation_command = reason} ->
          %{
            kind: :unsupported_mix,
            error: reason,
            resource_uri: "arbor://action/mix"
          }

        {:error, reason}
        when reason in [
               :invalid_mix_compile_args,
               :invalid_mix_test_args,
               :invalid_mix_format_args,
               :invalid_mix_xref_args
             ] ->
          %{
            kind: :unsupported_mix,
            error: reason,
            resource_uri: "arbor://action/mix"
          }

        # Non-mix commands may still use shell. Mix project-code commands never
        # fall through here.
        :error ->
          params = %{command: command, cwd: worktree_path, timeout: timeout, sandbox: :basic}

          %{
            kind: :shell,
            module: Shell.Execute,
            params: params,
            resource_uri: shell_resource_uri(command)
          }
      end
    end

    # Prefer schema-bounded mix actions over raw shell for known mix tasks so
    # capability/trust use arbor://action/mix/* (auto for coding agents). Owner-
    # issued workspace_id is mandatory. No Mix form that executes project code
    # may fall back to Shell.Execute.
    defp mix_action_invocation(worktree_path, command, timeout, context) do
      with {:ok, tokens} <- split_command(command),
           {:ok, mix_argv} <- mix_args(tokens) do
        case mix_argv do
          ["compile" | args] ->
            with {:ok, parsed} <- parse_mix_compile_args(args),
                 {:ok, params} <-
                   require_workspace_id_params(
                     parsed
                     |> Map.put(:path, worktree_path)
                     |> Map.put(:timeout, timeout),
                     context
                   ) do
              {:ok,
               %{
                 kind: :action,
                 module: MixActions.Compile,
                 params: params,
                 resource_uri: Actions.canonical_uri_for(MixActions.Compile, params)
               }}
            else
              :error -> {:error, :invalid_mix_compile_args}
              {:error, _} = err -> err
            end

          ["quality"] ->
            with {:ok, params} <-
                   require_workspace_id_params(
                     %{path: worktree_path, timeout: timeout},
                     context
                   ) do
              {:ok,
               %{
                 kind: :action,
                 module: MixActions.Quality,
                 params: params,
                 resource_uri: Actions.canonical_uri_for(MixActions.Quality, params)
               }}
            end

          ["test" | args] ->
            with {:ok, parsed} <- parse_mix_test_args(args),
                 {:ok, params} <-
                   require_workspace_id_params(
                     parsed
                     |> Map.put(:path, worktree_path)
                     |> Map.put(:timeout, timeout),
                     context
                   ) do
              {:ok,
               %{
                 kind: :action,
                 module: MixActions.Test,
                 params: params,
                 resource_uri: Actions.canonical_uri_for(MixActions.Test, params)
               }}
            else
              :error -> {:error, :invalid_mix_test_args}
              {:error, _} = err -> err
            end

          ["format" | args] ->
            with {:ok, parsed} <- parse_mix_format_args(args),
                 {:ok, params} <-
                   require_workspace_id_params(
                     parsed
                     |> Map.put(:path, worktree_path)
                     |> Map.put(:timeout, timeout),
                     context
                   ) do
              {:ok,
               %{
                 kind: :action,
                 module: MixActions.Format,
                 params: params,
                 resource_uri: Actions.canonical_uri_for(MixActions.Format, params)
               }}
            else
              :error -> {:error, :invalid_mix_format_args}
              {:error, _} = err -> err
            end

          ["xref" | args] ->
            with {:ok, parsed} <- parse_mix_xref_args(args),
                 {:ok, params} <-
                   require_workspace_id_params(
                     parsed
                     |> Map.put(:path, worktree_path)
                     |> Map.put(:timeout, timeout),
                     context
                   ) do
              {:ok,
               %{
                 kind: :action,
                 module: MixActions.Xref,
                 params: params,
                 resource_uri: Actions.canonical_uri_for(MixActions.Xref, params)
               }}
            else
              :error -> {:error, :invalid_mix_xref_args}
              {:error, _} = err -> err
            end

          # Recognized mix task name but unsupported form/flags — fail closed,
          # never Shell.Execute.
          [task | _] when is_binary(task) ->
            {:error, :unsupported_mix_validation_command}

          _ ->
            {:error, :unsupported_mix_validation_command}
        end
      else
        # Not a mix command at all.
        _ -> :error
      end
    end

    defp split_command(command) when is_binary(command) do
      {:ok, OptionParser.split(command)}
    rescue
      _ -> :error
    end

    defp split_command(_command), do: :error

    defp mix_args([executable | args]) when is_binary(executable) do
      if Path.basename(executable) == "mix" do
        {:ok, args}
      else
        :error
      end
    end

    defp mix_args(_tokens), do: :error

    defp parse_mix_test_args(args) when is_list(args) do
      # Only bounded flags the Mix.Test action models. Unsupported flags fail
      # closed rather than falling through to Shell.Execute.
      Enum.reduce_while(args, {:ok, %{test_paths: []}}, fn
        "--only", {:ok, acc} ->
          {:cont, {:ok, Map.put(acc, :_expect_only, true)}}

        tag, {:ok, %{_expect_only: true} = acc} when is_binary(tag) ->
          {:cont, {:ok, acc |> Map.delete(:_expect_only) |> Map.put(:tags, tag)}}

        "--seed", {:ok, acc} ->
          {:cont, {:ok, Map.put(acc, :_expect_seed, true)}}

        seed, {:ok, %{_expect_seed: true} = acc} when is_binary(seed) ->
          case Integer.parse(seed) do
            {n, ""} when n >= 0 ->
              {:cont, {:ok, acc |> Map.delete(:_expect_seed) |> Map.put(:seed, n)}}

            _ ->
              {:halt, :error}
          end

        "--", {:ok, acc} ->
          {:cont, {:ok, Map.put(acc, :_paths, true)}}

        path, {:ok, %{_paths: true} = acc} when is_binary(path) ->
          paths = Map.get(acc, :test_paths, []) ++ [path]
          {:cont, {:ok, Map.put(acc, :test_paths, paths)}}

        path, {:ok, acc} when is_binary(path) ->
          if String.starts_with?(path, "-") do
            {:halt, :error}
          else
            paths = Map.get(acc, :test_paths, []) ++ [path]
            {:cont, {:ok, Map.put(acc, :test_paths, paths)}}
          end

        _other, _acc ->
          {:halt, :error}
      end)
      |> case do
        {:ok, %{_expect_only: _}} -> :error
        {:ok, %{_expect_seed: _}} -> :error
        {:ok, acc} -> {:ok, Map.drop(acc, [:_paths, :_expect_only, :_expect_seed])}
        :error -> :error
      end
    end

    defp parse_mix_format_args(args) when is_list(args) do
      Enum.reduce_while(args, {:ok, %{}}, fn
        "--check-formatted", {:ok, acc} ->
          {:cont, {:ok, Map.put(acc, :check_only, true)}}

        "--", {:ok, acc} ->
          {:cont, {:ok, Map.put(acc, :_files, true)}}

        file, {:ok, %{_files: true} = acc} when is_binary(file) ->
          files = Map.get(acc, :files, []) ++ [file]
          {:cont, {:ok, Map.put(acc, :files, files)}}

        _other, _acc ->
          {:halt, :error}
      end)
      |> case do
        {:ok, acc} -> {:ok, Map.drop(acc, [:_files])}
        :error -> :error
      end
    end

    defp parse_mix_xref_args(args) when is_list(args) do
      case args do
        [] ->
          {:ok, %{}}

        ["graph"] ->
          {:ok, %{mode: "graph"}}

        ["graph", "--format", format] when format in ["stats", "cycles", "linked"] ->
          {:ok, %{mode: "graph", format: format}}

        _ ->
          :error
      end
    end

    defp parse_mix_compile_args(args) do
      Enum.reduce_while(args, {:ok, %{}}, fn
        "--warnings-as-errors", {:ok, acc} ->
          {:cont, {:ok, Map.put(acc, :warnings_as_errors, true)}}

        _arg, _acc ->
          {:halt, :error}
      end)
    end

    defp emit_awaiting_approval_signal(proposal_id, resource_uri, context, command) do
      Actions.emit_event(:awaiting_approval, %{
        proposal_id: proposal_id,
        resource_uri: resource_uri,
        command: command,
        agent_id: context_agent_id(context),
        task_id: validation_task_id(context),
        source: :coding_validation
      })
    end

    defp run_validation_invocation(%{kind: :action, module: module, params: params}, context) do
      context = put_validation_agent_context(context)

      cond do
        has_action_runner?(context) ->
          call_action(module, params, context)

        agent_id = context_agent_id(context) ->
          Actions.authorize_and_execute(agent_id, module, params, context)

        true ->
          call_action(module, params, context)
      end
    end

    defp run_validation_invocation(%{kind: :missing_workspace, error: reason}, _context) do
      {:error, reason}
    end

    defp run_validation_invocation(%{kind: :unsupported_mix, error: reason}, _context) do
      {:error, reason}
    end

    defp run_validation_invocation(%{kind: :shell, module: module, params: params}, context) do
      # Shell validation must go through Shell.Execute with agent_id present so
      # Trust can escalate to pending_approval. Shell.Execute authorizes once via
      # Trust (honoring approved_invocation) and does not re-auth through the
      # Security-only Shell.authorize path that previously re-asked after approve.
      context = put_validation_agent_context(context)

      cond do
        has_action_runner?(context) ->
          call_action(module, params, context)

        agent_id = context_agent_id(context) ->
          Actions.authorize_and_execute(agent_id, module, params, context)

        true ->
          {:error, :authenticated_principal_required}
      end
    end

    defp has_action_runner?(context) do
      is_function(Map.get(context, :action_runner), 3) or
        is_function(Map.get(context, "action_runner"), 3)
    end

    # Ensure nested shell/mix validation sees the same agent + task provenance the
    # outer action was running under (needed for Trust auth + task-scoped answer caps).
    defp put_validation_agent_context(context) when is_map(context) do
      context
      |> then(fn c ->
        case context_agent_id(c) do
          id when is_binary(id) and id != "" -> Map.put(c, :agent_id, id)
          _ -> c
        end
      end)
      |> then(fn c ->
        case validation_task_id(c) do
          id when is_binary(id) and id != "" -> Map.put(c, :task_id, id)
          _ -> c
        end
      end)
    end

    defp put_validation_agent_context(context), do: context

    defp validation_task_id(context) do
      map_value(context, :task_id) ||
        map_value(context, "session.task_id") ||
        map_value(context, :session_task_id)
    end

    defp retry_validation_after_approval(command, invocation, proposal_id, context) do
      resource_uri = invocation.resource_uri

      case await_validation_approval(proposal_id, resource_uri, context) do
        :approved ->
          approved_context =
            context
            |> put_validation_agent_context()
            |> Map.put(:approved_invocation, %{
              request_id: proposal_id,
              principal_id: context_agent_id(context),
              resource_uri: resource_uri,
              decision: :approved
            })

          case run_validation_invocation(invocation, approved_context) do
            {:ok, result} when is_map(result) ->
              validation_result(command, result)

            {:ok, :pending_approval, retry_proposal_id} ->
              # Exact-invocation retry should not re-ask. If it does, surface the
              # second id so the operator can see the gate still wants approval
              # (usually resource_uri mismatch on the approved_invocation marker).
              validation_failure(
                command,
                "pending approval after approval: #{retry_proposal_id}"
              )

            {:error, reason} ->
              validation_failure(command, to_string(reason))
          end

        {:error, reason} ->
          validation_failure(command, "approval #{proposal_id} #{format_approval_error(reason)}")
      end
    end

    defp validation_result(command, result) do
      exit_code = result[:exit_code] || result["exit_code"]
      timed_out = result[:timed_out] == true or result["timed_out"] == true
      killed = result[:killed] == true or result["killed"] == true

      output_limit_exceeded =
        result[:output_limit_exceeded] == true or result["output_limit_exceeded"] == true

      output_truncated =
        result[:output_truncated] == true or result["output_truncated"] == true

      stderr = result[:stderr] || result["stderr"] || ""

      # Order: output ceiling → absolute timeout → generic kill. Exit 137 is
      # shared; mislabeling ceiling kills as timeouts or generic kills as
      # timeouts misdirects operators toward the wrong fix.
      ceiling_mib = div(Arbor.Shell.max_output_bytes_limit(), 1_048_576)

      stderr =
        cond do
          output_limit_exceeded ->
            base =
              "command output limit exceeded (exit 137 = killed after retained " <>
                "stdout hit max_output_bytes; reduce command output or raise " <>
                "max_output_bytes only within the #{ceiling_mib} MiB system ceiling)"

            if stderr == "", do: base, else: base <> "; " <> stderr

          timed_out ->
            base =
              "command timed out (exit 137 = killed after timeout; " <>
                "check validation_timeout — values under 10s are treated as unset)"

            if stderr == "", do: base, else: base <> "; " <> stderr

          killed and exit_code == 137 ->
            base =
              "command killed (exit 137 = process killed; not an absolute timeout " <>
                "and not an output-limit termination)"

            if stderr == "", do: base, else: base <> "; " <> stderr

          true ->
            stderr
        end

      %{
        command: command,
        passed: exit_code == 0 and not timed_out and not output_limit_exceeded,
        exit_code: exit_code,
        stdout: result[:stdout] || result["stdout"] || "",
        stderr: stderr,
        timed_out: timed_out,
        killed: killed,
        output_limit_exceeded: output_limit_exceeded,
        output_truncated: output_truncated
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
    end

    defp validation_failure(command, stderr) do
      %{
        command: command,
        passed: false,
        exit_code: nil,
        stdout: "",
        stderr: stderr
      }
    end

    defp await_validation_approval(proposal_id, resource_uri, context) do
      case Map.get(context, :approval_awaiter) || Map.get(context, "approval_awaiter") do
        awaiter when is_function(awaiter, 4) ->
          awaiter.(proposal_id, resource_uri, context, approval_timeout())

        _ ->
          await_interaction_approval(
            context_agent_id(context),
            proposal_id,
            resource_uri,
            approval_timeout()
          )
      end
    end

    defp await_interaction_approval(nil, _request_id, _resource_uri, _timeout_ms),
      do: {:error, :missing_agent_id}

    defp await_interaction_approval(agent_id, request_id, _resource_uri, timeout_ms) do
      pubsub = Module.concat([:Arbor, :Comms, :PubSub])

      if pubsub_available?(pubsub) do
        topic = Arbor.Contracts.Comms.Interaction.response_topic_for_agent(agent_id)

        task =
          Task.async(fn ->
            apply(pubsub_module(), :subscribe, [pubsub, topic])

            receive do
              {:interaction_response, %{request_id: ^request_id, response: response}} ->
                normalize_approval_response(response)
            after
              timeout_ms ->
                {:error, :timeout}
            end
          end)

        case Task.yield(task, timeout_ms + 1_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          nil -> {:error, :timeout}
          {:exit, reason} -> {:error, {:approval_waiter_exit, reason}}
        end
      else
        {:error, :approval_pubsub_unavailable}
      end
    end

    defp pubsub_available?(pubsub) do
      pubsub_module = pubsub_module()

      Code.ensure_loaded?(pubsub_module) and
        function_exported?(pubsub_module, :subscribe, 2) and
        not is_nil(Process.whereis(pubsub))
    end

    defp pubsub_module, do: Module.concat([:Phoenix, :PubSub])

    defp normalize_approval_response(response)
         when response in [:approved, :approve, "approved", "approve"],
         do: :approved

    defp normalize_approval_response(response)
         when response in [
                :rejected,
                :reject,
                :denied,
                :deny,
                "rejected",
                "reject",
                "denied",
                "deny"
              ],
         do: {:error, :rejected}

    defp normalize_approval_response(response), do: {:error, {:unexpected_response, response}}

    defp approval_timeout do
      Application.get_env(
        :arbor_actions,
        :approval_timeout_ms,
        Application.get_env(:arbor_orchestrator, :approval_timeout_ms, @default_approval_timeout)
      )
    end

    defp format_approval_error(:timeout), do: "timed out"
    defp format_approval_error(:rejected), do: "was rejected"
    defp format_approval_error(:missing_agent_id), do: "could not be awaited without an agent id"

    defp format_approval_error(:approval_pubsub_unavailable),
      do: "could not be awaited: PubSub unavailable"

    defp format_approval_error(reason), do: "failed: #{inspect(reason)}"

    defp shell_resource_uri(command) do
      command_name =
        command
        |> String.trim_leading()
        |> String.split(~r/\s+/, parts: 2)
        |> List.first()
        |> Path.basename()

      "arbor://shell/exec/#{command_name}"
    end

    defp commit_change(repo_root, worktree_path, params, context) do
      Git.with_storage_authority(repo_root, worktree_path, fn ->
        call_action(
          Git.Commit,
          %{
            path: worktree_path,
            message: commit_message(params),
            all: true
          },
          context
        )
      end)
    end

    defp finalize_committed_change(
           repo_root,
           worktree_path,
           branch_name,
           response,
           validations,
           params,
           context,
           commit,
           workspace
         ) do
      if submit_review?(params) do
        case submit_council_review(
               worktree_path,
               branch_name,
               params,
               context,
               workspace,
               commit
             ) do
          {:ok, review} ->
            finalize_reviewed_change(
              repo_root,
              worktree_path,
              branch_name,
              response,
              validations,
              params,
              context,
              commit,
              review
            )

          {:error, reason} ->
            reviewable_change_result(
              "review_failed",
              repo_root,
              worktree_path,
              branch_name,
              response,
              validations,
              commit,
              params,
              review_failure_fields(reason)
            )
        end
      else
        maybe_open_pr(
          repo_root,
          worktree_path,
          branch_name,
          response,
          validations,
          params,
          context,
          commit
        )
      end
    end

    defp finalize_reviewed_change(
           repo_root,
           worktree_path,
           branch_name,
           response,
           validations,
           params,
           context,
           commit,
           review
         ) do
      fields = review_result_fields(review)

      case normalize_tier_decision(fields.tier_decision) do
        :rework ->
          reviewable_change_result(
            "review_requires_rework",
            repo_root,
            worktree_path,
            branch_name,
            response,
            validations,
            commit,
            params,
            fields
          )

        :stop ->
          reviewable_change_result(
            "review_rejected",
            repo_root,
            worktree_path,
            branch_name,
            response,
            validations,
            commit,
            params,
            fields
          )

        :human_review ->
          repo_root
          |> maybe_open_pr(
            worktree_path,
            branch_name,
            response,
            validations,
            params,
            context,
            commit
          )
          |> Map.merge(fields)
          |> maybe_mark_human_review_required(params)

        :auto_proceed ->
          repo_root
          |> maybe_open_pr(
            worktree_path,
            branch_name,
            response,
            validations,
            params,
            context,
            commit
          )
          |> Map.merge(fields)

        _unknown ->
          reviewable_change_result(
            "review_failed",
            repo_root,
            worktree_path,
            branch_name,
            response,
            validations,
            commit,
            params,
            review_failure_fields({:unknown_tier_decision, fields.tier_decision})
          )
      end
    end

    defp maybe_open_pr(
           repo_root,
           worktree_path,
           branch_name,
           response,
           validations,
           params,
           context,
           commit
         ) do
      if open_pr?(params) do
        case open_draft_pr(
               worktree_path,
               branch_name,
               response,
               validations,
               params,
               context,
               commit
             ) do
          {:ok, pr} ->
            reviewable_change_result(
              "pr_created",
              repo_root,
              worktree_path,
              branch_name,
              response,
              validations,
              commit,
              params,
              pr_url: pr[:url] || pr["url"]
            )

          {:pr_failed, reason, commit} ->
            reviewable_change_result(
              "pr_failed",
              repo_root,
              worktree_path,
              branch_name,
              response,
              validations,
              commit,
              params,
              error: reason
            )
        end
      else
        reviewable_change_result(
          "change_committed",
          repo_root,
          worktree_path,
          branch_name,
          response,
          validations,
          commit,
          params
        )
      end
    end

    # Council review material uses the same lease primitive as the canonical
    # coding-change-v1 graph (coding_workspace_committed_change): cumulative
    # base_commit..HEAD, clean worktree required.
    defp submit_council_review(
           worktree_path,
           branch_name,
           params,
           context,
           workspace,
           commit
         ) do
      workspace_id = map_value(workspace, :workspace_id)
      expected_commit = commit_hash(commit)

      with {:ok, change} <-
             materialize_review_change(
               workspace_id,
               worktree_path,
               workspace,
               expected_commit,
               context
             ) do
        review_params =
          %{
            diff: map_value(change, :diff),
            files: map_value(change, :files),
            branch: branch_name,
            base_ref: map_value(change, :base_ref),
            intent: get_param(params, :task),
            agent_id: context_agent_id(context),
            workspace_id: workspace_id,
            commit_hash: expected_commit
          }
          |> put_if_present(:timeout, get_param(params, :review_timeout))

        call_action(Council.ReviewChange, review_params, context)
      end
    end

    defp materialize_review_change(
           workspace_id,
           _worktree_path,
           _workspace,
           expected_commit,
           context
         )
         when is_binary(workspace_id) and workspace_id != "" do
      params =
        %{workspace_id: workspace_id}
        |> put_if_present(:commit, expected_commit)

      call_action(Workspace.CommittedChange, params, context)
    end

    defp materialize_review_change(
           _workspace_id,
           worktree_path,
           workspace,
           expected_commit,
           _context
         ) do
      Workspace.materialize_committed_change(
        worktree_path,
        map_value(workspace, :base_commit),
        expected_commit
      )
    end

    defp reviewable_change_result(
           status,
           repo_root,
           worktree_path,
           branch_name,
           response,
           validations,
           commit,
           params,
           extra \\ []
         ) do
      %{
        status: status,
        repo_path: repo_root,
        worktree_path: worktree_path,
        branch: branch_name,
        commit: commit_hash(commit),
        acp_agent: selected_acp_agent(params),
        validation: validations,
        response_text: response_text(response)
      }
      |> Map.merge(Map.new(extra))
    end

    defp open_draft_pr(worktree_path, branch_name, response, validations, params, context, commit) do
      pr_params = %{
        path: worktree_path,
        branch: branch_name,
        title: get_param(params, :pr_title) || pr_title(params),
        body: pr_body(branch_name, response, validations, params),
        draft: true
      }

      pr_params = put_if_present(pr_params, :base, get_param(params, :base_ref))

      case call_action(Git.PR, pr_params, context) do
        {:ok, pr} -> {:ok, pr}
        {:error, reason} -> {:pr_failed, reason, commit}
      end
    end

    defp open_pr?(params), do: get_param(params, :open_pr) == true
    defp submit_review?(params), do: get_param(params, :submit_review) != false

    defp maybe_mark_human_review_required(result, params) do
      if open_pr?(params), do: result, else: Map.put(result, :status, "human_review_required")
    end

    defp review_result_fields(review) do
      review = review_summary(review)

      %{
        review: review,
        tier_decision: map_value(review, :tier_decision),
        human_required: truthy?(map_value(review, :human_required)),
        blast_radius: map_value(review, :blast_radius),
        review_recommendation: map_value(review, :recommendation),
        security_veto: truthy?(map_value(review, :security_veto))
      }
    end

    defp review_failure_fields(reason) do
      error = inspect(reason)

      %{
        review: %{status: "review_failed", error: error},
        review_error: error,
        tier_decision: :human_review,
        human_required: true,
        security_veto: false
      }
    end

    defp review_summary(review) when is_map(review) do
      %{
        status: map_value(review, :status),
        recommendation: map_value(review, :recommendation),
        decision: map_value(review, :decision),
        branch: map_value(review, :branch),
        files: map_value(review, :files),
        approve_count: map_value(review, :approve_count),
        reject_count: map_value(review, :reject_count),
        abstain_count: map_value(review, :abstain_count),
        quorum_met: map_value(review, :quorum_met),
        blast_radius: map_value(review, :blast_radius),
        tier_decision: map_value(review, :tier_decision),
        human_required: map_value(review, :human_required),
        security_veto: map_value(review, :security_veto),
        authority_widening: map_value(review, :authority_widening),
        tier_reasons: map_value(review, :tier_reasons),
        verdict: verdict_summary(map_value(review, :verdict))
      }
      |> reject_nil_values()
    end

    defp review_summary(other), do: %{status: "reviewed", raw: inspect(other)}

    defp verdict_summary(%{__struct__: _struct} = verdict) do
      %{
        overall_score: Map.get(verdict, :overall_score),
        dimension_scores: Map.get(verdict, :dimension_scores),
        strengths: Map.get(verdict, :strengths),
        weaknesses: Map.get(verdict, :weaknesses),
        recommendation: Map.get(verdict, :recommendation),
        mode: Map.get(verdict, :mode),
        meta: Map.get(verdict, :meta)
      }
      |> reject_nil_values()
    end

    defp verdict_summary(verdict) when is_map(verdict), do: reject_nil_values(verdict)
    defp verdict_summary(_verdict), do: nil

    defp normalize_tier_decision(:auto_proceed), do: :auto_proceed
    defp normalize_tier_decision(:human_review), do: :human_review
    defp normalize_tier_decision(:rework), do: :rework
    defp normalize_tier_decision(:stop), do: :stop
    defp normalize_tier_decision("auto_proceed"), do: :auto_proceed
    defp normalize_tier_decision("human_review"), do: :human_review
    defp normalize_tier_decision("rework"), do: :rework
    defp normalize_tier_decision("stop"), do: :stop
    defp normalize_tier_decision(_decision), do: :unknown

    defp reject_nil_values(map) do
      Map.reject(map, fn {_key, value} -> is_nil(value) end)
    end

    defp map_value(map, key) when is_map(map) and is_atom(key) do
      cond do
        Map.has_key?(map, key) -> Map.get(map, key)
        Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
        true -> nil
      end
    end

    defp map_value(map, key) when is_map(map) and is_binary(key) do
      Map.get(map, key)
    end

    defp map_value(_map, _key), do: nil

    defp truthy?(true), do: true
    defp truthy?("true"), do: true
    defp truthy?(_value), do: false

    defp commit_hash(commit), do: map_value(commit, :commit_hash) || map_value(commit, :hash)

    defp commit_message(params) do
      title =
        params
        |> get_param(:pr_title)
        |> blank_to_nil()
        |> Kernel.||(pr_title(params))

      String.slice(title, 0, 72)
    end

    defp blank_to_nil(value) when is_binary(value) do
      value = String.trim(value)
      if value == "", do: nil, else: value
    end

    defp blank_to_nil(nil), do: nil
    defp blank_to_nil(value), do: value

    defp selected_acp_agent(params) do
      params
      |> get_param(:acp_agent)
      |> blank_to_nil()
      |> Kernel.||(default_acp_agent())
      |> to_string()
    end

    defp default_acp_agent do
      :arbor_actions
      |> Application.get_env(:coding_default_acp_agent, @default_acp_agent)
      |> blank_to_nil()
      |> Kernel.||(@default_acp_agent)
    end

    defp pr_title(params) do
      task =
        params
        |> get_param(:task)
        |> to_string()
        |> String.trim()

      if task == "" do
        "Coding agent change"
      else
        "Coding agent: #{String.slice(task, 0, 80)}"
      end
    end

    defp pr_body(branch_name, response, validations, params) do
      validation_text =
        validations
        |> Enum.map_join("\n", fn result ->
          mark = if result.passed, do: "PASS", else: "FAIL"
          "- #{mark}: `#{result.command}`"
        end)

      extra = get_param(params, :pr_body)

      """
      #{extra || ""}

      ## Coding Agent

      Branch: `#{branch_name}`

      ## ACP Agent Response

      #{response_text(response)}

      ## Validation

      #{validation_text}

      Human review and merge are required.
      """
      |> String.trim()
    end

    defp validation_commands(params) do
      cond do
        truthy?(get_param(params, :skip_validation)) ->
          []

        match?([_ | _], get_param(params, :validation_commands)) ->
          get_param(params, :validation_commands)

        get_param(params, :validation_commands) == [] ->
          # Explicit empty list means skip (smoke tests / docs-only).
          # Omitted/nil still uses the default mix compile.
          []

        true ->
          @default_validation_commands
      end
    end

    defp context_agent_id(context) do
      map_value(context, :agent_id) || map_value(context, :"session.agent_id")
    end

    defp call_action(module, params, context) do
      case Map.get(context, :action_runner) || Map.get(context, "action_runner") do
        runner when is_function(runner, 3) -> runner.(module, params, context)
        _runner -> Arbor.Actions.execute_action(module, params, context)
      end
    end

    defp get_param(map, key) when is_map(map), do: map_value(map, key)

    defp put_if_present(map, _key, nil), do: map
    defp put_if_present(map, _key, []), do: map
    defp put_if_present(map, key, value), do: Map.put(map, key, value)

    defp put_workspace_id_context(context, workspace) when is_map(context) do
      case map_value(workspace, :workspace_id) do
        id when is_binary(id) and id != "" -> Map.put(context, :workspace_id, id)
        _ -> context
      end
    end

    defp put_workspace_id_context(context, _workspace), do: context

    defp require_workspace_id_params(params, context) when is_map(params) do
      case map_value(context, :workspace_id) || map_value(params, :workspace_id) do
        id when is_binary(id) and id != "" ->
          {:ok, Map.put(params, :workspace_id, id)}

        _ ->
          {:error, :workspace_id_required}
      end
    end

    defp require_workspace_id_params(_params, _context), do: {:error, :workspace_id_required}

    defp assert_validation_tree_stable(%{tree_oid: before}, %{tree_oid: after_oid})
         when before == after_oid,
         do: :ok

    defp assert_validation_tree_stable(_before, _after), do: {:error, :validation_tree_mutated}

    # After commit/adopt, compare the **commit object's** tree OID (not the
    # mutable worktree) with the pre-validation binding so an async writer
    # restoring files cannot hide an unvalidated committed tree.
    defp assert_commit_matches_validated_tree(worktree_path, %{tree_oid: expected}, commit) do
      hash = map_value(commit, :commit_hash) || map_value(commit, "commit_hash")

      with true <- is_binary(hash) and hash != "",
           {:ok, tree_oid} <- Arbor.Actions.Mix.commit_tree_oid(worktree_path, hash) do
        if tree_oid == expected, do: :ok, else: {:error, :validation_tree_mutated}
      else
        false -> {:error, :missing_commit_hash}
        {:error, reason} -> {:error, reason}
      end
    end

    defp assert_commit_matches_validated_tree(_worktree_path, _binding, _commit),
      do: {:error, :validation_tree_mutated}
  end
end
