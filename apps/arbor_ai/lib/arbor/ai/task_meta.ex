defmodule Arbor.AI.TaskMeta do
  @moduledoc """
  Task metadata for heuristic-based classification of prompts.

  Provides pure functions for classifying prompts into routing tiers
  based on keyword matching and heuristics.

  ## Usage

      # Classify a prompt
      meta = TaskMeta.classify("Fix the security vulnerability in auth.ex")
      #=> %TaskMeta{risk_level: :critical, domain: :security, ...}

      # Determine routing tier
      tier = TaskMeta.tier(meta)
      #=> :critical

      # Classify with overrides
      meta = TaskMeta.classify("Hello world", speed_preference: :fast)
      #=> %TaskMeta{speed_preference: :fast, ...}

  ## Classification Rules

  Keywords are matched case-insensitively against the prompt:

  - **Security domain**: "security", "vulnerability", "auth", "credential", "token",
    "encrypt", "password", "permission" → `:critical` risk, `:security` domain
  - **Database domain**: "database", "migration", "schema", "query", "sql" → `:database` domain
  - **Trivial complexity**: "fix typo", "rename", "update comment", "minor" → `:trivial` complexity
  - **Complex complexity**: "refactor", "redesign", "architecture", "rewrite" → `:complex` complexity, `:repo_wide` scope
  - **Reasoning required**: "explain", "why", "analyze", "compare", "understand"
  - **Tools required**: "run", "execute", "build", "compile", "test"
  """

  @type risk_level :: :trivial | :low | :medium | :high | :critical
  @type complexity :: :trivial | :simple | :moderate | :complex
  @type scope :: :single_file | :multi_file | :repo_wide
  @type domain :: :ui | :api | :database | :security | :infra | :docs | :tests | nil
  @type speed_pref :: :fast | :balanced | :thorough
  @type trust_level :: :highest | :high | :medium | :low | :any

  @type t :: %__MODULE__{
          risk_level: risk_level(),
          complexity: complexity(),
          scope: scope(),
          domain: domain(),
          requires_reasoning: boolean(),
          requires_tools: boolean(),
          speed_preference: speed_pref(),
          min_trust_level: trust_level()
        }

  defstruct risk_level: :medium,
            complexity: :moderate,
            scope: :single_file,
            domain: nil,
            requires_reasoning: false,
            requires_tools: false,
            speed_preference: :balanced,
            min_trust_level: :any

  # ===========================================================================
  # Keywords for classification
  # ===========================================================================

  @security_keywords ~w(security vulnerability auth credential token encrypt password permission
                        oauth jwt secret key exploit injection xss csrf sql hack attack breach)

  @database_keywords ~w(database migration schema query sql postgres mysql sqlite ecto repo
                        transaction rollback seed index foreign constraint)

  @trivial_keywords ~w(typo rename comment minor whitespace formatting indent spacing
                       fix_typo update_comment)

  @complex_keywords ~w(refactor redesign architecture rewrite restructure overhaul
                       implement_new build_system migrate_to)

  @ui_keywords ~w(ui component button form input modal dialog style css html jsx tsx
                  render layout responsive theme)

  @api_keywords ~w(api endpoint route controller handler request response status
                   rest graphql grpc http)

  @infra_keywords ~w(deploy docker kubernetes k8s ci cd pipeline container
                     infrastructure config devops ansible terraform)

  @docs_keywords ~w(document readme changelog docs docstring moduledoc guide tutorial)

  @test_keywords ~w(test spec unit integration e2e mock stub fixture assertion
                    exunit describe)

  @reasoning_keywords ~w(explain why analyze compare understand review evaluate
                         assess diagnose investigate debug trace)

  @tools_keywords ~w(run execute build compile test deploy install start stop
                     restart generate create)

  @repo_wide_keywords ~w(codebase entire whole project all_files repository
                         across_all global)

  @multi_file_keywords ~w(multiple several files modules components services
                          layers interfaces)

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Classify a prompt string into TaskMeta via keyword heuristics.

  Returns a TaskMeta struct with inferred properties based on keyword
  matching against the prompt.
  """
  @spec classify(String.t()) :: t()
  def classify(prompt) when is_binary(prompt) do
    classify(prompt, [])
  end

  @doc """
  Classify a prompt with option overrides.

  ## Options

  Any field of TaskMeta can be passed as an option to override the
  heuristic-detected value:

  - `:risk_level` - Override risk level
  - `:complexity` - Override complexity
  - `:scope` - Override scope
  - `:domain` - Override domain
  - `:requires_reasoning` - Override reasoning requirement
  - `:requires_tools` - Override tools requirement
  - `:speed_preference` - Override speed preference
  - `:min_trust_level` - Override minimum trust level
  """
  @spec classify(String.t(), keyword()) :: t()
  def classify(prompt, opts) when is_binary(prompt) and is_list(opts) do
    prompt_lower = String.downcase(prompt)

    # Build base struct from heuristics
    base = %__MODULE__{
      risk_level: detect_risk_level(prompt_lower),
      complexity: detect_complexity(prompt_lower),
      scope: detect_scope(prompt_lower),
      domain: detect_domain(prompt_lower),
      requires_reasoning: detect_requires_reasoning(prompt_lower),
      requires_tools: detect_requires_tools(prompt_lower),
      speed_preference: :balanced,
      min_trust_level: detect_min_trust_level(prompt_lower)
    }

    # Apply overrides from opts
    apply_overrides(base, opts)
  end

  @doc """
  Determine routing tier from TaskMeta.

  The tier is derived from risk_level and complexity:

  - `:critical` - Critical risk tasks or critical domain (security)
  - `:complex` - Complex tasks or repo-wide scope
  - `:moderate` - Moderate complexity tasks
  - `:simple` - Simple tasks
  - `:trivial` - Trivial complexity and single_file scope
  """
  @spec tier(t()) :: :critical | :complex | :moderate | :simple | :trivial
  def tier(%__MODULE__{} = meta) do
    cond do
      # Critical risk or security domain always gets critical tier
      meta.risk_level == :critical ->
        :critical

      meta.domain == :security ->
        :critical

      # Complex complexity or repo-wide scope
      meta.complexity == :complex ->
        :complex

      meta.scope == :repo_wide ->
        :complex

      # High risk or moderate complexity
      meta.risk_level == :high ->
        :complex

      meta.complexity == :moderate ->
        :moderate

      # Multi-file scope or low risk
      meta.scope == :multi_file ->
        :moderate

      meta.risk_level == :low ->
        :simple

      # Simple complexity
      meta.complexity == :simple ->
        :simple

      # Trivial - must be trivial complexity and single file
      meta.complexity == :trivial and meta.scope == :single_file ->
        :trivial

      # Default to moderate
      true ->
        :moderate
    end
  end

  # ===========================================================================
  # Detection Functions
  # ===========================================================================

  defp detect_risk_level(prompt) do
    cond do
      has_keywords?(prompt, @security_keywords) -> :critical
      has_keywords?(prompt, @complex_keywords) -> :high
      has_keywords?(prompt, @database_keywords) -> :medium
      has_keywords?(prompt, @trivial_keywords) -> :trivial
      true -> :medium
    end
  end

  defp detect_complexity(prompt) do
    cond do
      has_keywords?(prompt, @trivial_keywords) -> :trivial
      has_keywords?(prompt, @complex_keywords) -> :complex
      has_keywords?(prompt, @repo_wide_keywords) -> :complex
      has_keywords?(prompt, @multi_file_keywords) -> :moderate
      true -> :moderate
    end
  end

  defp detect_scope(prompt) do
    cond do
      has_keywords?(prompt, @repo_wide_keywords) -> :repo_wide
      has_keywords?(prompt, @complex_keywords) -> :repo_wide
      has_keywords?(prompt, @multi_file_keywords) -> :multi_file
      true -> :single_file
    end
  end

  defp detect_domain(prompt) do
    cond do
      has_keywords?(prompt, @security_keywords) -> :security
      has_keywords?(prompt, @database_keywords) -> :database
      has_keywords?(prompt, @test_keywords) -> :tests
      has_keywords?(prompt, @docs_keywords) -> :docs
      has_keywords?(prompt, @api_keywords) -> :api
      has_keywords?(prompt, @ui_keywords) -> :ui
      has_keywords?(prompt, @infra_keywords) -> :infra
      true -> nil
    end
  end

  defp detect_requires_reasoning(prompt) do
    has_keywords?(prompt, @reasoning_keywords)
  end

  defp detect_requires_tools(prompt) do
    has_keywords?(prompt, @tools_keywords)
  end

  defp detect_min_trust_level(prompt) do
    cond do
      has_keywords?(prompt, @security_keywords) -> :high
      has_keywords?(prompt, @database_keywords) -> :medium
      true -> :any
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp has_keywords?(prompt, keywords) do
    Enum.any?(keywords, fn keyword ->
      # Match whole word boundaries
      String.contains?(prompt, keyword) or
        Regex.match?(~r/\b#{Regex.escape(keyword)}\b/i, prompt)
    end)
  end

  defp apply_overrides(meta, []), do: meta

  defp apply_overrides(meta, [{key, value} | rest])
       when key in ~w(risk_level complexity scope domain
                                                                    requires_reasoning requires_tools
                                                                    speed_preference min_trust_level)a do
    apply_overrides(Map.put(meta, key, value), rest)
  end

  defp apply_overrides(meta, [_unknown | rest]) do
    # Ignore unknown opts
    apply_overrides(meta, rest)
  end
end
