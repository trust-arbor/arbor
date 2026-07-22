defmodule Arbor.AI.AcpSession.ReadinessTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.AcpSession.Readiness.Internal
  alias Arbor.Contracts.LLM.ProviderObservation

  @fixed_time ~U[2026-07-22 12:00:00Z]

  setup do
    prior = Application.fetch_env(:arbor_ai, :acp_providers)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:arbor_ai, :acp_providers, value)
        :error -> Application.delete_env(:arbor_ai, :acp_providers)
      end
    end)

    :ok
  end

  test "records Grok 4.5 as the requested and launch-bound model" do
    result = observe(:grok, nil, observation: :available)
    observation = result["observation"]

    assert observation["requested_model_id"] == "grok-4.5"
    assert observation["launch_bound_model_id"] == "grok-4.5"
    assert observation["provider"] == "grok"
    assert observation["source"] == "acp_provider_readiness"
    assert observation["runtime"] == "acp"
    assert observation["availability"] == "degraded"
  end

  test "rejects a launch-bound model mismatch distinctly" do
    result = observe(:grok, "grok-code-fast", observation: :available)
    observation = result["observation"]

    assert observation["availability"] == "unavailable"
    assert observation["failure_code"] == "model_mismatch"
    assert observation["failure_message"] == "requested model does not match launch-bound model"
    assert observation["requested_model_id"] == "grok-code-fast"
    assert observation["launch_bound_model_id"] == "grok-4.5"
  end

  test "string provider ids retain launch-bound model evidence on mismatch" do
    result = observe("grok", "grok-code-fast", observation: :available)
    observation = result["observation"]

    assert observation["provider"] == "grok"
    assert observation["failure_code"] == "model_mismatch"
    assert observation["requested_model_id"] == "grok-code-fast"
    assert observation["launch_bound_model_id"] == "grok-4.5"
  end

  test "unknown provider strings do not intern atoms" do
    _ = Arbor.AI.acp_provider_readiness("provider-that-is-not-registered")
    before = :erlang.system_info(:atom_count)
    result = Arbor.AI.acp_provider_readiness("provider-that-is-not-registered")
    after_count = :erlang.system_info(:atom_count)

    assert before == after_count
    assert result["observation"]["availability"] == "unavailable"
    assert result["observation"]["failure_code"] == "unknown"
  end

  test "reports a missing native executable without returning command details" do
    Application.put_env(:arbor_ai, :acp_providers, %{
      missing_native: %{
        command: ["definitely-missing-arbor-acp"],
        env: [{"ACP_SECRET", "do-not-return-this-secret"}]
      }
    })

    result = Arbor.AI.acp_provider_readiness(:missing_native)
    observation = result["observation"]

    assert observation["availability"] == "unavailable"
    assert observation["failure_code"] == "transport_error"
    refute inspect(result) =~ "definitely-missing-arbor-acp"
    refute inspect(result) =~ "do-not-return-this-secret"
    refute Map.has_key?(result, "command")
    refute Map.has_key?(result, "env")
  end

  test "reports adapted module availability and required adapter config" do
    Application.put_env(:arbor_ai, :acp_providers, %{
      adapted_ready: %{
        transport_mod: __MODULE__.Transport,
        adapter: __MODULE__.Adapter,
        adapter_opts: []
      }
    })

    result = Arbor.AI.acp_provider_readiness(:adapted_ready)
    observation = result["observation"]

    assert observation["availability"] == "degraded"
    assert observation["auth_health"] == "unknown"
    assert observation["provider"] == "adapted_ready"
    assert observation["source"] == "acp_provider_readiness"
    assert observation["runtime"] == "acp"
  end

  test "missing adapted modules are unavailable" do
    Application.put_env(:arbor_ai, :acp_providers, %{
      adapted_missing: %{
        transport_mod: Arbor.AI.AcpSession.ReadinessMissingTransport,
        adapter: Arbor.AI.AcpSession.ReadinessMissingAdapter,
        adapter_opts: []
      }
    })

    result = Arbor.AI.acp_provider_readiness(:adapted_missing)
    observation = result["observation"]

    assert observation["availability"] == "unavailable"
    assert observation["failure_code"] == "protocol_error"
  end

  test "static readiness never claims authentication health" do
    result = observe(:grok, "grok-4.5", observation: :available)
    observation = result["observation"]

    assert observation["auth_health"] == "unknown"
    assert observation["availability"] == "degraded"
  end

  test "injected time produces a deterministic observation and exact digest" do
    result = observe(:grok, "grok-4.5", observation: :available)
    observation = result["observation"]

    assert observation["observed_at"] == "2026-07-22T12:00:00Z"
    assert observation["expires_at"] == "2026-07-22T12:00:30Z"
    assert {:ok, digest} = ProviderObservation.digest(observation)
    assert result["digest"] == digest
    assert result == observe(:grok, "grok-4.5", observation: :available)
  end

  test "dynamic providers record requested model but leave membership unknown" do
    result = observe(:claude, "claude-sonnet-4-5", observation: :available)
    observation = result["observation"]

    assert observation["requested_model_id"] == "claude-sonnet-4-5"
    assert observation["model_catalog_membership"] == "unknown"
    refute Map.has_key?(observation, "launch_bound_model_id")
  end

  test "rejects non-string requested models for dynamic providers" do
    result = observe(:claude, 123, observation: :available)
    observation = result["observation"]

    assert observation["availability"] == "unavailable"
    assert observation["failure_code"] == "model_absent"
  end

  defmodule Transport do
  end

  defmodule Adapter do
  end

  defp observe(provider, model, opts) do
    Internal.observe(provider, model, Keyword.put_new(opts, :clock, fn -> @fixed_time end))
  end
end
