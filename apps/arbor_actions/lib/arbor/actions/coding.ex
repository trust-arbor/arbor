defmodule Arbor.Actions.Coding do
  @moduledoc """
  Coding-agent orchestration actions.

  These actions compose existing primitives into reviewable software-change
  workflows. The v0 path delegates implementation to an ACP coding agent, then
  validates and hands the result back as a human-reviewed branch/PR.
  """

  defmodule ProduceReviewableChange do
    @moduledoc """
    Produce a reviewable code change in an isolated git worktree.

    The action creates a new worktree/branch, starts an ACP coding-agent session
    in `permission_mode: :default`, asks it to implement the requested task,
    runs validation commands, and commits the result. It can optionally open a
    draft PR, but never merges its own work.
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

      with {:ok, repo_root} <- resolve_repo_root(repo_path),
           {:ok, branch_name} <- resolve_branch_name(params),
           {:ok, worktree_path} <- create_worktree(repo_root, branch_name, params),
           {:ok, session} <- start_acp_session(worktree_path, params, context),
           {:ok, response} <- prompt_acp_agent(session, worktree_path, params, context) do
        maybe_close_session(session, context)
        finish_change(repo_root, worktree_path, branch_name, response, params, context)
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    def run(_params, _context), do: {:error, "task and repo_path are required"}

    defp finish_change(repo_root, worktree_path, branch_name, response, params, context) do
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

        worktree_clean?(worktree_path) ->
          result = %{
            status: "no_changes",
            branch: branch_name,
            worktree_path: worktree_path,
            acp_agent: selected_acp_agent(params),
            response_text: response_text(response)
          }

          Actions.emit_completed(__MODULE__, result)
          {:ok, result}

        true ->
          with {:ok, validations} <- run_validations(worktree_path, params, context),
               {:ok, commit} <- commit_change(worktree_path, params, context) do
            result =
              finalize_committed_change(
                repo_root,
                worktree_path,
                branch_name,
                response,
                validations,
                params,
                context,
                commit
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
    end

    defp resolve_repo_root(path) when is_binary(path) do
      expanded = Path.expand(path)

      case git(expanded, ["rev-parse", "--show-toplevel"]) do
        {:ok, output} -> {:ok, String.trim(output)}
        {:error, reason} -> {:error, "repo_path is not a git repository: #{reason}"}
      end
    end

    defp resolve_repo_root(_), do: {:error, "repo_path must be a string"}

    defp resolve_branch_name(params) do
      params
      |> get_param(:branch_name)
      |> case do
        nil -> generated_branch_name(get_param(params, :task))
        "" -> generated_branch_name(get_param(params, :task))
        branch -> {:ok, branch}
      end
      |> validate_branch_name()
    end

    defp generated_branch_name(task) do
      slug =
        task
        |> to_string()
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/, "-")
        |> String.trim("-")
        |> String.slice(0, 48)
        |> case do
          "" -> "change"
          value -> value
        end

      unique = System.unique_integer([:positive])
      {:ok, "arbor/coding-agent/#{slug}-#{unique}"}
    end

    defp validate_branch_name({:ok, branch}) do
      cond do
        not is_binary(branch) or branch == "" ->
          {:error, "branch_name must be a non-empty string"}

        String.starts_with?(branch, "-") ->
          {:error, "branch_name must not start with '-'"}

        String.contains?(branch, ["..", "@{", "\\"]) ->
          {:error, "branch_name contains a forbidden git ref sequence"}

        String.ends_with?(branch, ["/", "."]) ->
          {:error, "branch_name must not end with '/' or '.'"}

        not Regex.match?(~r/^[A-Za-z0-9._\/-]+$/, branch) ->
          {:error, "branch_name contains unsupported characters"}

        true ->
          {:ok, branch}
      end
    end

    defp create_worktree(repo_root, branch_name, params) do
      base_dir =
        params
        |> get_param(:worktree_base_dir)
        |> case do
          nil -> System.tmp_dir!()
          path -> Path.expand(path)
        end

      File.mkdir_p!(base_dir)
      base_ref = get_param(params, :base_ref) || "HEAD"
      worktree_path = Path.join(base_dir, worktree_dir_name(branch_name))

      with {:ok, base_commit} <- rev_parse(repo_root, base_ref),
           {:ok, path, reused?} <-
             ensure_worktree(repo_root, branch_name, worktree_path, base_commit),
           :ok <- maybe_reset_reused_worktree(path, base_commit, reused?) do
        {:ok, path}
      end
    end

    defp worktree_dir_name(branch_name) do
      slug =
        branch_name
        |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
        |> String.trim("-")
        |> String.slice(0, 48)
        |> case do
          "" -> "change"
          value -> value
        end

      hash =
        branch_name
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 12)

      "arbor-coding-agent-#{slug}-#{hash}"
    end

    defp rev_parse(repo_root, ref) do
      case git(repo_root, ["rev-parse", "--verify", ref]) do
        {:ok, output} -> {:ok, String.trim(output)}
        {:error, reason} -> {:error, "failed to resolve base_ref #{inspect(ref)}: #{reason}"}
      end
    end

    defp ensure_worktree(repo_root, branch_name, worktree_path, base_commit) do
      cond do
        File.dir?(worktree_path) ->
          ensure_existing_worktree_branch(worktree_path, branch_name)

        existing_path = worktree_for_branch(repo_root, branch_name) ->
          {:ok, existing_path, true}

        branch_exists?(repo_root, branch_name) ->
          add_existing_branch_worktree(repo_root, branch_name, worktree_path)

        true ->
          add_new_branch_worktree(repo_root, branch_name, worktree_path, base_commit)
      end
    end

    defp ensure_existing_worktree_branch(worktree_path, branch_name) do
      case git(worktree_path, ["branch", "--show-current"]) do
        {:ok, output} ->
          current_branch = String.trim(output)

          if current_branch == branch_name do
            {:ok, worktree_path, true}
          else
            {:error,
             "existing worktree #{worktree_path} is on #{inspect(current_branch)}, expected #{inspect(branch_name)}"}
          end

        {:error, reason} ->
          {:error, "existing worktree #{worktree_path} is not usable: #{reason}"}
      end
    end

    defp worktree_for_branch(repo_root, branch_name) do
      with {:ok, output} <- git(repo_root, ["worktree", "list", "--porcelain"]) do
        output
        |> String.split("\n\n", trim: true)
        |> Enum.find_value(fn entry ->
          lines = String.split(entry, "\n", trim: true)
          path = line_value(lines, "worktree ")
          branch = line_value(lines, "branch refs/heads/")

          if branch == branch_name, do: path
        end)
      else
        _ -> nil
      end
    end

    defp line_value(lines, prefix) do
      lines
      |> Enum.find_value(fn line ->
        if String.starts_with?(line, prefix) do
          String.replace_prefix(line, prefix, "")
        end
      end)
    end

    defp branch_exists?(repo_root, branch_name) do
      case git(repo_root, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch_name}"]) do
        {:ok, _} -> true
        {:error, _} -> false
      end
    end

    defp add_existing_branch_worktree(repo_root, branch_name, worktree_path) do
      case System.cmd(
             "git",
             ["-C", repo_root, "worktree", "add", worktree_path, branch_name],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> {:ok, worktree_path, true}
        {output, _code} -> {:error, "failed to create worktree: #{String.trim(output)}"}
      end
    end

    defp add_new_branch_worktree(repo_root, branch_name, worktree_path, base_commit) do
      case System.cmd(
             "git",
             ["-C", repo_root, "worktree", "add", "-b", branch_name, worktree_path, base_commit],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> {:ok, worktree_path, false}
        {output, _code} -> {:error, "failed to create worktree: #{String.trim(output)}"}
      end
    end

    defp maybe_reset_reused_worktree(_worktree_path, _base_commit, false), do: :ok

    defp maybe_reset_reused_worktree(worktree_path, base_commit, true) do
      with {:ok, _} <- git(worktree_path, ["reset", "--hard", base_commit]),
           {:ok, _} <- git(worktree_path, ["clean", "-fd"]) do
        :ok
      else
        {:error, reason} -> {:error, "failed to reset existing worktree: #{reason}"}
      end
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
      session_pid = session[:session_pid] || session["session_pid"]

      prompt_params =
        %{
          session_pid: session_pid,
          prompt: build_prompt(worktree_path, params)
        }
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
      session_pid = session[:session_pid] || session["session_pid"]

      if session_pid do
        call_action(Acp.CloseSession, %{session_pid: session_pid}, context)
      end

      :ok
    end

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

    defp worktree_clean?(worktree_path) do
      case git(worktree_path, ["status", "--porcelain"]) do
        {:ok, ""} -> true
        {:ok, output} -> String.trim(output) == ""
        {:error, _reason} -> false
      end
    end

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

      invocation = validation_invocation(worktree_path, command, timeout)

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

    defp validation_invocation(worktree_path, command, timeout) do
      case mix_action_invocation(worktree_path, command, timeout) do
        {:ok, invocation} ->
          invocation

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
    # capability/trust use arbor://action/mix/* (auto for coding agents) and so
    # worktrees can share the host checkout's deps/_build via Mix.run_mix/3.
    defp mix_action_invocation(worktree_path, command, timeout) do
      with {:ok, tokens} <- split_command(command),
           {:ok, mix_argv} <- mix_args(tokens) do
        case mix_argv do
          ["compile" | args] ->
            with {:ok, parsed} <- parse_mix_compile_args(args) do
              params =
                parsed
                |> Map.put(:path, worktree_path)
                |> Map.put(:timeout, timeout)

              {:ok,
               %{
                 kind: :action,
                 module: MixActions.Compile,
                 params: params,
                 resource_uri: Actions.canonical_uri_for(MixActions.Compile, params)
               }}
            end

          # Exact match only — trailing args (e.g. `mix quality --strict`) must
          # not silently drop flags and run plain quality.
          ["quality"] ->
            params = %{path: worktree_path, timeout: timeout}

            {:ok,
             %{
               kind: :action,
               module: MixActions.Quality,
               params: params,
               resource_uri: Actions.canonical_uri_for(MixActions.Quality, params)
             }}

          # `mix test …` and non-exact quality forms stay on the shell path:
          # free-form paths/flags that the schema-bounded mix actions do not
          # fully model yet. Compile (and bare quality) share host deps/_build.
          _ ->
            :error
        end
      else
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

    defp run_validation_invocation(%{kind: :shell, module: module, params: params}, context) do
      # Shell validation must go through Shell.Execute with agent_id present so
      # Trust can escalate to pending_approval. Shell.Execute authorizes once via
      # Trust (honoring approved_invocation) and does not re-auth through the
      # Security-only Shell.authorize path that previously re-asked after approve.
      context = put_validation_agent_context(context)
      call_action(module, params, context)
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
      stderr = result[:stderr] || result["stderr"] || ""

      # 137 is the shell executor's conventional "killed after timeout" code
      # (SIGKILL). Without this note, docs-only smoke failures look like a flaky
      # `ls` rather than a 0/1ms validation_timeout.
      stderr =
        cond do
          timed_out or (killed and exit_code == 137) ->
            base =
              "command timed out (exit 137 = killed after timeout; " <>
                "check validation_timeout — values under 10s are treated as unset)"

            if stderr == "", do: base, else: base <> "; " <> stderr

          true ->
            stderr
        end

      %{
        command: command,
        passed: exit_code == 0 and not timed_out,
        exit_code: exit_code,
        stdout: result[:stdout] || result["stdout"] || "",
        stderr: stderr,
        timed_out: timed_out,
        killed: killed
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

    defp commit_change(worktree_path, params, context) do
      call_action(
        Git.Commit,
        %{
          path: worktree_path,
          message: commit_message(params),
          all: true
        },
        context
      )
    end

    defp finalize_committed_change(
           repo_root,
           worktree_path,
           branch_name,
           response,
           validations,
           params,
           context,
           commit
         ) do
      if submit_review?(params) do
        case submit_council_review(worktree_path, branch_name, params, context, commit) do
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

    defp submit_council_review(worktree_path, branch_name, params, context, commit) do
      with {:ok, hash} <- require_commit_hash(commit),
           {:ok, diff} <- committed_diff(worktree_path, hash),
           {:ok, files} <- committed_files(worktree_path, hash) do
        review_params =
          %{
            diff: diff,
            files: files,
            branch: branch_name,
            base_ref: review_base_ref(worktree_path, params, hash),
            intent: get_param(params, :task),
            agent_id: context_agent_id(context)
          }
          |> put_if_present(:timeout, get_param(params, :review_timeout))

        call_action(Council.ReviewChange, review_params, context)
      end
    end

    defp require_commit_hash(commit) do
      case commit_hash(commit) do
        hash when is_binary(hash) and hash != "" -> {:ok, hash}
        _ -> {:error, :missing_commit_hash}
      end
    end

    defp committed_diff(worktree_path, commit_hash) do
      case git(worktree_path, [
             "show",
             "--format=",
             "--find-renames",
             "--no-ext-diff",
             commit_hash
           ]) do
        {:ok, diff} when diff != "" -> {:ok, diff}
        {:ok, _empty} -> {:error, :empty_commit_diff}
        {:error, reason} -> {:error, {:diff_failed, reason}}
      end
    end

    defp committed_files(worktree_path, commit_hash) do
      case git(worktree_path, [
             "diff-tree",
             "--no-commit-id",
             "--name-only",
             "--find-renames",
             "-r",
             commit_hash
           ]) do
        {:ok, output} ->
          files =
            output
            |> String.split("\n", trim: true)
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          if files == [], do: {:error, :empty_commit_file_list}, else: {:ok, files}

        {:error, reason} ->
          {:error, {:files_failed, reason}}
      end
    end

    defp review_base_ref(worktree_path, params, commit_hash) do
      get_param(params, :base_ref) || parent_commit(worktree_path, commit_hash)
    end

    defp parent_commit(worktree_path, commit_hash) do
      case git(worktree_path, ["rev-parse", "#{commit_hash}^"]) do
        {:ok, output} -> String.trim(output)
        {:error, _reason} -> nil
      end
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
        _runner -> run_action_module(module, params, context)
      end
    end

    defp run_action_module(module, params, context) do
      case Code.ensure_loaded(module) do
        {:module, ^module} -> module.run(params, context)
        {:error, _reason} -> {:error, "#{inspect(module)} is not available"}
      end
    end

    defp git(path, args) do
      case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, _code} -> {:error, String.trim(output)}
      end
    end

    defp get_param(map, key) when is_map(map), do: map_value(map, key)

    defp put_if_present(map, _key, nil), do: map
    defp put_if_present(map, _key, []), do: map
    defp put_if_present(map, key, value), do: Map.put(map, key, value)
  end
end
