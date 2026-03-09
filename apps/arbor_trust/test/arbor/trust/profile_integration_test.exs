defmodule Arbor.Trust.ProfileIntegrationTest do
  @moduledoc """
  Integration tests for the Trust Profiles feature.

  Tests the full pipeline: TrustProfile struct -> ProfileResolver resolution
  with user rules, security ceilings, and model constraints interacting.
  """

  use ExUnit.Case, async: true

  alias Arbor.Contracts.Trust.Profile
  alias Arbor.Trust.ProfileResolver

  @moduletag :fast

  # ── Helpers ───────────────────────────────────────────────────────────

  # Build a profile struct with custom trust profile fields
  defp build_profile(attrs) do
    {:ok, profile} = Profile.new(Map.get(attrs, :agent_id, "test_agent_#{:rand.uniform(100_000)}"))

    profile
    |> Map.put(:baseline, Map.get(attrs, :baseline, :ask))
    |> Map.put(:rules, Map.get(attrs, :rules, %{}))
    |> Map.put(:model_constraints, Map.get(attrs, :model_constraints, %{}))
  end

  # Common URIs used across tests
  @shell_exec "arbor://shell/exec/bash"
  @shell_git "arbor://shell/exec/git"
  @shell_git_status "arbor://shell/exec/git/status"
  @file_read "arbor://actions/execute/file.read"
  @file_write "arbor://actions/execute/file.write"
  @code_read "arbor://actions/execute/code.read"
  @memory_read "arbor://memory/read"
  @memory_write "arbor://memory/write"
  @governance_vote "arbor://governance/vote"
  @historian_query "arbor://historian/query"

  # ── 1. Custom rules + effective_mode resolution ──────────────────────

  describe "custom rules -> effective_mode resolution" do
    test "profile with granular shell rules resolves correctly per URI" do
      profile = build_profile(%{
        baseline: :ask,
        rules: %{
          "arbor://shell" => :block,
          "arbor://shell/exec/git" => :ask,
          "arbor://shell/exec/git/status" => :auto,
          "arbor://actions/execute/file.read" => :auto,
          "arbor://memory" => :allow
        }
      })

      # Shell broadly blocked
      assert ProfileResolver.effective_mode(profile, @shell_exec, security_ceilings: %{}) == :block

      # Git specifically allowed to ask
      assert ProfileResolver.effective_mode(profile, @shell_git, security_ceilings: %{}) == :ask

      # Git status auto (most specific match)
      assert ProfileResolver.effective_mode(profile, @shell_git_status, security_ceilings: %{}) == :auto

      # File read auto
      assert ProfileResolver.effective_mode(profile, @file_read, security_ceilings: %{}) == :auto

      # Memory allows (prefix match)
      assert ProfileResolver.effective_mode(profile, @memory_read, security_ceilings: %{}) == :allow
      assert ProfileResolver.effective_mode(profile, @memory_write, security_ceilings: %{}) == :allow

      # Unmatched URI falls to baseline
      assert ProfileResolver.effective_mode(profile, "arbor://unknown/resource", security_ceilings: %{}) == :ask
    end

    test "baseline propagates as default for all unmatched URIs" do
      profile = build_profile(%{baseline: :allow, rules: %{"arbor://shell" => :block}})

      assert ProfileResolver.effective_mode(profile, @memory_read, security_ceilings: %{}) == :allow
      assert ProfileResolver.effective_mode(profile, @file_read, security_ceilings: %{}) == :allow
      assert ProfileResolver.effective_mode(profile, @historian_query, security_ceilings: %{}) == :allow
      # Matched rule overrides baseline
      assert ProfileResolver.effective_mode(profile, @shell_exec, security_ceilings: %{}) == :block
    end
  end

  # ── 2. Security ceilings cap user preferences ────────────────────────

  describe "security ceilings prevent overly permissive user preferences" do
    test "shell :auto user preference capped to :ask by default ceiling" do
      profile = build_profile(%{
        baseline: :auto,
        rules: %{"arbor://shell" => :auto}
      })

      # Default security ceilings cap shell to :ask
      result = ProfileResolver.effective_mode(profile, @shell_exec)
      assert result == :ask
    end

    test "governance :auto user preference capped to :ask by default ceiling" do
      profile = build_profile(%{
        baseline: :auto,
        rules: %{"arbor://governance" => :auto}
      })

      result = ProfileResolver.effective_mode(profile, @governance_vote)
      assert result == :ask
    end

    test "user :block is more restrictive than ceiling :ask, so block wins" do
      profile = build_profile(%{
        baseline: :ask,
        rules: %{"arbor://shell" => :block}
      })

      # User says block, ceiling says ask — block is more restrictive
      result = ProfileResolver.effective_mode(profile, @shell_exec)
      assert result == :block
    end

    test "non-shell URIs are not capped when no ceiling applies" do
      profile = build_profile(%{
        baseline: :auto,
        rules: %{"arbor://memory" => :auto}
      })

      # Default ceilings only cover shell and governance
      result = ProfileResolver.effective_mode(profile, @memory_read)
      assert result == :auto
    end

    test "custom ceilings can restrict any URI prefix" do
      custom_ceilings = %{
        "arbor://shell" => :ask,
        "arbor://governance" => :ask,
        "arbor://memory/write" => :ask
      }

      profile = build_profile(%{
        baseline: :auto,
        rules: %{"arbor://memory" => :auto}
      })

      # Memory read: no ceiling match on "arbor://memory/write" prefix
      assert ProfileResolver.effective_mode(profile, @memory_read, security_ceilings: custom_ceilings) == :auto

      # Memory write: ceiling caps to :ask
      assert ProfileResolver.effective_mode(profile, @memory_write, security_ceilings: custom_ceilings) == :ask
    end
  end

  # ── 3. Model constraints as a third restriction layer ────────────────

  describe "model constraints add a third layer of restriction" do
    test "model constraint further restricts beyond user preference and ceiling" do
      profile = build_profile(%{
        baseline: :allow,
        rules: %{"arbor://actions/execute/file.write" => :allow},
        model_constraints: %{
          {:local_small, "arbor://actions/execute/file.write"} => :ask
        }
      })

      # Without model class — user preference wins (no ceiling on this URI)
      assert ProfileResolver.effective_mode(profile, @file_write,
               security_ceilings: %{},
               model_class: nil
             ) == :allow

      # With matching model class — constrained to :ask
      assert ProfileResolver.effective_mode(profile, @file_write,
               security_ceilings: %{},
               model_class: :local_small
             ) == :ask

      # With non-matching model class — no constraint
      assert ProfileResolver.effective_mode(profile, @file_write,
               security_ceilings: %{},
               model_class: :frontier_cloud
             ) == :allow
    end

    test "model constraint uses longest prefix match" do
      profile = build_profile(%{
        baseline: :auto,
        rules: %{},
        model_constraints: %{
          {:local_small, "arbor://shell"} => :block,
          {:local_small, "arbor://shell/exec/git"} => :ask
        }
      })

      # Git matches the more specific constraint
      assert ProfileResolver.effective_mode(profile, @shell_git,
               security_ceilings: %{},
               model_class: :local_small
             ) == :ask

      # Other shell commands match the broad block
      assert ProfileResolver.effective_mode(profile, @shell_exec,
               security_ceilings: %{},
               model_class: :local_small
             ) == :block
    end

    test "all three layers combine: most restrictive wins" do
      profile = build_profile(%{
        baseline: :auto,
        rules: %{"arbor://shell/exec/git" => :allow},
        model_constraints: %{
          {:frontier_cloud, "arbor://shell"} => :allow
        }
      })

      # User: :allow, Security ceiling (default): :ask, Model: :allow
      # Most restrictive = :ask (from security ceiling)
      result = ProfileResolver.effective_mode(profile, @shell_git, model_class: :frontier_cloud)
      assert result == :ask
    end

    test "model :block overrides even when user and ceiling are permissive" do
      profile = build_profile(%{
        baseline: :auto,
        rules: %{"arbor://memory" => :auto},
        model_constraints: %{
          {:untrusted_model, "arbor://memory"} => :block
        }
      })

      result = ProfileResolver.effective_mode(profile, @memory_read,
        security_ceilings: %{},
        model_class: :untrusted_model
      )

      assert result == :block
    end
  end

  # ── 4. Preset profiles produce expected modes ────────────────────────

  describe "preset profiles produce expected modes for common URIs" do
    test ":cautious preset blocks all shell, auto-allows reads" do
      preset = ProfileResolver.preset(:cautious)
      profile = build_profile(Map.put(preset, :agent_id, "cautious_agent"))

      # Shell blocked (rule overrides baseline)
      assert ProfileResolver.effective_mode(profile, @shell_exec, security_ceilings: %{}) == :block
      assert ProfileResolver.effective_mode(profile, @shell_git, security_ceilings: %{}) == :block

      # Read operations auto-allowed
      assert ProfileResolver.effective_mode(profile, @file_read, security_ceilings: %{}) == :auto
      assert ProfileResolver.effective_mode(profile, @code_read, security_ceilings: %{}) == :auto
      assert ProfileResolver.effective_mode(profile, @historian_query, security_ceilings: %{}) == :auto

      # Write operations fall to baseline :ask
      assert ProfileResolver.effective_mode(profile, @file_write, security_ceilings: %{}) == :ask

      # Memory falls to baseline :ask
      assert ProfileResolver.effective_mode(profile, @memory_read, security_ceilings: %{}) == :ask
    end

    test ":balanced preset allows writes with notification, asks for git" do
      preset = ProfileResolver.preset(:balanced)
      profile = build_profile(Map.put(preset, :agent_id, "balanced_agent"))

      # Reads auto
      assert ProfileResolver.effective_mode(profile, @file_read, security_ceilings: %{}) == :auto
      assert ProfileResolver.effective_mode(profile, @code_read, security_ceilings: %{}) == :auto

      # File write is :allow (notified)
      assert ProfileResolver.effective_mode(profile, @file_write, security_ceilings: %{}) == :allow

      # Git is :ask
      assert ProfileResolver.effective_mode(profile, @shell_git, security_ceilings: %{}) == :ask

      # Other shell falls to baseline :ask
      assert ProfileResolver.effective_mode(profile, @shell_exec, security_ceilings: %{}) == :ask
    end

    test ":hands_off preset allows most, asks for shell and governance" do
      preset = ProfileResolver.preset(:hands_off)
      profile = build_profile(Map.put(preset, :agent_id, "hands_off_agent"))

      # Most things are :allow (baseline)
      assert ProfileResolver.effective_mode(profile, @file_read, security_ceilings: %{}) == :allow
      assert ProfileResolver.effective_mode(profile, @memory_read, security_ceilings: %{}) == :allow

      # Shell and governance capped to :ask by rules
      assert ProfileResolver.effective_mode(profile, @shell_exec, security_ceilings: %{}) == :ask
      assert ProfileResolver.effective_mode(profile, @governance_vote, security_ceilings: %{}) == :ask
    end

    test ":full_trust preset auto-allows most, but shell/governance still capped" do
      preset = ProfileResolver.preset(:full_trust)
      profile = build_profile(Map.put(preset, :agent_id, "full_trust_agent"))

      # Most things are :auto (baseline)
      assert ProfileResolver.effective_mode(profile, @file_read, security_ceilings: %{}) == :auto
      assert ProfileResolver.effective_mode(profile, @memory_read, security_ceilings: %{}) == :auto

      # Shell and governance capped to :ask by rules
      assert ProfileResolver.effective_mode(profile, @shell_exec, security_ceilings: %{}) == :ask
      assert ProfileResolver.effective_mode(profile, @governance_vote, security_ceilings: %{}) == :ask
    end

    test ":full_trust with default security ceilings still caps shell to :ask" do
      preset = ProfileResolver.preset(:full_trust)
      profile = build_profile(Map.put(preset, :agent_id, "full_trust_agent"))

      # Even without explicit rules, the default security ceilings would cap shell.
      # But :full_trust already has rules setting shell to :ask, so both layers agree.
      result = ProfileResolver.effective_mode(profile, @shell_exec)
      assert result == :ask
    end
  end

  # ── 5. explain/3 returns complete resolution chain ───────────────────

  describe "explain/3 returns complete resolution chain" do
    test "shows all layers for a rule-matched URI" do
      profile = build_profile(%{
        baseline: :allow,
        rules: %{
          "arbor://shell" => :block,
          "arbor://shell/exec/git" => :ask
        },
        model_constraints: %{
          {:local_small, "arbor://shell"} => :block
        }
      })

      explanation = ProfileResolver.explain(profile, @shell_git,
        security_ceilings: %{"arbor://shell" => :ask},
        model_class: :local_small
      )

      assert explanation.resource_uri == @shell_git
      assert explanation.baseline == :allow

      # User mode: longest prefix match is "arbor://shell/exec/git" => :ask
      assert explanation.user_mode == :ask
      assert explanation.user_match == {"arbor://shell/exec/git", :ask}

      # Security ceiling: "arbor://shell" => :ask
      assert explanation.security_ceiling == :ask
      assert explanation.ceiling_match == {"arbor://shell", :ask}

      # Model: "arbor://shell" => :block for :local_small
      assert explanation.model_class == :local_small
      assert explanation.model_ceiling == :block

      # Effective: most restrictive of [:ask, :ask, :block] = :block
      assert explanation.effective_mode == :block
    end

    test "shows nil model ceiling when no model_class provided" do
      profile = build_profile(%{
        baseline: :ask,
        rules: %{"arbor://memory" => :auto}
      })

      explanation = ProfileResolver.explain(profile, @memory_read, security_ceilings: %{})

      assert explanation.model_class == nil
      assert explanation.model_ceiling == nil
      assert explanation.user_mode == :auto
      assert explanation.effective_mode == :auto
    end

    test "shows baseline when no rule matches" do
      profile = build_profile(%{baseline: :allow, rules: %{}})

      explanation = ProfileResolver.explain(profile, @memory_read, security_ceilings: %{})

      assert explanation.user_mode == :allow
      assert explanation.user_match == nil
      assert explanation.baseline == :allow
      assert explanation.effective_mode == :allow
    end

    test "shows ceiling overriding user preference" do
      profile = build_profile(%{
        baseline: :auto,
        rules: %{"arbor://shell" => :auto}
      })

      explanation = ProfileResolver.explain(profile, @shell_exec)

      assert explanation.user_mode == :auto
      # Default ceiling caps shell to :ask
      assert explanation.security_ceiling == :ask
      assert explanation.effective_mode == :ask
    end
  end

  # ── 6. Edge cases ────────────────────────────────────────────────────

  describe "edge cases" do
    test "empty rules with various baselines" do
      for baseline <- [:block, :ask, :allow, :auto] do
        profile = build_profile(%{baseline: baseline, rules: %{}})
        result = ProfileResolver.effective_mode(profile, @memory_read, security_ceilings: %{})
        assert result == baseline, "Expected #{baseline} for empty rules with baseline #{baseline}"
      end
    end

    test "conflicting prefixes: most specific wins" do
      profile = build_profile(%{
        baseline: :block,
        rules: %{
          "arbor://" => :block,
          "arbor://actions" => :ask,
          "arbor://actions/execute" => :allow,
          "arbor://actions/execute/file.read" => :auto
        }
      })

      # Each level gets more specific and more permissive
      assert ProfileResolver.effective_mode(profile, "arbor://unknown", security_ceilings: %{}) == :block
      assert ProfileResolver.effective_mode(profile, "arbor://actions/list", security_ceilings: %{}) == :ask
      assert ProfileResolver.effective_mode(profile, "arbor://actions/execute/code.eval", security_ceilings: %{}) == :allow
      assert ProfileResolver.effective_mode(profile, @file_read, security_ceilings: %{}) == :auto
    end

    test "nil model_class means model constraints are ignored" do
      profile = build_profile(%{
        baseline: :auto,
        rules: %{},
        model_constraints: %{
          {:any_model, "arbor://"} => :block
        }
      })

      # Without model_class, the block constraint is ignored
      result = ProfileResolver.effective_mode(profile, @memory_read,
        security_ceilings: %{},
        model_class: nil
      )

      assert result == :auto
    end

    test "profile with no fields defaults gracefully" do
      # Bare map with no fields at all
      empty_profile = %{}

      result = ProfileResolver.effective_mode(empty_profile, @memory_read, security_ceilings: %{})
      # Defaults: rules=%{}, baseline=:ask, model_constraints=%{}
      assert result == :ask
    end

    test "explain with empty profile returns sensible defaults" do
      explanation = ProfileResolver.explain(%{}, @memory_read, security_ceilings: %{})

      assert explanation.resource_uri == @memory_read
      assert explanation.baseline == :ask
      assert explanation.user_mode == :ask
      assert explanation.user_match == nil
      assert explanation.security_ceiling == :auto
      assert explanation.model_class == nil
      assert explanation.model_ceiling == nil
      assert explanation.effective_mode == :ask
    end

    test "very long URI prefix chains resolve correctly" do
      deep_uri = "arbor://shell/exec/git/remote/add/origin"

      profile = build_profile(%{
        baseline: :block,
        rules: %{
          "arbor://shell" => :block,
          "arbor://shell/exec" => :block,
          "arbor://shell/exec/git" => :ask,
          "arbor://shell/exec/git/remote" => :allow
        }
      })

      # Longest match is "arbor://shell/exec/git/remote" => :allow
      result = ProfileResolver.effective_mode(profile, deep_uri, security_ceilings: %{})
      assert result == :allow
    end

    test "model constraints with multiple model classes are independent" do
      profile = build_profile(%{
        baseline: :auto,
        rules: %{},
        model_constraints: %{
          {:frontier_cloud, "arbor://shell"} => :ask,
          {:local_small, "arbor://shell"} => :block,
          {:frontier_cloud, "arbor://memory"} => :allow
        }
      })

      # frontier_cloud on shell => :ask
      assert ProfileResolver.effective_mode(profile, @shell_exec,
               security_ceilings: %{},
               model_class: :frontier_cloud
             ) == :ask

      # local_small on shell => :block
      assert ProfileResolver.effective_mode(profile, @shell_exec,
               security_ceilings: %{},
               model_class: :local_small
             ) == :block

      # frontier_cloud on memory => :allow
      assert ProfileResolver.effective_mode(profile, @memory_read,
               security_ceilings: %{},
               model_class: :frontier_cloud
             ) == :allow

      # local_small on memory => no constraint (nil), so baseline :auto wins
      assert ProfileResolver.effective_mode(profile, @memory_read,
               security_ceilings: %{},
               model_class: :local_small
             ) == :auto
    end

    test "preset profile with model constraints applied end-to-end" do
      preset = ProfileResolver.preset(:full_trust)

      profile = build_profile(%{
        baseline: preset.baseline,
        rules: preset.rules,
        model_constraints: %{
          {:local_small, "arbor://actions/execute/file.write"} => :ask
        }
      })

      # File read: auto (baseline), no model constraint for this URI
      assert ProfileResolver.effective_mode(profile, @file_read,
               security_ceilings: %{},
               model_class: :local_small
             ) == :auto

      # File write: baseline auto, but model constrains to :ask
      assert ProfileResolver.effective_mode(profile, @file_write,
               security_ceilings: %{},
               model_class: :local_small
             ) == :ask

      # Shell: rule says :ask, model has no constraint, ceiling irrelevant => :ask
      assert ProfileResolver.effective_mode(profile, @shell_exec,
               security_ceilings: %{},
               model_class: :local_small
             ) == :ask
    end
  end
end
