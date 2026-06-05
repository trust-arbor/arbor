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

  defp profile_with(metadata), do: %{trust_tier: :established, metadata: metadata}

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
end
