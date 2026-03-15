defmodule Arbor.Trust.ProfileResolverTest do
  use ExUnit.Case, async: true

  alias Arbor.Trust.ProfileResolver

  @moduletag :fast

  describe "resolve_prefix/3" do
    test "returns baseline when no rules match" do
      rules = %{"arbor://shell" => :block}
      assert ProfileResolver.resolve_prefix(rules, "arbor://memory/read", :auto) == :auto
    end

    test "matches exact prefix" do
      rules = %{"arbor://shell" => :block}
      assert ProfileResolver.resolve_prefix(rules, "arbor://shell", :auto) == :block
    end

    test "matches longest prefix" do
      rules = %{
        "arbor://shell" => :block,
        "arbor://shell/exec/git" => :ask
      }

      assert ProfileResolver.resolve_prefix(rules, "arbor://shell/exec/git", :auto) == :ask
      assert ProfileResolver.resolve_prefix(rules, "arbor://shell/exec/rm", :auto) == :block
    end

    test "returns baseline for empty rules" do
      assert ProfileResolver.resolve_prefix(%{}, "arbor://anything", :allow) == :allow
    end

    test "prefix match is greedy (matches child paths)" do
      rules = %{"arbor://shell" => :ask}
      assert ProfileResolver.resolve_prefix(rules, "arbor://shell/exec/git/status", :auto) == :ask
    end
  end

  describe "most_restrictive/1" do
    test "block beats everything" do
      assert ProfileResolver.most_restrictive([:auto, :allow, :ask, :block]) == :block
    end

    test "ask beats allow and auto" do
      assert ProfileResolver.most_restrictive([:auto, :allow, :ask]) == :ask
    end

    test "allow beats auto" do
      assert ProfileResolver.most_restrictive([:auto, :allow]) == :allow
    end

    test "auto alone returns auto" do
      assert ProfileResolver.most_restrictive([:auto, :auto]) == :auto
    end

    test "ignores nil values" do
      assert ProfileResolver.most_restrictive([:auto, nil, :allow, nil]) == :allow
    end

    test "all nil returns :ask as default" do
      assert ProfileResolver.most_restrictive([nil, nil]) == :ask
    end

    test "empty list returns :ask as default" do
      assert ProfileResolver.most_restrictive([]) == :ask
    end
  end

  describe "at_least_as_restrictive?/2" do
    test "block is at least as restrictive as anything" do
      assert ProfileResolver.at_least_as_restrictive?(:block, :block)
      assert ProfileResolver.at_least_as_restrictive?(:block, :ask)
      assert ProfileResolver.at_least_as_restrictive?(:block, :allow)
      assert ProfileResolver.at_least_as_restrictive?(:block, :auto)
    end

    test "auto is only as restrictive as auto" do
      assert ProfileResolver.at_least_as_restrictive?(:auto, :auto)
      refute ProfileResolver.at_least_as_restrictive?(:auto, :allow)
      refute ProfileResolver.at_least_as_restrictive?(:auto, :ask)
      refute ProfileResolver.at_least_as_restrictive?(:auto, :block)
    end

    test "ask is at least as restrictive as ask, allow, auto" do
      assert ProfileResolver.at_least_as_restrictive?(:ask, :ask)
      assert ProfileResolver.at_least_as_restrictive?(:ask, :allow)
      assert ProfileResolver.at_least_as_restrictive?(:ask, :auto)
      refute ProfileResolver.at_least_as_restrictive?(:ask, :block)
    end
  end

  describe "effective_mode/3" do
    test "uses baseline when no rules match" do
      profile = %{rules: %{}, baseline: :ask}
      assert ProfileResolver.effective_mode(profile, "arbor://shell/exec/git") == :ask
    end

    test "user preference is used when no ceiling applies" do
      profile = %{rules: %{"arbor://memory" => :auto}, baseline: :ask}

      assert ProfileResolver.effective_mode(profile, "arbor://memory/read",
               security_ceilings: %{}
             ) == :auto
    end

    test "security ceiling caps user preference" do
      profile = %{rules: %{"arbor://shell" => :auto}, baseline: :auto}

      # Default ceilings: shell => :ask
      assert ProfileResolver.effective_mode(profile, "arbor://shell/exec/git") == :ask
    end

    test "custom security ceilings override defaults" do
      profile = %{rules: %{"arbor://shell" => :auto}, baseline: :auto}

      assert ProfileResolver.effective_mode(profile, "arbor://shell/exec/git",
               security_ceilings: %{"arbor://shell" => :block}
             ) == :block
    end

    test "model constraint applies when model_class provided" do
      profile = %{
        rules: %{"arbor://shell/exec/git" => :allow},
        baseline: :ask,
        model_constraints: %{{:frontier_cloud, "arbor://shell"} => :ask}
      }

      # Without model_class, model constraint doesn't apply
      result_no_model =
        ProfileResolver.effective_mode(profile, "arbor://shell/exec/git",
          security_ceilings: %{}
        )

      assert result_no_model == :allow

      # With model_class, constraint applies
      result_with_model =
        ProfileResolver.effective_mode(profile, "arbor://shell/exec/git",
          security_ceilings: %{},
          model_class: :frontier_cloud
        )

      assert result_with_model == :ask
    end

    test "most restrictive of all three layers wins" do
      profile = %{
        rules: %{"arbor://shell" => :allow},
        baseline: :auto,
        model_constraints: %{{:local, "arbor://shell"} => :block}
      }

      assert ProfileResolver.effective_mode(profile, "arbor://shell/exec/git",
               security_ceilings: %{"arbor://shell" => :ask},
               model_class: :local
             ) == :block
    end

    test "defaults to :ask baseline when not specified" do
      profile = %{}
      assert ProfileResolver.effective_mode(profile, "arbor://anything", security_ceilings: %{}) == :ask
    end
  end

  describe "explain/3" do
    test "returns full resolution chain" do
      profile = %{
        rules: %{"arbor://shell" => :allow, "arbor://shell/exec/git" => :auto},
        baseline: :ask,
        model_constraints: %{}
      }

      result = ProfileResolver.explain(profile, "arbor://shell/exec/git", security_ceilings: %{})

      assert result.resource_uri == "arbor://shell/exec/git"
      assert result.user_mode == :auto
      assert result.user_match == {"arbor://shell/exec/git", :auto}
      assert result.baseline == :ask
      assert result.security_ceiling == :auto
      assert result.effective_mode == :auto
    end

    test "shows security ceiling impact" do
      profile = %{
        rules: %{"arbor://shell" => :auto},
        baseline: :auto,
        model_constraints: %{}
      }

      result = ProfileResolver.explain(profile, "arbor://shell/exec/git")

      assert result.user_mode == :auto
      # Default ceiling: shell => :ask
      assert result.security_ceiling == :ask
      assert result.effective_mode == :ask
    end
  end

  describe "security_ceilings/0" do
    test "shell requires at least :ask" do
      ceilings = ProfileResolver.security_ceilings()
      assert Map.get(ceilings, "arbor://shell") == :ask
    end

    test "governance requires at least :ask" do
      ceilings = ProfileResolver.security_ceilings()
      assert Map.get(ceilings, "arbor://governance") == :ask
    end
  end

  describe "preset/1" do
    test ":cautious blocks shell, auto-allows reads" do
      preset = ProfileResolver.preset(:cautious)
      assert preset.baseline == :ask
      assert preset.rules["arbor://shell"] == :block
      assert preset.rules["arbor://fs/read"] == :auto
    end

    test ":balanced allows file writes, asks for shell exec" do
      preset = ProfileResolver.preset(:balanced)
      assert preset.baseline == :ask
      assert preset.rules["arbor://fs/write"] == :allow
      # Shell exec covered by shell/exec => :ask (covers all exec subcommands)
      assert preset.rules["arbor://shell/exec"] == :ask
    end

    test ":hands_off allows most, asks for shell and governance" do
      preset = ProfileResolver.preset(:hands_off)
      assert preset.baseline == :allow
      assert preset.rules["arbor://shell"] == :ask
      assert preset.rules["arbor://governance"] == :ask
    end

    test ":full_trust auto-allows most, asks for shell and governance" do
      preset = ProfileResolver.preset(:full_trust)
      assert preset.baseline == :auto
      assert preset.rules["arbor://shell"] == :ask
      assert preset.rules["arbor://governance"] == :ask
    end

    test "unknown preset defaults to :balanced" do
      preset = ProfileResolver.preset(:nonexistent)
      assert preset == ProfileResolver.preset(:balanced)
    end
  end

  describe "integration with Profile struct" do
    test "Profile struct has new trust profile fields" do
      {:ok, profile} = Arbor.Contracts.Trust.Profile.new("test_agent")
      assert profile.baseline == :ask
      assert profile.rules == %{}
      assert profile.model_constraints == %{}
    end

    test "effective_mode works with Profile struct" do
      {:ok, profile} = Arbor.Contracts.Trust.Profile.new("test_agent")
      # Should use defaults — baseline :ask, no rules
      result = ProfileResolver.effective_mode(profile, "arbor://memory/read", security_ceilings: %{})
      assert result == :ask
    end

    test "effective_mode works with Profile struct with custom rules" do
      {:ok, profile} = Arbor.Contracts.Trust.Profile.new("test_agent")
      profile = %{profile | rules: %{"arbor://memory" => :auto}, baseline: :allow}
      result = ProfileResolver.effective_mode(profile, "arbor://memory/read", security_ceilings: %{})
      assert result == :auto
    end
  end
end
