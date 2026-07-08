defmodule Arbor.Actions.Coding do
  @moduledoc """
  Coding-agent orchestration actions.

  These actions compose existing primitives into reviewable software-change
  workflows. The v0 path delegates implementation to Codex over ACP, then
  validates and hands the result back as a human-reviewed branch/PR.
  """

  defmodule ProduceReviewableChange do
    @moduledoc """
    Produce a reviewable code change in an isolated git worktree.

    The action creates a new worktree/branch, starts a Codex ACP session in
    `permission_mode: :default`, asks Codex to implement the requested task, runs
    validation commands, and commits the result. It can optionally open a draft
    PR, but never merges its own work.
    """

    use Jido.Action,
      name: "coding_produce_reviewable_change",
      description: "Delegate a task to Codex via ACP and return a validated reviewable branch",
      category: "coding",
      tags: ["coding", "codex", "acp", "git", "pr"],
      schema: [
        task: [
          type: :string,
          required: true,
          doc: "Implementation task for Codex"
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
          doc: "Commands to run after Codex edits"
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
          doc: "Codex model override"
        ],
        allowed_tools: [
          type: {:list, :string},
          doc: "Codex adapter tool allowlist"
        ],
        disallowed_tools: [
          type: {:list, :string},
          doc: "Codex adapter tool denylist"
        ],
        timeout: [
          type: :non_neg_integer,
          doc: "ACP implementation timeout in milliseconds"
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

    @default_validation_commands ["./bin/mix compile --warnings-as-errors"]
    @default_timeout 900_000
    @default_validation_timeout 300_000

    def taint_roles do
      %{
        task: {:control, requires: [:prompt_injection]},
        repo_path: {:control, requires: [:path_traversal]},
        base_ref: {:control, requires: [:command_injection]},
        branch_name: {:control, requires: [:command_injection]},
        worktree_base_dir: {:control, requires: [:path_traversal]},
        validation_commands: {:control, requires: [:command_injection]},
        pr_title: {:control, requires: [:command_injection]},
        pr_body: {:control, requires: [:command_injection]},
        open_pr: :control,
        submit_review: :control,
        model: :control,
        allowed_tools: :control,
        disallowed_tools: :control,
        timeout: :data,
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
           {:ok, session} <- start_codex_session(worktree_path, params, context),
           {:ok, response} <- prompt_codex(session, worktree_path, params, context) do
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
            response_text: response_text(response)
          }

          Actions.emit_completed(__MODULE__, result)
          {:ok, result}

        worktree_clean?(worktree_path) ->
          result = %{
            status: "no_changes",
            branch: branch_name,
            worktree_path: worktree_path,
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
      id = System.unique_integer([:positive])
      worktree_path = Path.join(base_dir, "arbor-coding-agent-#{id}")
      base_ref = get_param(params, :base_ref) || "HEAD"

      case System.cmd(
             "git",
             ["-C", repo_root, "worktree", "add", "-b", branch_name, worktree_path, base_ref],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> {:ok, worktree_path}
        {output, _code} -> {:error, "failed to create worktree: #{String.trim(output)}"}
      end
    end

    defp start_codex_session(worktree_path, params, context) do
      start_params =
        %{
          provider: "codex",
          cwd: worktree_path,
          permission_mode: "default",
          timeout: get_param(params, :timeout) || @default_timeout
        }
        |> put_if_present(:model, get_param(params, :model))
        |> put_if_present(:allowed_tools, get_param(params, :allowed_tools))
        |> put_if_present(:disallowed_tools, get_param(params, :disallowed_tools))

      call_action(Acp.StartSession, start_params, context)
    end

    defp prompt_codex(session, worktree_path, params, context) do
      session_pid = session[:session_pid] || session["session_pid"]

      prompt_params = %{
        session_pid: session_pid,
        prompt: build_prompt(worktree_path, params),
        timeout: get_param(params, :timeout) || @default_timeout
      }

      call_action(Acp.SendMessage, prompt_params, context)
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
      validations =
        params
        |> validation_commands()
        |> Enum.map(fn command ->
          run_validation(worktree_path, command, params, context)
        end)

      if Enum.all?(validations, & &1.passed) do
        {:ok, validations}
      else
        {:validation_failed, validations}
      end
    end

    defp run_validation(worktree_path, command, params, context) do
      timeout = get_param(params, :validation_timeout) || @default_validation_timeout

      case call_action(
             Shell.Execute,
             %{command: command, cwd: worktree_path, timeout: timeout, sandbox: :basic},
             context
           ) do
        {:ok, result} when is_map(result) ->
          exit_code = result[:exit_code] || result["exit_code"]

          %{
            command: command,
            passed: exit_code == 0,
            exit_code: exit_code,
            stdout: result[:stdout] || result["stdout"] || "",
            stderr: result[:stderr] || result["stderr"] || ""
          }

        {:ok, :pending_approval, proposal_id} ->
          %{
            command: command,
            passed: false,
            exit_code: nil,
            stdout: "",
            stderr: "pending approval: #{proposal_id}"
          }

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
          commit
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
           extra \\ []
         ) do
      %{
        status: status,
        repo_path: repo_root,
        worktree_path: worktree_path,
        branch: branch_name,
        commit: commit_hash(commit),
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

    defp map_value(map, key) when is_map(map) do
      cond do
        Map.has_key?(map, key) -> Map.get(map, key)
        Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
        true -> nil
      end
    end

    defp map_value(_map, _key), do: nil

    defp truthy?(true), do: true
    defp truthy?("true"), do: true
    defp truthy?(_value), do: false

    defp commit_hash(commit), do: map_value(commit, :commit_hash) || map_value(commit, :hash)

    defp commit_message(params) do
      title = get_param(params, :pr_title) || pr_title(params)
      String.slice(title, 0, 72)
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

      ## Codex Response

      #{response_text(response)}

      ## Validation

      #{validation_text}

      Human review and merge are required.
      """
      |> String.trim()
    end

    defp validation_commands(params) do
      case get_param(params, :validation_commands) do
        commands when is_list(commands) and commands != [] -> commands
        _ -> @default_validation_commands
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
