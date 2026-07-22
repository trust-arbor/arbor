defmodule Arbor.Orchestrator.CodingChangePipelineTest do
  @moduledoc """
  Structural + deterministic execution tests for coding-change-v1.dot.

  Execution uses a fake ActionsExecutor; no real shell, network, ACP, or LLM.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :coding_change_pipeline

  @pipeline_path "apps/arbor_orchestrator/priv/pipelines/coding-change-v1.dot"

  @exec_actions ~w(
    coding_workspace_acquire
    coding_workspace_inspect
    coding_workspace_release
    coding_workspace_committed_change
    coding_workspace_recovery_summary
    acp_start_session
    acp_send_message
    acp_session_status
    acp_close_session
    mix_compile
    coding_reviewed_commit
    git_pr
    council_review_change
  )

  # ---------------------------------------------------------------------------
  # Fake ActionsExecutor: scripted terminal-path fixtures
  # ---------------------------------------------------------------------------

  defmodule FakeActionsExecutor do
    @moduledoc false

    def execute(name, args, _workdir, _opts) do
      state = Process.get(:coding_change_fake_state)

      if is_nil(state) do
        {:error, "fake executor state missing for #{name}"}
      else
        Agent.update(state, fn s ->
          %{s | calls: s.calls ++ [{name, stringify_keys(args)}]}
        end)

        scenario = Agent.get(state, & &1.scenario)
        counters = Agent.get(state, & &1.counters)

        case dispatch(name, args, scenario, counters, state) do
          {:ok, result} when is_map(result) ->
            {:ok, Jason.encode!(result)}

          other ->
            other
        end
      end
    end

    defp dispatch(name, args, scenario, counters, state) do
      case name do
        "coding_workspace_acquire" ->
          case scenario do
            :acquire_failed ->
              {:error, "acquire rejected"}

            _ ->
              {:ok,
               %{
                 workspace_id: "ws_fixture_1",
                 repo_path:
                   Map.get(args, "repo_path") || Map.get(args, :repo_path) || "/tmp/repo",
                 worktree_path: "/tmp/ws_fixture_1",
                 branch:
                   Map.get(args, "branch_name") || Map.get(args, :branch_name) ||
                     "arbor/coding-agent/fixture",
                 base_commit: "basecommit0001",
                 ownership: "owned",
                 active: true
               }}
          end

        "acp_start_session" ->
          n = Map.get(counters, :start, 0)
          Agent.update(state, fn s -> %{s | counters: Map.put(s.counters, :start, n + 1)} end)

          case scenario do
            :worker_open_failed ->
              {:error, "worker open failed"}

            :recovery_reopen_failed when n == 1 ->
              {:error, "recovery reopen failed"}

            # Initial explicit resume: fake the StartSession FS_NOT_FOUND envelope
            # at the action boundary. With fallback, return the post-retry success
            # shape (continuity=fresh_recovery + replacement provider id). Without
            # fallback, surface the wire error so open_worker terminalizes.
            scenario
            when scenario in [
                   :initial_resume_fs_not_found_recovery,
                   :initial_resume_fs_not_found_no_fallback
                 ] and n == 0 ->
              initial_resume_start_response(scenario, args)

            _ ->
              replacement? = n > 0

              worker_id =
                if replacement?, do: "acp_worker_fixture_2", else: "acp_worker_fixture_1"

              session_id =
                cond do
                  scenario in [:recovery_status_failed_without_id, :recovery_status_empty_no_id] and
                      not replacement? ->
                    ""

                  replacement? ->
                    "sess_2"

                  true ->
                    "sess_1"
                end

              continuity =
                cond do
                  not replacement? -> "new"
                  scenario == :recovery_fresh_success -> "fresh_recovery"
                  scenario == :recovery_continuity_new -> "new"
                  scenario == :recovery_continuity_unknown -> "unknown"
                  true -> "resumed"
                end

              {:ok,
               %{
                 worker_session_id: worker_id,
                 session_id: session_id,
                 provider: Map.get(args, "provider") || Map.get(args, :provider) || "codex",
                 model: "default",
                 status: "ready",
                 continuity: continuity,
                 pooled:
                   (Map.get(args, "use_pool") || Map.get(args, :use_pool) || false) in [
                     true,
                     "true"
                   ]
               }}
          end

        "acp_send_message" ->
          implement_response(scenario, counters, state)

        "acp_session_status" ->
          n = Map.get(counters, :status, 0)
          Agent.update(state, fn s -> %{s | counters: Map.put(s.counters, :status, n + 1)} end)

          case scenario do
            scenario
            when scenario in [
                   :recovery_status_failure_with_id,
                   :recovery_status_failed_without_id
                 ] ->
              {:error, "session status unavailable"}

            scenario
            when scenario in [:recovery_status_empty_preserves_id, :recovery_status_empty_no_id] ->
              {:ok, %{session_id: ""}}

            _ ->
              {:ok, %{session_id: "status_sess_1"}}
          end

        "coding_workspace_recovery_summary" ->
          n = Map.get(counters, :recovery_summary, 0)

          Agent.update(state, fn s ->
            %{s | counters: Map.put(s.counters, :recovery_summary, n + 1)}
          end)

          pending = Map.get(args, "pending_prompt") || Map.get(args, :pending_prompt) || ""
          {:ok, %{workspace_id: "ws_fixture_1", recovery_prompt: "RECOVERY SUMMARY\n" <> pending}}

        "coding_workspace_inspect" ->
          inspect_response(scenario, counters, state, args)

        "mix_compile" ->
          validate_response(scenario, counters, state)

        "coding_reviewed_commit" ->
          commit_response(scenario, counters, state, args)

        "coding_workspace_committed_change" ->
          committed_change_response(scenario, args)

        "council_review_change" ->
          review_response(scenario, counters, state, args)

        "git_pr" ->
          pr_response(scenario)

        "acp_close_session" ->
          case scenario do
            :close_failed ->
              {:error, "close session failed"}

            :recovery_close_failed ->
              return_to_pool =
                (Map.get(args, "return_to_pool") || Map.get(args, :return_to_pool) || false) in [
                  true,
                  "true"
                ]

              if return_to_pool do
                {:ok, %{worker_session_id: "acp_worker_fixture_1", status: "closed"}}
              else
                {:error, "stale close failed"}
              end

            _ ->
              return_to_pool =
                (Map.get(args, "return_to_pool") || Map.get(args, :return_to_pool) || false) in [
                  true,
                  "true"
                ]

              {:ok,
               %{
                 worker_session_id: "acp_worker_fixture_1",
                 status: if(return_to_pool, do: "returned_to_pool", else: "closed")
               }}
          end

        "coding_workspace_release" ->
          mode = Map.get(args, "mode") || Map.get(args, :mode) || "retain"

          result = %{
            workspace_id: "ws_fixture_1",
            status: if(mode == "retain", do: "retained", else: "removed"),
            mode: mode,
            active: false
          }

          result =
            if mode == "retain" do
              Map.put(result, :expires_at, "2026-07-12T12:00:00Z")
            else
              result
            end

          {:ok, result}

        other ->
          {:error, "unexpected action in fixture: #{other}"}
      end
    end

    # Resume-against-new-worktree error shape. Used only when the fixture
    # deliberately surfaces the failure without StartSession fallback.
    @fs_not_found_wire_error %{
      "code" => -32_603,
      "data" => %{
        "code" => "FS_NOT_FOUND",
        "detail" => "No such file or directory (os error 2)"
      },
      "message" => "Path not found."
    }

    @provider_account_exhausted_reason "ACP provider account credits exhausted or monthly spending limit reached (HTTP 403)"

    defp initial_resume_start_response(scenario, args) do
      session_id = Map.get(args, "session_id") || Map.get(args, :session_id)
      fallback = Map.get(args, "fallback_to_fresh_on_resume_unavailable")
      fallback = fallback || Map.get(args, :fallback_to_fresh_on_resume_unavailable)
      resume? = is_binary(session_id) and session_id != ""
      fallback? = fallback in [true, "true"]

      cond do
        # Mirrors StartSession after classify_resume_unavailability(FS_NOT_FOUND)
        # + one create_session retry: graph sees success, not the wire error.
        scenario == :initial_resume_fs_not_found_recovery and resume? and fallback? ->
          {:ok,
           %{
             worker_session_id: "acp_worker_fixture_fresh",
             session_id: "provider_sess_fresh_after_fs_not_found",
             provider: Map.get(args, "provider") || Map.get(args, :provider) || "codex",
             model: "default",
             status: "ready",
             continuity: "fresh_recovery",
             pooled:
               (Map.get(args, "use_pool") || Map.get(args, :use_pool) || false) in [
                 true,
                 "true"
               ]
           }}

        # Without the reviewed fallback flag the action fails closed at open_worker.
        resume? ->
          {:error, @fs_not_found_wire_error}

        true ->
          {:error, "initial resume fixture requires param.session_id"}
      end
    end

    defp implement_response(scenario, counters, state) do
      n = Map.get(counters, :implement, 0)
      Agent.update(state, fn s -> %{s | counters: Map.put(s.counters, :implement, n + 1)} end)

      case {scenario, n} do
        {:uncertain_send_recovery, 0} ->
          # Uncertain transport failure: the send may have executed on the
          # worker. The workspace mutated before the transport error surfaced,
          # so the owner-observed fingerprint changes even though implement
          # returns an error. Mutation timing is tracked explicitly in fake
          # state (not derived from send count) so a regression that overwrites
          # the logical-turn baseline would be observed as no_changes. The
          # recovered send (n=1) does not mutate further.
          Agent.update(state, fn s -> %{s | mutations: s.mutations + 1} end)
          {:error, "transport: send may have executed (uncertain)"}

        {scenario, 0}
        when scenario in [
               :recovery_resumed_success,
               :recovery_fresh_success,
               :recovery_status_failure_with_id,
               :recovery_status_failed_without_id,
               :recovery_status_empty_preserves_id,
               :recovery_status_empty_no_id,
               :recovery_close_failed,
               :recovery_reopen_failed,
               :recovery_provider_account_exhausted,
               :recovery_second_send_failed,
               :recovery_continuity_new,
               :recovery_continuity_unknown
             ] ->
          {:error, "initial send failed"}

        {:provider_account_exhausted, _} ->
          provider_account_exhausted_receipt()

        {:recovery_provider_account_exhausted, 1} ->
          provider_account_exhausted_receipt()

        {:recovery_second_send_failed, 1} ->
          {:error, "recovered send failed"}

        {:implement_hard_fail, _} ->
          {:error, "implement transport failed"}

        _ ->
          text =
            case {scenario, n} do
              {:narrative_changed, _} ->
                "I implemented the requested change across several files. Summary: done."

              {:narrative_no_changes, _} ->
                "I looked around and decided nothing needed changing."

              {:no_changes, _} ->
                "No workspace changes were necessary for this task."

              {:validation_failed, 0} ->
                "First pass attempted a fix; compile still broken."

              {:validation_failed, _} ->
                "Second pass still leaves validation failing."

              {:validation_hard_fail, _} ->
                "Implement complete; validation may crash."

              {:review_requires_rework, _} ->
                "Implemented a change that review will ask to rework."

              {:rework_exhausted, 0} ->
                "Initial implementation."

              {:rework_exhausted, _} ->
                "After rework attempt."

              {:review_rejected, _} ->
                "Implemented path that review rejects."

              {:review_failed, _} ->
                "Implemented path that review crashes."

              {:committed_change_failed, _} ->
                "Implemented; materialization will fail."

              {:commit_hard_fail, _} ->
                "Implemented; commit will fail."

              {:commit_approval_denied, _} ->
                "Implemented; awaiting operator deny."

              {:commit_approval_rework_success, 0} ->
                "First implement before operator rework."

              {:commit_approval_rework_success, _} ->
                "After operator rework feedback applied."

              {:commit_approval_rework_exhausted, 0} ->
                "First implement before exhausted operator rework."

              {:commit_approval_rework_exhausted, _} ->
                "After operator rework attempt that exhausts budget."

              {:validation_then_operator_rework_exhausted, 0} ->
                "Broken first implement for validation then operator path."

              {:validation_then_operator_rework_exhausted, _} ->
                "After validation rework before operator exhaustion."

              {:inspect_hard_fail, _} ->
                "Implement complete; inspect will fail."

              {:narrative_validation_rework, 0} ->
                "Initial narrative implement before validation rework."

              {:narrative_validation_rework, _} ->
                "Narrative validation rework summary: fixed compile issues."

              {:narrative_review_rework, 0} ->
                "Initial narrative implement before review rework."

              {:narrative_review_rework, _} ->
                "Narrative review rework summary: addressed council feedback."

              {:rework_no_progress, 0} ->
                "First implement created a candidate."

              {:rework_no_progress, _} ->
                "Rework claimed progress but owner observes none."

              {:rework_with_progress, 0} ->
                "First implement created a candidate."

              {:rework_with_progress, _} ->
                "Rework actually changed the workspace."

              {:max_tokens_stop, _} ->
                "Partial output truncated by token budget."

              {:missing_stop_reason, _} ->
                "Provider omitted stop_reason."

              {:missing_workspace, _} ->
                "Implement claimed success but worktree is gone."

              {:missing_workspace_before_send, _} ->
                "This send must never be reached."

              {:close_failed, _} ->
                "Implement complete on close-failure path."

              {:human_review_required, _} ->
                "Implement complete; human review required."

              {:pr_failed, _} ->
                "Implement complete; PR will fail."

              {:pr_created, _} ->
                "Implement complete; PR will succeed."

              {:change_committed, _} ->
                "Implement complete; commit path."

              {:self_commit_adopt, _} ->
                "Self-committed in the worktree."

              _ ->
                "Default narrative implement summary."
            end

          response_session_id =
            cond do
              scenario == :initial_resume_fs_not_found_recovery ->
                # Keep the replacement provider conversation id from open_worker.
                "provider_sess_fresh_after_fs_not_found"

              scenario in [
                :recovery_resumed_success,
                :recovery_fresh_success,
                :recovery_status_failure_with_id,
                :recovery_status_failed_without_id,
                :recovery_status_empty_preserves_id,
                :recovery_status_empty_no_id,
                :recovery_close_failed,
                :recovery_reopen_failed,
                :recovery_second_send_failed,
                :recovery_continuity_new,
                :recovery_continuity_unknown,
                :uncertain_send_recovery
              ] and n > 0 ->
                "sess_2"

              true ->
                "sess_1"
            end

          stop_reason =
            case scenario do
              :max_tokens_stop -> "max_tokens"
              :missing_stop_reason -> ""
              _ -> "end_turn"
            end

          {:ok,
           %{
             delivery_status: "delivered",
             text: text,
             stop_reason: stop_reason,
             session_id: response_session_id,
             usage: %{}
           }}
      end
    end

    defp provider_account_exhausted_receipt do
      {:ok,
       %{
         delivery_status: "provider_account_exhausted",
         failure_reason: @provider_account_exhausted_reason,
         text: "",
         stop_reason: "",
         session_id: "",
         context_pressure: false,
         usage: %{}
       }}
    end

    defp inspect_response(scenario, counters, state, args) do
      n = Map.get(counters, :inspect, 0)
      Agent.update(state, fn s -> %{s | counters: Map.put(s.counters, :inspect, n + 1)} end)

      baseline =
        Map.get(args, "baseline_fingerprint") || Map.get(args, :baseline_fingerprint)

      post_turn? = is_binary(baseline) and baseline != ""
      # Implement counter is incremented in implement_response before post-turn inspect.
      sends = Map.get(counters, :implement, 0)

      case scenario do
        :inspect_hard_fail when post_turn? ->
          {:error, "inspect failed"}

        _ ->
          base = %{
            workspace_id: "ws_fixture_1",
            worktree_path: "/tmp/ws_fixture_1",
            branch: "arbor/coding-agent/fixture",
            base_commit: "basecommit0001",
            ownership: "owned",
            active: true,
            exists: true
          }

          fingerprint =
            fixture_fingerprint(scenario, sends, post_turn?, Agent.get(state, & &1.mutations))

          view =
            case scenario do
              scenario when scenario in [:no_changes, :narrative_no_changes] ->
                Map.merge(base, %{
                  dirty: false,
                  head_commit: "basecommit0001",
                  changed_from_base: false,
                  fingerprint: fingerprint
                })

              :missing_workspace when post_turn? ->
                Map.merge(base, %{
                  exists: false,
                  dirty: false,
                  head_commit: nil,
                  changed_from_base: false,
                  fingerprint: fingerprint
                })

              :missing_workspace_before_send when not post_turn? ->
                Map.merge(base, %{
                  exists: false,
                  dirty: false,
                  head_commit: nil,
                  changed_from_base: false,
                  fingerprint: fingerprint
                })

              :self_commit_adopt ->
                Map.merge(base, %{
                  dirty: false,
                  head_commit: "selfcommit9999",
                  changed_from_base: true,
                  fingerprint: fingerprint
                })

              _ ->
                Map.merge(base, %{
                  dirty: fingerprint != "fp-clean",
                  head_commit: "basecommit0001",
                  changed_from_base: fingerprint != "fp-clean",
                  fingerprint: fingerprint
                })
            end

          turn_progressed =
            if post_turn? do
              view.fingerprint != baseline
            else
              true
            end

          {:ok, Map.put(view, :turn_progressed, turn_progressed)}
      end
    end

    # Fingerprints are relative to completed ACP sends so pre-turn capture and
    # post-turn inspect share a stable owner-observed identity for each turn.
    # The uncertain-send scenario derives its fingerprint from explicit
    # mutation timing (state.mutations) rather than send count, so a regression
    # that re-captures the baseline mid-recovery is observable as no_changes.
    defp fixture_fingerprint(scenario, sends, post_turn?, mutations) do
      case scenario do
        s when s in [:no_changes, :narrative_no_changes] ->
          "fp-clean"

        :missing_workspace when post_turn? ->
          "sha256:missing-worktree"

        :missing_workspace_before_send when not post_turn? ->
          "sha256:missing-worktree"

        :self_commit_adopt ->
          if post_turn? or sends > 0, do: "fp-self-commit", else: "fp-clean"

        :uncertain_send_recovery ->
          if mutations == 0, do: "fp-clean", else: "fp-uncertain-mutated-#{mutations}"

        :rework_no_progress ->
          cond do
            sends == 0 and not post_turn? -> "fp-clean"
            # After the first successful implement, rework leaves the same fingerprint.
            true -> "fp-dirty-1"
          end

        :rework_with_progress ->
          cond do
            sends == 0 and not post_turn? -> "fp-clean"
            not post_turn? -> "fp-after-send-#{sends}"
            true -> "fp-after-send-#{sends}"
          end

        _ ->
          cond do
            sends == 0 and not post_turn? -> "fp-clean"
            not post_turn? -> "fp-after-send-#{sends}"
            true -> "fp-after-send-#{sends}"
          end
      end
    end

    defp validate_response(scenario, counters, state) do
      n = Map.get(counters, :validate, 0)
      Agent.update(state, fn s -> %{s | counters: Map.put(s.counters, :validate, n + 1)} end)

      case scenario do
        :validation_hard_fail ->
          {:error, "mix compile crashed"}

        _ ->
          passed =
            case {scenario, n} do
              {:validation_failed, _} -> false
              {:rework_exhausted, 0} -> false
              {:rework_exhausted, _} -> true
              {:validation_then_review_rework_success, 0} -> false
              {:validation_then_review_rework_success, _} -> true
              {:validation_then_operator_rework_exhausted, 0} -> false
              {:validation_then_operator_rework_exhausted, _} -> true
              {:narrative_validation_rework, 0} -> false
              {:narrative_validation_rework, _} -> true
              # First implement progresses then fails validation so rework runs;
              # rework_no_progress never reaches a second validate.
              {:rework_no_progress, _} -> false
              {:rework_with_progress, 0} -> false
              {:rework_with_progress, _} -> true
              _ -> true
            end

          stdout = if(passed, do: "compile ok", else: "RAW_VALIDATION_STDOUT_SENTINEL")
          stderr = if(passed, do: "", else: "RAW_VALIDATION_STDERR_SENTINEL")

          feedback = %{
            "exit_code" => if(passed, do: 0, else: 1),
            "passed" => passed,
            "stdout_excerpt" => if(passed, do: "compile ok", else: "bounded stdout excerpt"),
            "stderr_excerpt" => if(passed, do: "", else: "bounded compile feedback"),
            "stdout_truncated" => not passed,
            "stderr_truncated" => not passed,
            "stdout_sha256" => String.duplicate("a", 64),
            "stderr_sha256" => String.duplicate("b", 64)
          }

          {:ok,
           %{
             path: "/tmp/ws_fixture_1",
             exit_code: if(passed, do: 0, else: 1),
             passed: passed,
             stdout: stdout,
             stderr: stderr,
             feedback: feedback,
             feedback_json: Jason.encode!(feedback)
           }}
      end
    end

    defp commit_response(scenario, counters, state, args) do
      n = Map.get(counters, :commit, 0)
      Agent.update(state, fn s -> %{s | counters: Map.put(s.counters, :commit, n + 1)} end)

      dirty? =
        Map.get(args, "workspace_dirty") in [true, "true", "1", 1] or
          Map.get(args, :workspace_dirty) in [true, "true", "1", 1]

      case {scenario, n} do
        {:self_commit_adopt, _} ->
          # Clean worktree still requires the reviewed gate (fresh approval path).
          {:ok,
           %{
             interaction_outcome: "",
             request_id: "",
             note: "",
             path: "/tmp/ws_fixture_1",
             commit_hash: "selfcommit9999",
             adopted: true
           }}

        {:commit_hard_fail, _} ->
          {:error, "git commit failed"}

        {:commit_approval_denied, _} ->
          {:ok,
           %{
             interaction_outcome: "denied",
             request_id: "irq_commit_denied_1",
             note: "operator denied this commit",
             commit_hash: "",
             path: "",
             message: ""
           }}

        {:commit_approval_rework_success, 0} ->
          {:ok,
           %{
             interaction_outcome: "rework",
             request_id: "irq_commit_rework_1",
             note: "please fix the public API name",
             commit_hash: "",
             path: "",
             message: ""
           }}

        {:commit_approval_rework_success, _} ->
          {:ok,
           %{
             interaction_outcome: "",
             request_id: "irq_commit_rework_approved_2",
             note: "",
             path: "/tmp/ws_fixture_1",
             commit_hash: "commitrework456",
             message: "fixture commit after rework"
           }}

        {:commit_approval_rework_exhausted, _} ->
          {:ok,
           %{
             interaction_outcome: "rework",
             request_id: "irq_commit_rework_exhausted_#{n + 1}",
             note: "still not right",
             commit_hash: "",
             path: "",
             message: ""
           }}

        {:validation_then_operator_rework_exhausted, _} ->
          {:ok,
           %{
             interaction_outcome: "rework",
             request_id: "irq_commit_op_#{n + 1}",
             note: "operator rework after validation",
             commit_hash: "",
             path: "",
             message: ""
           }}

        _ ->
          commit_hash =
            if scenario in [
                 :review_requires_rework,
                 :rework_exhausted,
                 :validation_then_review_rework_success,
                 :narrative_review_rework,
                 :resolved_finding_accepted,
                 :in_delta_blocker_reworks,
                 :outside_delta_side_channel,
                 :two_review_reworks_exhaust
               ] do
              "commit-review-#{n + 1}"
            else
              if(dirty?, do: "commitabc123", else: "selfcommit9999")
            end

          {:ok,
           %{
             interaction_outcome: "",
             request_id: "",
             note: "",
             path: "/tmp/ws_fixture_1",
             commit_hash: commit_hash,
             message: "fixture commit"
           }}
      end
    end

    defp committed_change_response(:committed_change_failed, _args) do
      {:error, "dirty workspace or missing base"}
    end

    defp committed_change_response(_scenario, args) do
      commit_hash = Map.get(args, "commit") || Map.get(args, :commit) || "commitabc123"
      prior_commit = Map.get(args, "prior_commit") || Map.get(args, :prior_commit)

      result = %{
        workspace_id: "ws_fixture_1",
        commit_hash: commit_hash,
        diff: "diff --git a/file.ex b/file.ex\n+hello\n",
        files: ["file.ex"],
        base_ref: "basecommit0001",
        branch: "arbor/coding-agent/fixture",
        worktree_path: "/tmp/ws_fixture_1"
      }

      result =
        if is_binary(prior_commit) and prior_commit != "" do
          Map.merge(result, %{
            prior_candidate_commit: prior_commit,
            delta_diff: "diff --git a/file.ex b/file.ex\n+cycle delta\n",
            delta_files: ["file.ex"],
            delta_ranges: %{"file.ex" => [[1, 3]]}
          })
        else
          result
        end

      {:ok, result}
    end

    defp review_response(scenario, counters, state, args) do
      case Arbor.Actions.Council.build_code_review_request(args) do
        {:ok, _request} -> do_review_response(scenario, counters, state, args)
        {:error, reason} -> {:error, "invalid real review request: #{inspect(reason)}"}
      end
    end

    defp do_review_response(scenario, counters, state, args) do
      n = Map.get(counters, :review, 0)
      Agent.update(state, fn s -> %{s | counters: Map.put(s.counters, :review, n + 1)} end)

      case scenario do
        :review_failed ->
          {:error, "council unavailable"}

        :review_rejected ->
          {:ok, review_payload("stop", args)}

        :human_review_required ->
          {:ok, review_payload("human_review", args)}

        :review_requires_rework ->
          {:ok, review_payload("rework", args)}

        :rework_exhausted ->
          # After validation rework, review keeps asking for rework until exhausted
          {:ok, review_payload("rework", args)}

        :validation_then_review_rework_success ->
          {:ok, review_payload(if(n == 0, do: "rework", else: "auto_proceed"), args)}

        :narrative_review_rework ->
          {:ok, review_payload(if(n == 0, do: "rework", else: "auto_proceed"), args)}

        :resolved_finding_accepted ->
          {:ok, review_payload(if(n == 0, do: "rework", else: "auto_proceed"), args)}

        :in_delta_blocker_reworks ->
          tier = if(n < 2, do: "rework", else: "auto_proceed")
          {:ok, review_payload(tier, args, :new_in_delta_on_cycle_two)}

        :outside_delta_side_channel ->
          tier = if(n == 0, do: "rework", else: "auto_proceed")
          {:ok, review_payload(tier, args, :outside_delta_on_cycle_two)}

        :two_review_reworks_exhaust ->
          {:ok, review_payload("rework", args)}

        :unknown_review_tier ->
          {:ok, review_payload("unexpected_tier", args)}

        :missing_review_tier ->
          {:ok, Map.delete(review_payload("auto_proceed", args), :tier_decision)}

        :malformed_review_cycle ->
          {:ok, Map.put(review_payload("auto_proceed", args), :review_cycle, "01")}

        _ ->
          {:ok, review_payload("auto_proceed", args)}
      end
    end

    defp review_payload(tier, args, mode \\ :normal) do
      recommendation = if(tier == "stop", do: "reject", else: "revise")
      decision = strict_review_decision(tier, args, mode)

      feedback = %{
        "recommendation" => recommendation,
        "tier" => %{
          "blast_radius" => "low",
          "decision" => tier,
          "reasons" => ["bounded_reason"]
        },
        "verdict" => %{
          "weaknesses" => ["bounded council feedback"],
          "scores" => %{"correctness" => 0.8},
          "counts" => %{"approve" => 1, "reject" => 0, "abstain" => 0}
        },
        "flags" => %{
          "security_veto" => false,
          "human_required" => tier == "human_review",
          "authority_widening" => false
        }
      }

      %{
        status: "reviewed",
        tier_decision: tier,
        verdict: %{
          overall_score: 0.8,
          dimension_scores: %{"correctness" => 0.8},
          strengths: ["focused change"],
          weaknesses: ["bounded council feedback"],
          recommendation: recommendation,
          mode: "binding",
          meta: %{
            "source" => "code_review_council",
            "decision" => "approved",
            "branch" => "arbor/coding-agent/fixture",
            "base_ref" => "basecommit0001",
            "files" => ["file.ex"],
            "agent_id" => "agent_fixture",
            "approve_count" => 1,
            "reject_count" => 0,
            "abstain_count" => 0,
            "quorum_met" => true
          }
        },
        recommendation: recommendation,
        decision: "approved",
        branch: "arbor/coding-agent/fixture",
        files: ["file.ex"],
        approve_count: 1,
        reject_count: 0,
        abstain_count: 0,
        quorum_met: true,
        human_required: tier == "human_review",
        security_veto: false,
        authority_widening: false,
        blast_radius: "low",
        tier_reasons: ["bounded_reason"],
        persistence: %{"status" => "recorded"},
        feedback: feedback,
        feedback_json: Jason.encode!(feedback),
        review_cycle: decision["review_cycle"],
        finding_ledger: decision["finding_ledger"],
        review_disposition: decision["review_disposition"]
      }
    end

    defp strict_review_decision(tier, args, mode) do
      cycle = parse_cycle(Map.get(args, "review_cycle") || Map.get(args, :review_cycle))
      ledger = Map.get(args, "finding_ledger") || Map.get(args, :finding_ledger) || %{}
      delta_ranges = Map.get(args, "delta_ranges") || Map.get(args, :delta_ranges) || %{}
      findings = Map.get(ledger, "findings", %{})

      updates =
        if tier == "auto_proceed" do
          findings
          |> Enum.filter(fn {_id, finding} -> finding["owner"] == "correctness" end)
          |> Enum.map(fn {id, _finding} -> %{"id" => id, "state" => "fixed"} end)
        else
          []
        end

      new_findings =
        cond do
          tier == "rework" and cycle == 1 ->
            [strict_finding("initial blocker", 1)]

          mode == :new_in_delta_on_cycle_two and cycle == 2 ->
            [strict_finding("new in-delta blocker", 2)]

          mode == :outside_delta_on_cycle_two and cycle == 2 ->
            [strict_finding("outside-delta side channel", 99)]

          true ->
            []
        end

      vote = if(tier == "rework", do: "reject", else: "approve")

      report = %{
        "vote" => vote,
        "finding_updates" => updates,
        "new_findings" => new_findings
      }

      branch = %{
        "id" => "correctness",
        "status" => "success",
        "context_updates" => %{"last_response" => Jason.encode!(report)}
      }

      {:ok, decision} =
        Arbor.Actions.Consensus.DecideReview.run(
          %{
            results: [branch],
            review_cycle: cycle,
            finding_ledger: ledger,
            delta_ranges: delta_ranges
          },
          %{}
        )

      decision
    end

    defp strict_finding(title, line) do
      %{
        "severity" => "blocking",
        "title" => title,
        "required_action" => "fix #{title}",
        "anchor" => %{"path" => "file.ex", "side" => "new", "line" => line},
        "evidence" => "fixture evidence"
      }
    end

    defp parse_cycle(cycle) when is_integer(cycle), do: cycle
    defp parse_cycle(cycle) when is_binary(cycle), do: String.to_integer(cycle)

    defp pr_response(:pr_failed), do: {:error, "scm rejected draft PR"}
    defp pr_response(_), do: {:ok, %{url: "https://example.test/pr/1", number: 1, draft: true}}

    defp stringify_keys(map) when is_map(map) do
      Map.new(map, fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {k, v}
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp load_dot do
    path =
      [
        @pipeline_path,
        Path.expand("../../../priv/pipelines/coding-change-v1.dot", __DIR__),
        Application.app_dir(:arbor_orchestrator, "priv/pipelines/coding-change-v1.dot")
      ]
      |> Enum.find(@pipeline_path, &File.exists?/1)

    File.read!(path)
  end

  defp load_graph do
    assert {:ok, graph} = Arbor.Orchestrator.parse(load_dot())
    graph
  end

  defp run_fixture(scenario, initial_overrides \\ %{}, dot_source \\ load_dot()) do
    {:ok, state} =
      Agent.start_link(fn ->
        %{scenario: scenario, calls: [], counters: %{}, mutations: 0}
      end)

    Process.put(:coding_change_fake_state, state)

    on_exit(fn ->
      Process.delete(:coding_change_fake_state)
      if Process.alive?(state), do: Agent.stop(state)
    end)

    # Concrete optional acquire keys silence ExecHandler missing-context warnings.
    initial =
      %{
        "task" => "fixture task for #{scenario}",
        "repo_path" => "/tmp/repo",
        "base_ref" => "HEAD",
        "branch_name" => "arbor/coding-agent/fixture",
        "worktree_base_dir" => "/tmp/worktrees",
        "acp_agent" => "codex",
        "timeout" => 900_000,
        "inactivity_timeout_ms" => 300_000,
        "open_pr" => "false",
        "retain_workspace" => "true",
        "submit_review" => "true",
        "session.agent_id" => "agent_fixture",
        "session.task_id" => "task_fixture"
      }
      |> Map.merge(initial_overrides)

    opts = [
      authorization: false,
      actions_executor: FakeActionsExecutor,
      initial_values: initial,
      max_steps: 200,
      sleep_fn: fn _ -> :ok end
    ]

    result = Arbor.Orchestrator.run(dot_source, opts)
    calls = Agent.get(state, & &1.calls)
    {result, calls}
  end

  defp assert_json_clean_context(context) when is_map(context) do
    Enum.each(context, fn {k, v} ->
      assert is_binary(k) or is_atom(k)
      assert json_clean_value?(v), "context key #{inspect(k)} is not JSON-clean: #{inspect(v)}"
    end)
  end

  defp json_clean_value?(value) do
    case value do
      %{} = map when not is_struct(map) ->
        Enum.all?(map, fn {k, v} -> (is_atom(k) or is_binary(k)) and json_clean_value?(v) end)

      list when is_list(list) ->
        Enum.all?(list, &json_clean_value?/1)

      v when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v) ->
        true

      _ ->
        false
    end
  end

  defp assert_opaque_handles(context) do
    ws = context["workspace_id"] || context[:workspace_id]
    worker = context["worker_session_id"] || context[:worker_session_id]

    if ws do
      assert is_binary(ws)
      refute String.contains?(ws, "#PID")
    end

    if worker do
      assert is_binary(worker)
      refute String.contains?(worker, "#PID")
    end
  end

  defp assert_closed_and_released(calls) do
    names = Enum.map(calls, fn {name, _} -> name end)
    assert "acp_close_session" in names
    assert "coding_workspace_release" in names

    release_args =
      calls
      |> Enum.filter(fn {name, _} -> name == "coding_workspace_release" end)
      |> Enum.map(fn {_, args} -> args end)

    assert length(release_args) == 1
  end

  defp assert_release_mode(calls, expected_mode) do
    assert {"coding_workspace_release", args} =
             Enum.find(calls, fn {name, _args} -> name == "coding_workspace_release" end)

    assert args["mode"] == expected_mode
  end

  defp assert_released(calls) do
    assert called?(calls, "coding_workspace_release")
  end

  defp assert_single_worker_session(calls, expected_send_count) do
    start_calls = Enum.filter(calls, fn {name, _args} -> name == "acp_start_session" end)
    send_calls = Enum.filter(calls, fn {name, _args} -> name == "acp_send_message" end)

    assert length(start_calls) == 1
    assert length(send_calls) == expected_send_count

    assert Enum.all?(send_calls, fn {_name, args} ->
             args["worker_session_id"] == "acp_worker_fixture_1"
           end)

    send_calls
  end

  defp assert_validation_inspections(calls, attempts) do
    inspect_calls =
      Enum.filter(calls, fn {name, _args} -> name == "coding_workspace_inspect" end)

    validation_captures =
      Enum.filter(inspect_calls, fn {_name, args} ->
        args["include_committable_tree"] in [true, "true"]
      end)

    assert length(inspect_calls) == attempts * 3
    assert length(validation_captures) == attempts
  end

  defp action_prompts(calls) do
    for {"acp_send_message", args} <- calls, do: args["prompt"]
  end

  defp called?(calls, action_name), do: Enum.any?(calls, fn {n, _} -> n == action_name end)

  # Mirror CodingPlan.Compiler rewrite_worker_open for explicit resume plans:
  # static session_id plus optional fallback flag on open_worker only.
  defp explicit_resume_open_worker_dot(opts) do
    fallback? = Keyword.get(opts, :fallback, true)

    insert =
      if fallback? do
        ~s(param.use_pool="true",\n    param.session_id="provider-session-from-prior-task",\n    param.fallback_to_fresh_on_resume_unavailable=true,)
      else
        ~s(param.use_pool="true",\n    param.session_id="provider-session-from-prior-task",)
      end

    # Target only open_worker (not open_recovery_worker): the next attrs after
    # param.use_pool are unique to the initial open node in the packaged graph.
    original = load_dot()

    needle =
      ~s(param.use_pool="true",\n    output_prefix="worker",\n    max_retries="0"\n  ])

    replacement = insert <> ~s(\n    output_prefix="worker",\n    max_retries="0"\n  ])
    assert String.contains?(original, needle)
    String.replace(original, needle, replacement, global: false)
  end

  defp called_with_prompt?(calls, fragment) do
    Enum.any?(action_prompts(calls), fn prompt ->
      is_binary(prompt) and String.contains?(prompt, fragment)
    end)
  end

  # ---------------------------------------------------------------------------
  # Structural / compile
  # ---------------------------------------------------------------------------

  describe "coding-change-v1.dot structure" do
    test "parses strictly, compiles typed IR, and has no error diagnostics" do
      dot = load_dot()
      assert {:ok, graph} = Arbor.Orchestrator.parse(dot)

      structural = Arbor.Orchestrator.validate(graph)
      structural_errors = Enum.filter(structural, &(&1.severity == :error))
      assert structural_errors == [], "structural errors: #{inspect(structural_errors)}"

      assert {:ok, compiled} = Arbor.Orchestrator.compile(graph)
      assert compiled.compiled == true

      diagnostics = Arbor.Orchestrator.validate_typed(compiled, [])
      errors = Enum.filter(diagnostics, &(&1.severity == :error))
      assert errors == [], "unexpected error diagnostics: #{inspect(errors)}"
    end

    test "all exec actions resolve and never call coding_produce_reviewable_change" do
      graph = load_graph()

      exec_actions =
        graph.nodes
        |> Map.values()
        |> Enum.filter(
          &(Map.get(&1.attrs, "type") == "exec" and Map.get(&1.attrs, "target") == "action")
        )
        |> Enum.map(&Map.get(&1.attrs, "action"))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      assert Enum.sort(@exec_actions) == exec_actions
      refute "coding_produce_reviewable_change" in exec_actions
      refute "coding.produce_reviewable_change" in exec_actions

      # Resolve each name the same way ActionsExecutor does
      for action <- exec_actions do
        assert {:ok, mod} = Arbor.Actions.name_to_module(action),
               "action #{action} does not resolve"

        assert is_atom(mod)
      end
    end

    test "acquire precedes mutation and cleanup branches through the reviewed retention policy" do
      graph = load_graph()
      assert graph.nodes["acquire_workspace"]
      assert graph.nodes["publish_workspace"]
      assert graph.nodes["release_workspace"]
      assert graph.nodes["close_worker"]

      publish = graph.nodes["publish_workspace"]
      assert publish.attrs["action"] == "coding_workspace_release"
      assert publish.attrs["context_keys"] == "workspace_id,mode,commit_hash,repo_path"

      release = graph.nodes["release_workspace"]
      assert release.attrs["action"] == "coding_workspace_release"
      assert release.attrs["context_keys"] == "workspace_id,mode"
      assert graph.nodes["route_release_mode"].attrs["fan_out"] == "false"
      assert graph.nodes["route_success_workspace_retention"].attrs["fan_out"] == "false"

      # Validation is top-level mix_compile (not nested shell)
      validate = graph.nodes["validate"]
      assert validate.attrs["action"] == "mix_compile"

      capture = graph.nodes["capture_validation_workspace"]

      assert capture.attrs == %{
               "type" => "exec",
               "target" => "action",
               "action" => "coding_workspace_inspect",
               "context_keys" => "workspace_id",
               "param.include_committable_tree" => "true",
               "output_prefix" => "validation_workspace",
               "max_retries" => "0"
             }

      assert graph.nodes["hoist_validation_candidate_tree_oid"].attrs["source_key"] ==
               "validation_workspace.committable_tree_oid"

      assert graph.nodes["hoist_validation_observed_at"].attrs["source_key"] ==
               "validation_workspace.committable_tree_observed_at"

      assert Enum.any?(
               graph.edges,
               &(&1.from == "prep_validation_path" and
                   &1.to == "capture_validation_workspace" and &1.attrs == %{})
             )

      assert Enum.any?(
               graph.edges,
               &(&1.from == "hoist_review_attestation_id" and
                   &1.to == "capture_validation_workspace" and &1.attrs == %{})
             )

      assert Enum.any?(
               graph.edges,
               &(&1.from == "hoist_validation_observed_at" and &1.to == "validate" and
                   &1.attrs["condition"] == "outcome=success")
             )

      # Commit path uses reviewed top-level action + operator interaction routing
      assert graph.nodes["commit_change"]
      refute Map.has_key?(graph.nodes["commit_change"].attrs, "project_interaction_control")
      assert graph.nodes["commit_change"].attrs["action"] == "coding_reviewed_commit"

      assert graph.nodes["commit_change"].attrs["context_keys"] ==
               "path,message,workspace_dirty,head_commit,workspace_id,expected_workspace_fingerprint,expected_tree_oid,prior_commit"

      # No-change / declined terminals discard owned worktrees and retire
      # invocation-created branches when tip still equals the recorded base.
      assert graph.nodes["prep_release_mode_discard"]
      assert graph.nodes["prep_release_mode_discard"].attrs["expression"] == "discard"
      assert graph.nodes["prep_release_mode_discard"].attrs["output_key"] == "mode"

      refute Map.has_key?(graph.nodes, "adopt_head_commit")
      assert graph.nodes["route_commit_interaction"]
      assert graph.nodes["status_approval_denied"]
      assert graph.nodes["check_operator_rework_category_budget"]
      assert graph.nodes["check_operator_rework_total_budget"]

      # No production prefer_rework_exhausted switch
      refute Map.has_key?(graph.nodes, "status_review_requires_rework")
      assert graph.nodes["status_rework_exhausted"]
      assert graph.nodes["legacy_status_review_requires_rework"]

      # Strict enum routers have explicit, single-path fallbacks. This keeps an
      # unconditional error edge from becoming a fan-out sibling.
      assert graph.nodes["route_review"].attrs["fan_out"] == "false"
      assert graph.nodes["route_commit_interaction"].attrs["fan_out"] == "false"
      assert graph.nodes["error_review_tier_invalid"]

      # Owner-observed outcome: no worker JSON protocol repair machinery.
      refute Map.has_key?(graph.nodes, "extract_worker_status")
      refute Map.has_key?(graph.nodes, "route_worker_status")
      refute Map.has_key?(graph.nodes, "repair_worker_protocol")
      refute Map.has_key?(graph.nodes, "build_protocol_repair_prompt")
      refute Map.has_key?(graph.nodes, "error_worker_protocol_invalid")
      refute Map.has_key?(graph.nodes, "check_protocol_retry_budget")
      refute Map.has_key?(graph.nodes, "inc_protocol_retry_count")
      refute Map.has_key?(graph.nodes, "reset_worker_turn_protocol_retry_count")
      refute Map.has_key?(graph.nodes, "status_declined")
      assert graph.nodes["inspect_workspace"]
      assert graph.nodes["capture_pre_turn_workspace"]
      assert graph.nodes["check_worker_stop_reason"]
      assert graph.nodes["check_workspace_exists"]
      assert graph.nodes["route_turn_progress"]
      assert graph.nodes["route_no_progress"]
      assert graph.nodes["error_worker_stop_reason_not_end_turn"]
      assert graph.nodes["error_workspace_missing"]
      assert graph.nodes["error_worker_turn_no_progress"]
      assert graph.nodes["init_protocol_retry_count"]

      for counter <-
            ~w(validation_rework_count review_rework_count operator_rework_count total_rework_count) do
        assert String.contains?(load_dot(), "output_key=\"#{counter}\"")
      end

      # Compatibility metric remains initialized; per-turn repair machinery is gone.
      assert load_dot() =~ "output_key=\"protocol_retry_count\""
      refute load_dot() =~ "output_key=\"worker_turn_protocol_retry_count\""
      refute load_dot() =~ "worker_protocol_invalid_json_after_retry"
      # Steering prompts still request one terminal JSON object for old-graph
      # compatibility, but never require JSON-only protocol output.
      assert load_dot() =~ "ONLY one valid JSON object and no prose or Markdown"
      refute load_dot() =~ "ONLY one JSON object"
      refute load_dot() =~ "ONLY a JSON object"
      refute load_dot() =~ "source_key=\"rework_count\""

      # Bind materialization to the exact commit produced by this run.
      load = graph.nodes["load_committed_change"]
      assert load.attrs["context_keys"] == "workspace_id,commit,prior_commit"

      assert graph.nodes["review_change"].attrs["context_keys"] ==
               "diff,files,branch,base_ref,intent,agent_id,workspace_id,commit_hash,review_cycle,finding_ledger,prior_candidate_commit,delta_diff,delta_files,delta_ranges"
    end
  end

  # ---------------------------------------------------------------------------
  # Deterministic terminal-path fixtures
  # ---------------------------------------------------------------------------

  describe "terminal path fixtures" do
    for {scenario, status, overrides, retain_mode, remove_mode} <- [
          # no_changes / declined always discard (branch retirement when eligible);
          # retain_workspace only gates successful candidate outcomes.
          {:no_changes, "no_changes", %{}, "discard", "discard"},
          {:narrative_no_changes, "no_changes", %{}, "discard", "discard"},
          {:validation_failed, "validation_failed", %{}, "retain", "retain"},
          {:review_requires_rework, "rework_exhausted", %{}, "retain", "retain"},
          {:commit_approval_denied, "approval_denied", %{}, "retain", "retain"},
          {:review_rejected, "review_rejected", %{}, "retain", "retain"},
          {:review_failed, "review_failed", %{}, "retain", "retain"},
          {:pr_failed, "pr_failed", %{"open_pr" => "true"}, "retain", "retain"},
          {:implement_hard_fail, "pipeline_error", %{}, "retain", "retain"},
          {:worker_open_failed, "pipeline_error", %{}, "retain", "retain"},
          {:change_committed, "change_committed", %{}, "publish_retain", "publish"},
          {:narrative_changed, "change_committed", %{}, "publish_retain", "publish"},
          {:pr_created, "pr_created", %{"open_pr" => "true"}, "publish_retain", "publish"},
          {:human_review_required, "human_review_required", %{}, "publish_retain", "publish"}
        ] do
      test "#{scenario} release mode follows retain_workspace" do
        for {retain_workspace, expected_mode} <- [
              {"true", unquote(retain_mode)},
              {"false", unquote(remove_mode)}
            ] do
          initial =
            Map.put(unquote(Macro.escape(overrides)), "retain_workspace", retain_workspace)

          assert {{:ok, result}, calls} = run_fixture(unquote(scenario), initial)
          assert result.context["status"] == unquote(status)
          assert_release_mode(calls, expected_mode)
        end
      end
    end

    test "unknown terminal status retains instead of dead-ending before release" do
      unknown_status_dot =
        String.replace(
          load_dot(),
          ~s(expression="change_committed"),
          ~s(expression="unknown_terminal"),
          global: false
        )

      assert {{:ok, result}, calls} = run_fixture(:change_committed, %{}, unknown_status_dot)
      assert result.context["status"] == "unknown_terminal"
      assert "route_release_mode" in result.completed_nodes
      assert "prep_release_mode_retain" in result.completed_nodes
      assert_release_mode(calls, "retain")
    end

    test "malformed retain_workspace publishes and retains instead of dead-ending" do
      assert {{:ok, result}, calls} =
               run_fixture(:change_committed, %{"retain_workspace" => "malformed"})

      assert result.context["status"] == "change_committed"
      assert "route_success_workspace_retention" in result.completed_nodes
      assert "prep_release_mode_publish_retain" in result.completed_nodes
      assert "publish_workspace" in result.completed_nodes
      assert_release_mode(calls, "publish_retain")
    end

    test "narrative worker text with unchanged workspace returns no_changes" do
      assert {{:ok, result}, calls} = run_fixture(:narrative_no_changes)
      assert result.context["status"] == "no_changes"
      assert result.context["protocol_retry_count"] == "0"
      assert called?(calls, "coding_workspace_inspect")
      assert_single_worker_session(calls, 1)
      assert_closed_and_released(calls)
      assert_json_clean_context(result.context)
      assert_opaque_handles(result.context)
      refute called?(calls, "mix_compile")
      refute called?(calls, "coding_reviewed_commit")
      refute called_with_prompt?(calls, "ONLY one JSON object")
      refute called_with_prompt?(calls, "ONLY a JSON object")
    end

    test "no_changes when HEAD equals base and clean" do
      assert {{:ok, result}, calls} = run_fixture(:no_changes)
      assert result.context["status"] == "no_changes"
      assert result.context["protocol_retry_count"] == "0"
      assert called?(calls, "coding_workspace_inspect")
      assert_closed_and_released(calls)
      assert_json_clean_context(result.context)
      refute called?(calls, "mix_compile")
      refute called?(calls, "coding_reviewed_commit")
    end

    test "max_tokens stop_reason is pipeline_error with retain and worker close" do
      assert {{:ok, result}, calls} = run_fixture(:max_tokens_stop)
      assert result.context["status"] == "pipeline_error"
      assert result.context["error"] == "worker_stop_reason_not_end_turn"
      assert "error_worker_stop_reason_not_end_turn" in result.completed_nodes
      assert "close_worker" in result.completed_nodes
      assert_release_mode(calls, "retain")
      refute called?(calls, "mix_compile")
      refute called?(calls, "coding_reviewed_commit")
      assert_closed_and_released(calls)
    end

    test "missing stop_reason is pipeline_error with retain and worker close" do
      assert {{:ok, result}, calls} = run_fixture(:missing_stop_reason)
      assert result.context["status"] == "pipeline_error"
      assert result.context["error"] == "worker_stop_reason_not_end_turn"
      assert "close_worker" in result.completed_nodes
      assert_release_mode(calls, "retain")
      refute called?(calls, "mix_compile")
      assert_closed_and_released(calls)
    end

    test "missing workspace after end_turn is pipeline_error, not no_changes" do
      assert {{:ok, result}, calls} = run_fixture(:missing_workspace)
      assert result.context["status"] == "pipeline_error"
      assert result.context["error"] == "workspace_missing"
      assert "error_workspace_missing" in result.completed_nodes
      refute result.context["status"] == "no_changes"
      assert_release_mode(calls, "retain")
      refute called?(calls, "mix_compile")
      assert_closed_and_released(calls)
    end

    test "missing workspace before a worker send is pipeline_error and never dispatches the turn" do
      assert {{:ok, result}, calls} = run_fixture(:missing_workspace_before_send)
      assert result.context["status"] == "pipeline_error"
      assert result.context["error"] == "workspace_missing"
      assert "check_pre_turn_workspace_exists" in result.completed_nodes
      assert "error_workspace_missing" in result.completed_nodes
      refute called?(calls, "acp_send_message")
      refute called?(calls, "mix_compile")
      assert_release_mode(calls, "retain")
      assert_closed_and_released(calls)
    end

    test "rework no-op after candidate is pipeline_error and does not re-present prior work" do
      assert {{:ok, result}, calls} = run_fixture(:rework_no_progress)
      assert result.context["status"] == "pipeline_error"
      assert result.context["error"] == "worker_turn_no_progress"
      assert result.context["total_rework_count"] == 1
      assert "error_worker_turn_no_progress" in result.completed_nodes
      assert_release_mode(calls, "retain")
      # First turn validates once; rework no-op never re-validates or commits.
      assert Enum.count(calls, fn {name, _} -> name == "mix_compile" end) == 1
      refute called?(calls, "coding_reviewed_commit")
      assert_single_worker_session(calls, 2)
      assert_closed_and_released(calls)
    end

    test "rework progress continues validation and does not use worker prose control" do
      assert {{:ok, result}, calls} = run_fixture(:rework_with_progress)
      assert result.context["status"] == "change_committed"
      assert result.context["total_rework_count"] == 1
      assert result.context["validation_rework_count"] == 1
      refute Map.has_key?(result.context, "error")
      assert Enum.count(calls, fn {name, _} -> name == "mix_compile" end) == 2
      assert called?(calls, "coding_reviewed_commit")
      assert_single_worker_session(calls, 2)
      assert_closed_and_released(calls)
    end

    test "steering prompts request old-graph-compatible terminal JSON while remaining advisory" do
      assert {{:ok, result}, calls} = run_fixture(:change_committed)
      assert result.context["status"] == "change_committed"
      prompts = action_prompts(calls)
      assert Enum.at(prompts, 0) =~ "ONLY one valid JSON object and no prose or Markdown"
      assert Enum.at(prompts, 0) =~ ~s({\"status\":\"implemented\",\"summary\":\"what changed\"})

      assert Enum.at(prompts, 0) =~
               ~s({\"status\":\"declined\",\"summary\":\"why no change was made\"})

      assert Enum.at(prompts, 0) =~ "advisory only"
      refute Enum.at(prompts, 0) =~ "ONLY one JSON object"
      refute called_with_prompt?(calls, "ONLY a JSON object")
    end

    test "repeated validation failure exhausts only the validation retry" do
      assert {{:ok, result}, calls} = run_fixture(:validation_failed)
      assert result.context["status"] == "validation_failed"
      assert result.context["validation_rework_count"] == 1
      assert result.context["review_rework_count"] == "0"
      assert result.context["total_rework_count"] == 1
      assert result.context["rework_kind"] == "validation"
      assert result.context["rework_iteration"] == 1
      assert_closed_and_released(calls)

      validate_calls = Enum.count(calls, fn {n, _} -> n == "mix_compile" end)
      assert validate_calls == 2

      prompts = action_prompts(calls)
      assert_single_worker_session(calls, 2)
      assert Enum.at(prompts, 1) =~ "Structured validation feedback JSON"
      assert Enum.at(prompts, 1) =~ "bounded compile feedback"
      refute Enum.at(prompts, 1) =~ "RAW_VALIDATION_STDOUT_SENTINEL"
      refute Enum.at(prompts, 1) =~ "RAW_VALIDATION_STDERR_SENTINEL"
      assert Enum.at(prompts, 1) =~ "ONLY one valid JSON object and no prose or Markdown"
      refute Enum.at(prompts, 1) =~ "ONLY one JSON object"
      refute called?(calls, "coding_reviewed_commit")
    end

    test "repeated council rework exhausts only the review retry" do
      assert {{:ok, result}, calls} = run_fixture(:review_requires_rework)
      assert result.context["status"] == "rework_exhausted"
      assert result.context["legacy_status"] == "review_requires_rework"
      assert result.context["validation_rework_count"] == "0"
      assert result.context["review_rework_count"] == 2
      assert result.context["total_rework_count"] == 2
      assert result.context["rework_kind"] == "review"
      assert result.context["rework_iteration"] == 2
      assert result.context["review_cycle"] == 3
      assert_closed_and_released(calls)

      assert Enum.count(calls, fn {name, _args} -> name == "council_review_change" end) == 3
      prompts = action_prompts(calls)
      assert_single_worker_session(calls, 3)
      assert Enum.at(prompts, 1) =~ "Structured review feedback JSON"
      assert Enum.at(prompts, 1) =~ "bounded council feedback"
      assert Enum.at(prompts, 1) =~ "ONLY one valid JSON object and no prose or Markdown"
      refute Enum.at(prompts, 1) =~ "ONLY one JSON object"
    end

    test "cycle one reaches the real request boundary as an integer with empty delta evidence" do
      assert {{:ok, result}, calls} = run_fixture(:change_committed)
      assert result.context["status"] == "change_committed"

      assert [{"council_review_change", review_args}] =
               Enum.filter(calls, fn {name, _args} -> name == "council_review_change" end)

      assert review_args["review_cycle"] == 1
      assert review_args["finding_ledger"] == %{}
      assert review_args["delta_diff"] == ""
      assert review_args["delta_files"] == []
      assert review_args["delta_ranges"] == %{}
      refute Map.has_key?(review_args, "prior_candidate_commit")

      assert {:ok, request} = Arbor.Actions.Council.build_code_review_request(review_args)
      assert request.review_cycle == 1

      assert [{"coding_workspace_committed_change", material_args}] =
               Enum.filter(calls, fn {name, _args} ->
                 name == "coding_workspace_committed_change"
               end)

      refute Map.has_key?(material_args, "prior_commit")
    end

    test "cycle two carries the prior commit, scoped delta, and completed ledger" do
      assert {{:ok, result}, calls} = run_fixture(:resolved_finding_accepted)
      assert result.context["status"] == "change_committed"
      assert result.context["review_cycle"] == 2
      assert result.context["review_disposition"] == "accept"

      [first_material, second_material] =
        calls
        |> Enum.filter(fn {name, _args} -> name == "coding_workspace_committed_change" end)
        |> Enum.map(&elem(&1, 1))

      refute Map.has_key?(first_material, "prior_commit")
      assert second_material["prior_commit"] == "commit-review-1"
      assert second_material["commit"] == "commit-review-2"

      [first_review, second_review] =
        calls
        |> Enum.filter(fn {name, _args} -> name == "council_review_change" end)
        |> Enum.map(&elem(&1, 1))

      assert first_review["review_cycle"] == 1
      assert second_review["review_cycle"] == 2
      assert second_review["prior_candidate_commit"] == "commit-review-1"
      assert second_review["finding_ledger"]["review_cycle"] == 1
      assert second_review["delta_diff"] =~ "cycle delta"
      assert second_review["delta_files"] == ["file.ex"]
      assert second_review["delta_ranges"] == %{"file.ex" => [[1, 3]]}

      assert Enum.all?(result.context["finding_ledger"]["findings"], fn {_id, finding} ->
               finding["state"] == "fixed"
             end)
    end

    test "new in-delta blocker reworks and is resolved on cycle three" do
      assert {{:ok, result}, calls} = run_fixture(:in_delta_blocker_reworks)
      assert result.context["status"] == "change_committed"
      assert result.context["review_cycle"] == 3
      assert result.context["review_rework_count"] == 2
      assert Enum.count(calls, fn {name, _args} -> name == "council_review_change" end) == 3

      cycle_two =
        calls
        |> Enum.filter(fn {name, _args} -> name == "council_review_change" end)
        |> Enum.at(1)
        |> elem(1)

      assert cycle_two["delta_ranges"] == %{"file.ex" => [[1, 3]]}
      assert result.context["review_disposition"] == "accept"

      assert Enum.all?(result.context["finding_ledger"]["findings"], fn {_id, finding} ->
               finding["state"] == "fixed"
             end)
    end

    test "outside-delta finding is retained as a non-blocking side channel" do
      assert {{:ok, result}, calls} = run_fixture(:outside_delta_side_channel)
      assert result.context["status"] == "change_committed"
      assert result.context["review_cycle"] == 2
      assert result.context["review_disposition"] == "accept"
      assert Enum.count(calls, fn {name, _args} -> name == "council_review_change" end) == 2

      assert [%{"reason" => "outside_delta", "title" => "outside-delta side channel"}] =
               Enum.map(
                 result.context["finding_ledger"]["out_of_scope"],
                 &Map.take(&1, ["reason", "title"])
               )
    end

    test "two council reworks reach cycle three before category exhaustion" do
      assert {{:ok, result}, calls} = run_fixture(:two_review_reworks_exhaust)
      assert result.context["status"] == "rework_exhausted"
      assert result.context["review_cycle"] == 3
      assert result.context["review_rework_count"] == 2
      assert result.context["total_rework_count"] == 2
      assert Enum.count(calls, fn {name, _args} -> name == "council_review_change" end) == 3
      assert_single_worker_session(calls, 3)
    end

    test "validation retry then successful council retry reuse one worker session" do
      assert {{:ok, result}, calls} = run_fixture(:validation_then_review_rework_success)
      assert result.context["status"] == "change_committed"
      assert result.context["validation_rework_count"] == 1
      assert result.context["review_rework_count"] == 1
      assert result.context["total_rework_count"] == 2
      assert result.context["rework_kind"] == "review"
      assert result.context["rework_iteration"] == 2

      prompts = action_prompts(calls)
      assert_single_worker_session(calls, 3)
      assert Enum.at(prompts, 1) =~ "Structured validation feedback JSON"
      assert Enum.at(prompts, 1) =~ "bounded compile feedback"
      refute Enum.at(prompts, 1) =~ "RAW_VALIDATION_STDOUT_SENTINEL"
      refute Enum.at(prompts, 1) =~ "RAW_VALIDATION_STDERR_SENTINEL"
      assert Enum.at(prompts, 2) =~ "Structured review feedback JSON"
      assert Enum.at(prompts, 2) =~ "bounded council feedback"

      assert Enum.all?(
               prompts,
               &String.contains?(&1, "ONLY one valid JSON object and no prose or Markdown")
             )

      refute Enum.any?(prompts, &String.contains?(&1, "ONLY one JSON"))
      refute "error_review_tier_invalid" in result.completed_nodes
      assert_closed_and_released(calls)
    end

    test "hard total remains two when validation and repeated review exhaust" do
      assert {{:ok, result}, calls} = run_fixture(:rework_exhausted)
      assert result.context["status"] == "rework_exhausted"
      assert result.context["legacy_status"] == "review_requires_rework"
      assert result.context["validation_rework_count"] == 1
      assert result.context["review_rework_count"] == 1
      assert result.context["total_rework_count"] == 2
      assert result.context["rework_kind"] == "review"
      assert result.context["rework_iteration"] == 2
      assert_single_worker_session(calls, 3)
      assert_closed_and_released(calls)
    end

    test "operator denial of commit produces approval_denied with cleanup" do
      assert {{:ok, result}, calls} = run_fixture(:commit_approval_denied)
      assert result.context["status"] == "approval_denied"
      assert result.context["error"] == "approval_denied"
      assert result.context["approval_request_id"] == "irq_commit_denied_1"
      assert result.context["approval_note"] == "operator denied this commit"
      refute result.context["status"] == "pipeline_error"
      refute "status_pipeline_error_then_close" in result.completed_nodes
      refute called?(calls, "council_review_change")
      assert Enum.count(calls, fn {n, _} -> n == "coding_reviewed_commit" end) == 1
      assert_single_worker_session(calls, 1)
      assert_closed_and_released(calls)
      assert_json_clean_context(result.context)
    end

    test "operator rework uses one worker, second implement, shared budget, then fresh commit" do
      assert {{:ok, result}, calls} = run_fixture(:commit_approval_rework_success)
      assert result.context["status"] == "change_committed"
      assert result.context["operator_rework_count"] == 1
      assert result.context["validation_rework_count"] == "0"
      assert result.context["review_rework_count"] == "0"
      assert result.context["total_rework_count"] == 1
      assert result.context["rework_kind"] == "operator_approval"
      assert result.context["rework_iteration"] == 1
      assert result.context["commit_hash"] == "commitrework456"

      prompts = action_prompts(calls)
      # First implement + operator rework implement (no protocol repair)
      assert_single_worker_session(calls, 2)
      assert Enum.at(prompts, 1) =~ "Operator requested rework"
      assert Enum.at(prompts, 1) =~ "please fix the public API name"
      assert Enum.at(prompts, 1) =~ "ONLY one valid JSON object and no prose or Markdown"
      refute Enum.at(prompts, 1) =~ "ONLY one JSON object"

      commit_calls = Enum.filter(calls, fn {n, _} -> n == "coding_reviewed_commit" end)
      assert length(commit_calls) == 2

      validate_calls = Enum.count(calls, fn {n, _} -> n == "mix_compile" end)
      assert validate_calls == 2

      # Council review only after the successful fresh commit, never on the
      # rejected interaction control outcome.
      assert Enum.count(calls, fn {n, _} -> n == "council_review_change" end) == 1
      refute "status_pipeline_error_then_close" in result.completed_nodes
      assert_closed_and_released(calls)
      assert_json_clean_context(result.context)
    end

    test "exhausted operator rework terminates deterministically" do
      assert {{:ok, result}, calls} = run_fixture(:commit_approval_rework_exhausted)
      assert result.context["status"] == "rework_exhausted"
      assert result.context["legacy_status"] == "operator_approval_rework"
      assert result.context["error"] == "operator_approval_rework_exhausted"
      assert result.context["operator_rework_count"] == 1
      assert result.context["total_rework_count"] == 1
      assert result.context["rework_kind"] == "operator_approval"
      assert result.context["approval_request_id"] == "irq_commit_rework_exhausted_2"
      # Two implement turns (initial + one operator rework), two commit attempts
      # (first rework control, second rework control that exhausts category).
      assert_single_worker_session(calls, 2)
      assert Enum.count(calls, fn {n, _} -> n == "coding_reviewed_commit" end) == 2
      refute called?(calls, "council_review_change")
      assert_closed_and_released(calls)
      assert_json_clean_context(result.context)
    end

    test "validation rework then operator rework hits shared total budget" do
      assert {{:ok, result}, calls} = run_fixture(:validation_then_operator_rework_exhausted)
      assert result.context["status"] == "rework_exhausted"
      assert result.context["error"] == "operator_approval_rework_exhausted"
      assert result.context["legacy_status"] == "operator_approval_rework"
      assert result.context["validation_rework_count"] == 1
      assert result.context["operator_rework_count"] == 1
      assert result.context["total_rework_count"] == 2
      assert result.context["rework_kind"] == "operator_approval"
      # implement, validation rework implement, operator rework implement
      assert_single_worker_session(calls, 3)
      assert_closed_and_released(calls)
    end

    test "review_rejected" do
      assert {{:ok, result}, calls} = run_fixture(:review_rejected)
      assert result.context["status"] == "review_rejected"
      assert_closed_and_released(calls)
      refute called?(calls, "git_pr")
    end

    test "review_failed on council error" do
      assert {{:ok, result}, calls} = run_fixture(:review_failed)
      assert result.context["status"] == "review_failed"
      assert result.context["error"] == "council_review_failed"
      assert_closed_and_released(calls)
      assert_json_clean_context(result.context)
    end

    for scenario <- [:unknown_review_tier, :missing_review_tier] do
      test "#{scenario} fails closed as review_failed and cleans up" do
        assert {{:ok, result}, calls} = run_fixture(unquote(scenario))
        assert result.context["status"] == "review_failed"
        assert result.context["error"] == "review_tier_invalid_or_missing"
        assert "error_review_tier_invalid" in result.completed_nodes
        refute called?(calls, "git_pr")
        assert_single_worker_session(calls, 1)
        assert_closed_and_released(calls)
        assert_json_clean_context(result.context)
      end
    end

    test "malformed completed review cycle fails closed as review_failed" do
      assert {{:ok, result}, calls} = run_fixture(:malformed_review_cycle)
      assert result.context["status"] == "review_failed"
      assert result.context["error"] == "review_cycle_invalid_or_missing"
      assert "error_review_cycle_invalid" in result.completed_nodes
      refute called?(calls, "git_pr")
      assert_closed_and_released(calls)
    end

    test "human_review_required without PR" do
      assert {{:ok, result}, calls} = run_fixture(:human_review_required)
      assert result.context["status"] == "human_review_required"
      assert_closed_and_released(calls)
      refute called?(calls, "git_pr")
    end

    test "pr_failed" do
      assert {{:ok, result}, calls} = run_fixture(:pr_failed, %{"open_pr" => "true"})
      assert result.context["status"] == "pr_failed"
      assert result.context["error"] == "draft_pr_failed"
      assert_closed_and_released(calls)
      assert called?(calls, "git_pr")
      assert_json_clean_context(result.context)
    end

    test "pr_created" do
      assert {{:ok, result}, calls} = run_fixture(:pr_created, %{"open_pr" => "true"})
      assert result.context["status"] == "pr_created"
      assert_closed_and_released(calls)
      assert called?(calls, "git_pr")
    end

    test "change_committed without PR" do
      assert {{:ok, result}, calls} = run_fixture(:change_committed)
      assert result.context["status"] == "change_committed"
      assert_closed_and_released(calls)
      assert called?(calls, "coding_reviewed_commit")
      refute called?(calls, "git_pr")
      assert result.context["commit_hash"] == "commitabc123"
      assert result.context["worker_provider_session_id"] == "sess_1"

      assert {"acp_start_session", start_args} =
               Enum.find(calls, fn {name, _args} -> name == "acp_start_session" end)

      assert start_args["use_pool"] == "true"

      assert {"acp_close_session", close_args} =
               Enum.find(calls, fn {name, _args} -> name == "acp_close_session" end)

      assert close_args["return_to_pool"] == true

      assert {"coding_workspace_committed_change", materialize_args} =
               Enum.find(calls, fn {name, _args} ->
                 name == "coding_workspace_committed_change"
               end)

      assert materialize_args["commit"] == "commitabc123"
      refute "error_review_tier_invalid" in result.completed_nodes
      refute "inc_protocol_retry_count" in result.completed_nodes
      refute "repair_worker_protocol" in result.completed_nodes
      refute "extract_worker_status" in result.completed_nodes
      assert "inspect_workspace" in result.completed_nodes
      assert result.context["protocol_retry_count"] == "0"
      assert_json_clean_context(result.context)
      assert_opaque_handles(result.context)
    end

    test "security regression: task text is never interpolated into the git commit message" do
      hostile_task = "docs; rm -rf /tmp/example `touch /tmp/example`"

      assert {{:ok, result}, calls} =
               run_fixture(:change_committed, %{"task" => hostile_task})

      assert result.context["status"] == "change_committed"

      assert {"coding_reviewed_commit", commit_args} =
               Enum.find(calls, fn {name, _args} -> name == "coding_reviewed_commit" end)

      assert commit_args["message"] == "Coding agent change"
      assert commit_args["workspace_id"] == "ws_fixture_1"
      refute commit_args["message"] =~ hostile_task
      assert_closed_and_released(calls)
    end

    test "clean self-commit adopts HEAD and still goes through coding_reviewed_commit gate" do
      assert {{:ok, result}, calls} =
               run_fixture(:self_commit_adopt, %{"submit_review" => "false", "open_pr" => "false"})

      assert result.context["status"] == "change_committed"
      assert result.context["commit_hash"] == "selfcommit9999"
      assert called?(calls, "coding_reviewed_commit")
      assert_closed_and_released(calls)
    end

    test "fake-run contexts are JSON-clean with only opaque workspace/worker strings" do
      assert {{:ok, result}, _calls} = run_fixture(:change_committed)
      assert_json_clean_context(result.context)
      assert_opaque_handles(result.context)

      refute Enum.any?(result.context, fn {_k, v} ->
               is_pid(v) or is_function(v) or is_reference(v)
             end)
    end

    test "arbitrary narrative worker text plus changed workspace proceeds on first turn" do
      assert {{:ok, result}, calls} = run_fixture(:narrative_changed)
      assert result.context["status"] == "change_committed"
      assert result.context["protocol_retry_count"] == "0"
      assert result.context["validation_rework_count"] == "0"
      assert result.context["review_rework_count"] == "0"
      assert result.context["total_rework_count"] == "0"
      refute Map.has_key?(result.context, "error")
      refute result.context["error"] == "worker_protocol_invalid_json_after_retry"

      assert_single_worker_session(calls, 1)
      assert called?(calls, "coding_workspace_inspect")
      assert called?(calls, "mix_compile")
      refute called_with_prompt?(calls, "ONLY one JSON object")
      refute called_with_prompt?(calls, "not valid protocol JSON")
      refute "repair_worker_protocol" in result.completed_nodes
      refute "extract_worker_status" in result.completed_nodes
      assert "inspect_workspace" in result.completed_nodes
      assert_closed_and_released(calls)
      assert_json_clean_context(result.context)
    end

    test "narrative validation rework continues through owner-observed inspection" do
      assert {{:ok, result}, calls} = run_fixture(:narrative_validation_rework)

      assert result.context["status"] == "change_committed"
      assert result.context["protocol_retry_count"] == "0"
      assert result.context["validation_rework_count"] == 1
      assert result.context["review_rework_count"] == "0"
      assert result.context["total_rework_count"] == 1
      refute Map.has_key?(result.context, "error")

      prompts = action_prompts(calls)
      assert_single_worker_session(calls, 2)
      assert Enum.at(prompts, 1) =~ "Structured validation feedback JSON"
      assert Enum.at(prompts, 1) =~ "ONLY one valid JSON object and no prose or Markdown"
      refute Enum.at(prompts, 1) =~ "ONLY one JSON object"
      # Every turn performs pre-turn, post-turn, and fresh validation inspection.
      assert_validation_inspections(calls, 2)
      assert_closed_and_released(calls)
      assert_json_clean_context(result.context)
    end

    test "narrative review rework continues through owner-observed inspection" do
      assert {{:ok, result}, calls} = run_fixture(:narrative_review_rework)

      assert result.context["status"] == "change_committed"
      assert result.context["protocol_retry_count"] == "0"
      assert result.context["validation_rework_count"] == "0"
      assert result.context["review_rework_count"] == 1
      assert result.context["total_rework_count"] == 1
      refute Map.has_key?(result.context, "error")

      prompts = action_prompts(calls)
      assert_single_worker_session(calls, 2)
      assert Enum.at(prompts, 1) =~ "Structured review feedback JSON"
      assert Enum.at(prompts, 1) =~ "ONLY one valid JSON object and no prose or Markdown"
      refute Enum.at(prompts, 1) =~ "ONLY one JSON object"
      assert_validation_inspections(calls, 2)
      assert_closed_and_released(calls)
      assert_json_clean_context(result.context)
    end

    test "packaged graph has no protocol-repair path and cannot emit invalid-json terminal" do
      dot = load_dot()
      refute dot =~ "repair_worker_protocol"
      refute dot =~ "extract_worker_status"
      refute dot =~ "route_worker_status"
      refute dot =~ "worker_protocol_invalid_json_after_retry"
      refute dot =~ "build_protocol_repair_prompt"
      assert dot =~ "coding_workspace_inspect"
      assert dot =~ "output_key=\"protocol_retry_count\""
      assert dot =~ "acp_session_status"
      assert dot =~ "retry_recovered_send"
      assert dot =~ "worker_provider_session_id"
      assert dot =~ "param.failure_mode=\"delivery_receipt\""
    end

    test "initial open_worker FS_NOT_FOUND with fallback proceeds as fresh_recovery" do
      # Narrow DOT patch mirrors CodingPlan.Compiler rewrite for explicit resume:
      # static param.session_id + param.fallback_to_fresh_on_resume_unavailable=true.
      # Fake acp_start_session returns the StartSession post-fallback envelope
      # (real classify/retry is covered by arbor_actions StartSession tests).
      # Continuity is not an open_worker router key; load-bearing proof is that
      # open_worker succeeds (does not terminalize) and the replacement managed
      # handle + post-open continuity reach the implement path.
      dot = explicit_resume_open_worker_dot(fallback: true)

      assert {{:ok, result}, calls} =
               run_fixture(:initial_resume_fs_not_found_recovery, %{}, dot)

      assert result.context["status"] == "change_committed"
      # Managed handle + provider conversation from the fresh-recovery open.
      assert result.context["worker_session_id"] == "acp_worker_fixture_fresh"

      assert result.context["worker_provider_session_id"] ==
               "provider_sess_fresh_after_fs_not_found"

      continuity =
        result.context["worker.continuity"] ||
          get_in(result.context, ["worker", "continuity"])

      assert continuity == "fresh_recovery"

      starts = Enum.filter(calls, fn {name, _} -> name == "acp_start_session" end)
      assert length(starts) == 1
      {_name, start_args} = hd(starts)
      assert start_args["session_id"] == "provider-session-from-prior-task"
      assert start_args["fallback_to_fresh_on_resume_unavailable"] in [true, "true"]

      # Implement must run on the replacement worker — proof open_worker did not
      # terminalize and the replacement handle was hoisted.
      sends = Enum.filter(calls, fn {name, _} -> name == "acp_send_message" end)
      assert length(sends) >= 1

      assert Enum.at(sends, 0) |> elem(1) |> Map.fetch!("worker_session_id") ==
               "acp_worker_fixture_fresh"

      refute called?(calls, "coding_workspace_recovery_summary")
      assert_closed_and_released(calls)
      assert_json_clean_context(result.context)
    end

    test "initial open_worker FS_NOT_FOUND without fallback terminalizes at open_worker" do
      dot = explicit_resume_open_worker_dot(fallback: false)

      assert {{:ok, result}, calls} =
               run_fixture(:initial_resume_fs_not_found_no_fallback, %{}, dot)

      assert result.context["status"] == "pipeline_error"
      starts = Enum.filter(calls, fn {name, _} -> name == "acp_start_session" end)
      assert length(starts) == 1
      {_name, start_args} = hd(starts)
      assert start_args["session_id"] == "provider-session-from-prior-task"
      refute Map.get(start_args, "fallback_to_fresh_on_resume_unavailable") in [true, "true"]
      refute called?(calls, "acp_send_message")
      # open_worker failed before a managed handle existed; release still runs.
      assert called?(calls, "coding_workspace_release")
      refute called?(calls, "acp_close_session")
    end

    test "provider account exhaustion terminates without session recovery" do
      assert {{:ok, result}, calls} = run_fixture(:provider_account_exhausted)

      assert result.context["status"] == "pipeline_error"
      assert result.context["error"] == "worker_provider_account_exhausted"

      assert result.context["worker_failure_reason"] ==
               "ACP provider account credits exhausted or monthly spending limit reached (HTTP 403)"

      assert result.context["worker_send_recovery_count"] == "0"
      assert length(Enum.filter(calls, fn {name, _} -> name == "acp_send_message" end)) == 1
      assert length(Enum.filter(calls, fn {name, _} -> name == "acp_start_session" end)) == 1
      refute called?(calls, "acp_session_status")

      assert {"acp_send_message", send_args} =
               Enum.find(calls, fn {name, _args} -> name == "acp_send_message" end)

      assert send_args["failure_mode"] == "delivery_receipt"
      assert_closed_and_released(calls)
      assert_json_clean_context(result.context)
    end

    test "send failure resumes the current prompt once on a replacement worker" do
      assert {{:ok, result}, calls} = run_fixture(:recovery_resumed_success)
      assert result.context["status"] == "change_committed"
      assert result.context["worker_send_recovery_count"] == 1

      starts = Enum.filter(calls, fn {name, _args} -> name == "acp_start_session" end)
      sends = Enum.filter(calls, fn {name, _args} -> name == "acp_send_message" end)
      closes = Enum.filter(calls, fn {name, _args} -> name == "acp_close_session" end)

      assert length(starts) == 2
      assert length(sends) == 2
      assert length(closes) == 2

      assert Enum.at(sends, 0) |> elem(1) |> Map.fetch!("prompt") ==
               Enum.at(sends, 1) |> elem(1) |> Map.fetch!("prompt")

      assert Enum.at(starts, 1) |> elem(1) |> Map.fetch!("session_id") == "status_sess_1"
      assert Enum.at(closes, 0) |> elem(1) |> Map.fetch!("return_to_pool") == false
      assert result.context["worker_provider_session_id"] == "sess_2"
      assert_closed_and_released(calls)
    end

    test "uncertain transport send mutates then resumed recovery preserves the original baseline" do
      # Regression for uncertain ACP send recovery: the first send returns a
      # transport failure but the workspace already mutated (the send may have
      # executed). Recovery opens a replacement worker and retries the same
      # pending prompt; the recovered send succeeds without further mutation.
      # Post-turn inspection must compare against the ORIGINAL pre-turn
      # baseline, observe progress from the uncertain send, and route to
      # validation/commit — never no_changes. Invariant is asserted
      # deterministically without depending on any specific provider's
      # transport-failure semantics.
      assert {{:ok, result}, calls} = run_fixture(:uncertain_send_recovery)

      assert result.context["status"] == "change_committed"
      refute result.context["status"] == "no_changes"
      assert result.context["worker_send_recovery_count"] == 1

      starts = Enum.filter(calls, fn {name, _args} -> name == "acp_start_session" end)
      sends = Enum.filter(calls, fn {name, _args} -> name == "acp_send_message" end)
      closes = Enum.filter(calls, fn {name, _args} -> name == "acp_close_session" end)

      # One bounded recovery: exactly two sends, two opens, two closes.
      assert length(starts) == 2
      assert length(sends) == 2
      assert length(closes) == 2

      # Resumed continuity retries the same pending prompt (byte-equal).
      first_prompt = Enum.at(sends, 0) |> elem(1) |> Map.fetch!("prompt")
      recovered_prompt = Enum.at(sends, 1) |> elem(1) |> Map.fetch!("prompt")
      assert first_prompt == recovered_prompt

      # The original logical-turn baseline (captured before the uncertain send)
      # is preserved through recovery and is the value the post-turn owner
      # inspection received. A regression that re-captured the baseline
      # mid-recovery would overwrite this with the mutated fingerprint and the
      # post-turn comparison would observe no progress → no_changes.
      assert result.context["baseline_fingerprint"] == "fp-clean"

      [post_turn_inspect_args] =
        calls
        |> Enum.filter(fn {name, args} ->
          name == "coding_workspace_inspect" and
            Map.has_key?(args, "baseline_fingerprint")
        end)
        |> Enum.map(&elem(&1, 1))

      assert post_turn_inspect_args["baseline_fingerprint"] == "fp-clean"

      # Explicit mutation timing: exactly one mutation (from the uncertain
      # send). The recovered send performed no additional mutation — the
      # recovery-time pre-turn capture and the post-turn inspect observe the
      # same mutated fingerprint.
      assert result.context["pre_turn.fingerprint"] == "fp-uncertain-mutated-1"
      assert result.context["inspect.fingerprint"] == "fp-uncertain-mutated-1"

      assert result.context["worker_provider_session_id"] == "sess_2"
      assert_closed_and_released(calls)
      assert_json_clean_context(result.context)
    end

    test "fresh recovery summarizes the workspace and replaces the pending prompt" do
      assert {{:ok, result}, calls} = run_fixture(:recovery_fresh_success)
      assert result.context["status"] == "change_committed"
      assert result.context["worker_send_recovery_count"] == 1

      sends = Enum.filter(calls, fn {name, _args} -> name == "acp_send_message" end)
      assert length(sends) == 2
      original_prompt = Enum.at(sends, 0) |> elem(1) |> Map.fetch!("prompt")
      recovered_prompt = Enum.at(sends, 1) |> elem(1) |> Map.fetch!("prompt")
      assert recovered_prompt == "RECOVERY SUMMARY\n" <> original_prompt
      refute recovered_prompt == original_prompt

      assert {"coding_workspace_recovery_summary", summary_args} =
               Enum.find(calls, fn {name, _args} ->
                 name == "coding_workspace_recovery_summary"
               end)

      assert summary_args["workspace_id"] == "ws_fixture_1"
      assert summary_args["task"] == "fixture task for recovery_fresh_success"
      assert summary_args["pending_prompt"] == original_prompt
      assert_closed_and_released(calls)
    end

    test "successful status with an empty session id preserves the captured provider id" do
      assert {{:ok, result}, calls} = run_fixture(:recovery_status_empty_preserves_id)
      assert result.context["status"] == "change_committed"

      assert {"acp_start_session", replacement_args} =
               calls
               |> Enum.filter(fn {name, _args} -> name == "acp_start_session" end)
               |> List.last()

      assert replacement_args["session_id"] == "sess_1"
      refute called?(calls, "coding_workspace_recovery_summary")
      assert_closed_and_released(calls)
    end

    for scenario <- [:recovery_status_failure_with_id, :recovery_status_empty_no_id] do
      test "#{scenario} applies the provider-id gate before reopening" do
        assert {{:ok, result}, calls} = run_fixture(unquote(scenario))

        assert result.context["status"] == "change_committed" or
                 result.context["status"] == "pipeline_error"

        starts = Enum.filter(calls, fn {name, _args} -> name == "acp_start_session" end)

        if unquote(scenario) == :recovery_status_failure_with_id do
          assert length(starts) == 2
          assert Enum.at(starts, 1) |> elem(1) |> Map.fetch!("session_id") == "sess_1"
        else
          assert length(starts) == 1
          assert result.context["error"] == "worker_provider_session_id_missing"
        end

        assert_closed_and_released(calls)
      end
    end

    test "status failure without a captured provider id fails terminally" do
      assert {{:ok, result}, calls} = run_fixture(:recovery_status_failed_without_id)
      assert result.context["status"] == "pipeline_error"
      assert result.context["error"] == "worker_provider_session_id_missing"
      assert length(Enum.filter(calls, fn {name, _} -> name == "acp_start_session" end)) == 1
      assert_closed_and_released(calls)
    end

    test "stale close failure is terminal and still closes/releases the worker" do
      assert {{:ok, result}, calls} = run_fixture(:recovery_close_failed)
      assert result.context["status"] == "pipeline_error"
      assert result.context["error"] == "worker_stale_close_failed"
      assert length(Enum.filter(calls, fn {name, _} -> name == "acp_start_session" end)) == 1
      assert_closed_and_released(calls)
    end

    test "replacement open failure is terminal without a duplicate live worker" do
      assert {{:ok, result}, calls} = run_fixture(:recovery_reopen_failed)
      assert result.context["status"] == "pipeline_error"
      assert result.context["error"] == "worker_recovery_reopen_failed"
      assert length(Enum.filter(calls, fn {name, _} -> name == "acp_start_session" end)) == 2
      assert length(Enum.filter(calls, fn {name, _} -> name == "acp_send_message" end)) == 1
      assert_closed_and_released(calls)
    end

    test "recovered send failure does not trigger a second recovery attempt" do
      assert {{:ok, result}, calls} = run_fixture(:recovery_second_send_failed)
      assert result.context["status"] == "pipeline_error"
      assert result.context["error"] == "worker_recovery_send_failed"
      assert result.context["worker_send_recovery_count"] == 1
      assert length(Enum.filter(calls, fn {name, _} -> name == "acp_send_message" end)) == 2
      assert length(Enum.filter(calls, fn {name, _} -> name == "acp_session_status" end)) == 1
      assert length(Enum.filter(calls, fn {name, _} -> name == "acp_start_session" end)) == 2
      assert_closed_and_released(calls)
    end

    test "provider account exhaustion after recovery terminates without another recovery" do
      assert {{:ok, result}, calls} = run_fixture(:recovery_provider_account_exhausted)
      assert result.context["status"] == "pipeline_error"
      assert result.context["error"] == "worker_provider_account_exhausted"
      assert result.context["worker_send_recovery_count"] == 1
      assert length(Enum.filter(calls, fn {name, _} -> name == "acp_send_message" end)) == 2
      assert length(Enum.filter(calls, fn {name, _} -> name == "acp_session_status" end)) == 1
      assert length(Enum.filter(calls, fn {name, _} -> name == "acp_start_session" end)) == 2
      assert_closed_and_released(calls)
    end

    for scenario <- [:recovery_continuity_new, :recovery_continuity_unknown] do
      test "#{scenario} fails closed without retrying the prompt" do
        assert {{:ok, result}, calls} = run_fixture(unquote(scenario))
        assert result.context["status"] == "pipeline_error"
        assert result.context["error"] == "worker_recovery_continuity_invalid"
        assert length(Enum.filter(calls, fn {name, _} -> name == "acp_send_message" end)) == 1
        assert length(Enum.filter(calls, fn {name, _} -> name == "acp_start_session" end)) == 2
        assert_closed_and_released(calls)
      end
    end
  end

  describe "hard-failure routing and cleanup" do
    test "acquire failure is pipeline_error without workspace release" do
      assert {{:ok, result}, calls} = run_fixture(:acquire_failed)
      assert result.context["status"] == "pipeline_error"
      refute called?(calls, "coding_workspace_release")
      refute called?(calls, "acp_close_session")
    end

    test "worker open failure releases workspace only" do
      assert {{:ok, result}, calls} = run_fixture(:worker_open_failed)
      assert result.context["status"] == "pipeline_error"
      assert_released(calls)
      refute called?(calls, "acp_close_session")
      refute called?(calls, "acp_send_message")
    end

    test "implement hard failure sets pipeline_error and cleans up" do
      assert {{:ok, result}, calls} = run_fixture(:implement_hard_fail)
      assert result.context["status"] == "pipeline_error"
      assert_closed_and_released(calls)
    end

    test "workspace inspect hard failure sets pipeline_error and cleans up" do
      assert {{:ok, result}, calls} = run_fixture(:inspect_hard_fail)
      assert result.context["status"] == "pipeline_error"
      assert_closed_and_released(calls)
    end

    test "validation hard failure sets validation_failed and cleans up" do
      assert {{:ok, result}, calls} = run_fixture(:validation_hard_fail)
      assert result.context["status"] == "validation_failed"
      assert_closed_and_released(calls)
      # Validation fails before the commit gate.
      refute called?(calls, "coding_reviewed_commit")
    end

    test "commit hard failure sets pipeline_error and cleans up" do
      assert {{:ok, result}, calls} = run_fixture(:commit_hard_fail)
      assert result.context["status"] == "pipeline_error"
      assert_closed_and_released(calls)
    end

    test "committed review-material failure sets review_failed and cleans up" do
      assert {{:ok, result}, calls} = run_fixture(:committed_change_failed)
      assert result.context["status"] == "review_failed"
      assert result.context["error"] == "committed_change_materialization_failed"
      assert_closed_and_released(calls)
      refute called?(calls, "council_review_change")
      assert_json_clean_context(result.context)
    end

    test "close failure still releases workspace" do
      assert {{:ok, result}, calls} = run_fixture(:close_failed)
      assert result.context["status"] == "change_committed"
      assert called?(calls, "acp_close_session")
      assert_released(calls)
    end
  end
end
