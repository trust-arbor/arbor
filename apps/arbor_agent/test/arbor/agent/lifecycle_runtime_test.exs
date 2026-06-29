defmodule Arbor.Agent.LifecycleRuntimeTest do
  @moduledoc """
  Unit tests for `Arbor.Agent.Lifecycle.resolve_agent_runtime/2` — the
  per-agent runtime resolver used at both seams where Lifecycle decides
  what runtime an agent's heartbeats + Registry metadata will carry.

  Pre-Phase 4 follow-up: both seams hardcoded `:arbor` (Registry
  metadata) or relied on `SessionConfig`'s default (heartbeat opts), so
  an agent configured with `runtime: :acp` at create-time would still
  heartbeat through the in-BEAM HTTP path.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Lifecycle

  defp profile_with(metadata), do: %{metadata: metadata}

  describe "resolve_agent_runtime/2" do
    test "defaults to :arbor when nothing is set" do
      assert Lifecycle.resolve_agent_runtime(profile_with(%{}), []) == :arbor
    end

    test "explicit opts[:runtime] wins over everything else" do
      profile = profile_with(%{last_model_config: %{runtime: :acp}})
      opts = [runtime: :arbor, model_config: %{runtime: :acp}]
      assert Lifecycle.resolve_agent_runtime(profile, opts) == :arbor
    end

    test "opts[:model_config][:runtime] picked up when no top-level :runtime" do
      assert Lifecycle.resolve_agent_runtime(profile_with(%{}), model_config: %{runtime: :acp}) ==
               :acp
    end

    test "profile.metadata[:last_model_config][:runtime] used for restored agents" do
      profile = profile_with(%{last_model_config: %{runtime: :acp}})
      assert Lifecycle.resolve_agent_runtime(profile, []) == :acp
    end

    test "profile.metadata uses string keys (Postgres-restored shape)" do
      profile = profile_with(%{"last_model_config" => %{"runtime" => :acp}})
      assert Lifecycle.resolve_agent_runtime(profile, []) == :acp
    end

    test "opts model_config beats profile-persisted config" do
      profile = profile_with(%{last_model_config: %{runtime: :acp}})
      assert Lifecycle.resolve_agent_runtime(profile, model_config: %{runtime: :arbor}) == :arbor
    end

    test "nil profile.metadata doesn't crash the resolution chain" do
      assert Lifecycle.resolve_agent_runtime(%{metadata: nil}, []) == :arbor
    end

    test "missing profile.metadata key doesn't crash" do
      assert Lifecycle.resolve_agent_runtime(%{}, []) == :arbor
    end
  end

  describe "resolve_fallback_chain/2 — persistence + normalization" do
    test "returns [] for nothing-set agent" do
      assert Lifecycle.resolve_fallback_chain(profile_with(%{}), []) == []
    end

    test "explicit opts[:fallback_chain] wins" do
      profile = profile_with(%{last_model_config: %{fallback_chain: [%{runtime: :acp}]}})
      opts = [fallback_chain: [%{runtime: :arbor}], model_config: %{fallback_chain: [%{}]}]
      assert Lifecycle.resolve_fallback_chain(profile, opts) == [%{runtime: :arbor}]
    end

    test "opts[:model_config][:fallback_chain] picked up when no top-level" do
      chain = [%{runtime: :acp, model: "claude-sonnet-4-6"}]

      assert Lifecycle.resolve_fallback_chain(
               profile_with(%{}),
               model_config: %{fallback_chain: chain}
             ) == chain
    end

    test "persisted profile.metadata fallback_chain for restored agents" do
      chain = [%{runtime: :acp}, %{provider: :openai}]
      profile = profile_with(%{last_model_config: %{fallback_chain: chain}})
      assert Lifecycle.resolve_fallback_chain(profile, []) == chain
    end

    test "string-keyed Postgres-restored chain is atomized" do
      profile =
        profile_with(%{
          "last_model_config" => %{
            "fallback_chain" => [
              %{"runtime" => "acp", "model" => "claude-sonnet-4-6"},
              %{"provider" => "openai"}
            ]
          }
        })

      assert Lifecycle.resolve_fallback_chain(profile, []) == [
               %{runtime: :acp, model: "claude-sonnet-4-6"},
               %{provider: :openai}
             ]
    end

    test "non-existing atom in string value falls through (DoS protection)" do
      profile =
        profile_with(%{
          "last_model_config" => %{
            "fallback_chain" => [
              %{"runtime" => "this_atom_does_not_exist_anywhere_in_the_system_xyz"}
            ]
          }
        })

      # The entry's :runtime key drops; entry becomes %{}; gets rejected.
      assert Lifecycle.resolve_fallback_chain(profile, []) == []
    end

    test "mixed atom/string keys in same entry are normalized" do
      mixed_entry = %{:runtime => :acp, "model" => "claude-sonnet-4-6"}

      profile =
        profile_with(%{
          last_model_config: %{fallback_chain: [mixed_entry]}
        })

      assert Lifecycle.resolve_fallback_chain(profile, []) == [
               %{runtime: :acp, model: "claude-sonnet-4-6"}
             ]
    end

    test "empty entries are dropped" do
      profile =
        profile_with(%{
          last_model_config: %{fallback_chain: [%{}, %{runtime: :acp}, %{}]}
        })

      assert Lifecycle.resolve_fallback_chain(profile, []) == [%{runtime: :acp}]
    end

    test "non-list value defaults to []" do
      profile = profile_with(%{last_model_config: %{fallback_chain: "not a list"}})
      assert Lifecycle.resolve_fallback_chain(profile, []) == []
    end
  end
end
