defmodule Arbor.Voice.CodingPlanFactory do
  @moduledoc false

  # Pure policy-owned Coding Plan v2 factory (VP-05C).
  # Spoken/model input controls only the bounded task intent. All authority-
  # bearing fields are source-owned constants. Never calls compiler, FS, Git,
  # provider, Security, Agent, or Orchestration.

  alias Arbor.Contracts.Coding.{Plan, WorkPacket}

  # Source-owned admitted task-intent ceiling (shared by FrontDesk, Session
  # ManagedDispatchCore, and TranscriptRecorder).
  @max_intent_bytes 2048
  # Source-owned bound for trusted repo roots (absolute path strings).
  @max_repo_root_bytes 4096
  @worker_provider "grok"
  @control_chars ~r/[\x00-\x1F\x7F]/

  @non_goals [
    "Multi-task scope expansion beyond one reviewable increment",
    "Automatic merge or adoption of the candidate change",
    "Speech-selected repository, provider, model, profile, path, or principal"
  ]

  @constraints [
    "Authority comes only from the managed executor and owner-scoped dispatch capability",
    "Only work inside the configured coding repository allowlist is allowed",
    "Speech and model output cannot select execution authority or policy"
  ]

  @required_evidence [
    "Validation results remain authoritative for acceptance",
    "Binding review remains authoritative for release readiness"
  ]

  @type error_reason :: :invalid_intent | :invalid_repo_root | :invalid_plan

  @doc false
  @spec build(String.t(), String.t()) ::
          {:ok, %{required(String.t()) => term()}} | {:error, error_reason()}
  def build(task_intent, repo_root) do
    with {:ok, intent} <- admit_intent(task_intent),
         {:ok, root} <- admit_repo_root(repo_root),
         {:ok, packet} <- build_work_packet(intent),
         {:ok, digest} <- WorkPacket.digest(packet),
         {:ok, plan} <- build_plan(intent, root, packet, digest) do
      {:ok, %{"kind" => "coding_change", "plan" => Plan.to_map(plan)}}
    else
      {:error, :invalid_intent} = error -> error
      {:error, :invalid_repo_root} = error -> error
      {:error, _} -> {:error, :invalid_plan}
      _ -> {:error, :invalid_plan}
    end
  rescue
    _ -> {:error, :invalid_plan}
  catch
    _, _ -> {:error, :invalid_plan}
  end

  @doc false
  @spec max_intent_bytes() :: pos_integer()
  def max_intent_bytes, do: @max_intent_bytes

  @doc """
  Pure source-owned task-intent admission used by CodingPlanFactory,
  ManagedDispatchCore, FrontDesk, and TranscriptRecorder.

  Rejects non-binaries, non-UTF-8, blank, oversized, and control-bearing text
  (`\\x00-\\x1F` and `\\x7F`). Does not parse intent into authority fields.
  """
  @spec admit_intent(term()) :: {:ok, String.t()} | {:error, :invalid_intent}
  def admit_intent(intent) when is_binary(intent) do
    cond do
      not String.valid?(intent) ->
        {:error, :invalid_intent}

      byte_size(intent) > @max_intent_bytes ->
        {:error, :invalid_intent}

      String.trim(intent) == "" ->
        {:error, :invalid_intent}

      String.match?(intent, @control_chars) ->
        {:error, :invalid_intent}

      true ->
        {:ok, intent}
    end
  end

  def admit_intent(_), do: {:error, :invalid_intent}

  defp admit_repo_root(root) when is_binary(root) do
    cond do
      not String.valid?(root) ->
        {:error, :invalid_repo_root}

      byte_size(root) > @max_repo_root_bytes ->
        {:error, :invalid_repo_root}

      String.trim(root) == "" ->
        {:error, :invalid_repo_root}

      String.match?(root, @control_chars) ->
        {:error, :invalid_repo_root}

      Path.type(root) != :absolute ->
        {:error, :invalid_repo_root}

      true ->
        {:ok, root}
    end
  end

  defp admit_repo_root(_), do: {:error, :invalid_repo_root}

  @doc false
  @spec max_repo_root_bytes() :: pos_integer()
  def max_repo_root_bytes, do: @max_repo_root_bytes

  @doc false
  @spec worker_provider() :: String.t()
  def worker_provider, do: @worker_provider

  defp build_work_packet(intent) do
    WorkPacket.new(%{
      version: 1,
      success_criteria: [intent],
      non_goals: @non_goals,
      constraints: @constraints,
      architecture_refs: [],
      required_evidence: @required_evidence,
      checkpoint_policy: "direct"
    })
  end

  defp build_plan(intent, root, packet, digest) do
    Plan.new(%{
      version: 2,
      task: intent,
      repo_root: root,
      base_ref: "HEAD",
      task_class: "default",
      workspace_policy: %{
        "mode" => "isolated",
        "branch_name" => nil,
        "worktree_base_dir" => nil
      },
      worker: %{
        "provider" => @worker_provider,
        "model" => "grok-4.5",
        "permission_mode" => "default",
        "use_pool" => true,
        "resume_provider" => nil,
        "resume_session_id" => nil
      },
      validation_profile: "default",
      review_profile: "binding",
      overlays: [],
      rework: %{"max_cycles" => 2, "stop_conditions" => []},
      budgets: %{
        "wall_clock_ms" => 7_200_000,
        "inactivity_timeout_ms" => 600_000,
        "model_cost_usd" => nil,
        "parallelism" => 1
      },
      output: %{"commit" => true, "draft_pr" => false, "retain_workspace" => true},
      requested_paths: [],
      work_packet: WorkPacket.to_map(packet),
      work_packet_digest: digest
    })
  end
end
