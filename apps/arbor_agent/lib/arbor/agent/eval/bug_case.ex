defmodule Arbor.Agent.Eval.BugCase do
  @moduledoc """
  Bug definition for v3 real-task memory ablation eval.

  Each bug case references a real fix commit and its pre-fix parent, so the
  eval can check out the broken code in a git worktree and ask a diagnostician
  agent to find and fix it.
  """

  @type t :: %__MODULE__{
          id: atom(),
          name: String.t(),
          fix_commit: String.t(),
          pre_fix_commit: String.t(),
          file: String.t(),
          function: String.t(),
          symptom: String.t(),
          root_cause: String.t(),
          fix_description: String.t(),
          directive_template: String.t(),
          initial_goal: String.t(),
          scoring: scoring()
        }

  @type scoring :: %{
          target_file: String.t(),
          target_function: String.t(),
          root_cause_keywords: [String.t()],
          fix_keywords: [String.t()]
        }

  @enforce_keys [:id, :name, :fix_commit, :pre_fix_commit, :file, :function]
  defstruct [
    :id,
    :name,
    :fix_commit,
    :pre_fix_commit,
    :file,
    :function,
    :symptom,
    :root_cause,
    :fix_description,
    :directive_template,
    :initial_goal,
    scoring: %{}
  ]

  @doc """
  CapabilityStore glob wildcard bug.

  `authorizes_resource?/2` didn't handle `/**` glob patterns — capability URIs
  like `arbor://actions/execute/**` failed to match specific action URIs like
  `arbor://actions/execute/memory_recall`.
  """
  def glob_wildcard do
    %__MODULE__{
      id: :glob_wildcard,
      name: "CapabilityStore glob wildcards",
      fix_commit: "45d7d8b3",
      pre_fix_commit: "f681e22f",
      file: "apps/arbor_security/lib/arbor/security/capability_store.ex",
      function: "authorizes_resource?/2",
      symptom:
        "Capability URIs with /** glob wildcards (e.g. arbor://actions/execute/**) " <>
          "fail to match specific action URIs (e.g. arbor://actions/execute/memory_recall). " <>
          "All agent tool calls are denied even though the agent has wildcard capabilities granted.",
      root_cause:
        "The authorizes_resource?/2 function only checks exact match and prefix+separator. " <>
          "It has no handling for glob wildcards like /**. When a capability has " <>
          "resource_uri ending in /**, the function falls through to the prefix check " <>
          "which appends / and fails because ** is not stripped.",
      fix_description:
        "Add a cond branch that detects /** suffix, strips it to get the prefix, " <>
          "and uses String.starts_with? for matching.",
      directive_template: """
      You are investigating a bug in the Arbor security system.

      SYMPTOM: Agent tool execution is being denied even though capabilities are granted.
      Specifically, wildcard capability URIs like "arbor://actions/execute/**" fail to
      authorize specific URIs like "arbor://actions/execute/memory_recall".

      The bug is in the codebase at: {WORKTREE_PATH}

      INVESTIGATE: Read the file at {WORKTREE_PATH}/apps/arbor_security/lib/arbor/security/capability_store.ex
      and find the function that matches capability resource URIs against requested resources.
      Determine why glob wildcard patterns (/**) are not being matched.

      When you have identified the root cause and know how to fix it, create a proposal
      with your analysis and fix recommendation. Include the specific function name,
      the root cause, and the code change needed.
      """,
      initial_goal:
        "Find and fix the bug in CapabilityStore where /** glob wildcards in " <>
          "capability URIs fail to match specific action URIs",
      scoring: %{
        target_file: "capability_store.ex",
        target_function: "authorizes_resource?",
        root_cause_keywords: [
          "glob",
          "wildcard",
          "/**",
          "prefix",
          "starts_with",
          "authorizes_resource"
        ],
        fix_keywords: [
          "ends_with",
          "trim_trailing",
          "starts_with",
          "prefix",
          "/**",
          "glob",
          "cond"
        ]
      }
    }
  end

  @doc "All available bug cases."
  def all, do: [glob_wildcard()]

  @doc "Get a bug case by ID."
  def get(:glob_wildcard), do: {:ok, glob_wildcard()}
  def get(id), do: {:error, {:unknown_bug, id}}

  @doc "List available bug IDs."
  def ids, do: [:glob_wildcard]
end
