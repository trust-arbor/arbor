defmodule Arbor.Contracts.LLM.ProviderUsageEventTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.LLM.ProviderUsageEvent

  @moduletag :fast

  @max_token_count 1_000_000_000
  @max_number 1.0e18
  @max_event_id_bytes 64
  @max_identifier_bytes 512

  @valid %{
    event_id: "usage-evt-1",
    provider: :openai,
    account_id: "acct-1",
    source: "req_llm",
    runtime: :arbor,
    model_id: "gpt-5",
    operation: :complete,
    occurred_at: "2026-07-22T17:00:00-05:00",
    principal_id: "agent_abc",
    task_id: "task-1",
    goal_id: "goal-1",
    correlation_id: "corr-1",
    input_tokens: 1_000,
    output_tokens: 250,
    total_tokens: 1_250,
    cached_tokens: 100,
    marginal_api_cost_usd: 0.0125,
    subscription_usage_units: 2.0
  }

  @canonical_bytes ~s({"version":1,"event_id":"usage-evt-1","provider":"openai","account_id":"acct-1","source":"req_llm","runtime":"arbor","model_id":"gpt-5","operation":"complete","occurred_at":"2026-07-22T22:00:00Z","principal_id":"agent_abc","task_id":"task-1","goal_id":"goal-1","correlation_id":"corr-1","input_tokens":1000,"output_tokens":250,"total_tokens":1250,"cached_tokens":100,"marginal_api_cost_usd":0.0125,"subscription_usage_units":2.0})

  test "constructs ledger input and keeps API spend distinct from subscription usage" do
    assert {:ok, event} = ProviderUsageEvent.new(@valid)
    assert event.version == 1
    assert event.event_id == "usage-evt-1"
    assert event.provider == "openai"
    assert event.runtime == "arbor"
    assert event.model_id == "gpt-5"
    assert event.operation == "complete"
    assert event.occurred_at == "2026-07-22T22:00:00Z"
    assert event.input_tokens == 1_000
    assert event.output_tokens == 250
    assert event.total_tokens == 1_250
    assert event.cached_tokens == 100
    assert event.marginal_api_cost_usd == 0.0125
    assert event.subscription_usage_units == 2.0
    assert ProviderUsageEvent.schema_version() == 1

    map = ProviderUsageEvent.to_map(event)
    assert map["model_id"] == "gpt-5"
    assert map["marginal_api_cost_usd"] == 0.0125
    assert map["subscription_usage_units"] == 2.0
    refute Map.has_key?(map, "model")
    refute Map.has_key?(map, "subscription_usage")
    refute Map.has_key?(map, "cost")
    refute Map.has_key?(map, "capacity")
  end

  test "every closed operation constructs" do
    for operation <- ["complete", "embed_cloud", "embed_local", "acp_prompt"] do
      assert {:ok, event} = ProviderUsageEvent.new(Map.put(@valid, :operation, operation))
      assert event.operation == operation
    end

    for operation <- [:complete, :embed_cloud, :embed_local, :acp_prompt] do
      assert {:ok, event} = ProviderUsageEvent.new(Map.put(@valid, :operation, operation))
      assert event.operation == Atom.to_string(operation)
    end

    assert ProviderUsageEvent.enums()["operation"] == [
             "complete",
             "embed_cloud",
             "embed_local",
             "acp_prompt"
           ]

    assert ProviderUsageEvent.enums()["runtime"] == ["arbor", "acp", "local", "unknown"]
  end

  test "every closed runtime constructs when present" do
    for runtime <- ["arbor", "acp", "local", "unknown"] do
      assert {:ok, event} = ProviderUsageEvent.new(Map.put(@valid, :runtime, runtime))
      assert event.runtime == runtime
    end
  end

  test "allows unobserved optional scope and cost facts" do
    attrs =
      Map.drop(@valid, [
        :account_id,
        :runtime,
        :principal_id,
        :task_id,
        :goal_id,
        :correlation_id,
        :marginal_api_cost_usd,
        :subscription_usage_units
      ])

    assert {:ok, event} = ProviderUsageEvent.new(attrs)
    assert event.account_id == nil
    assert event.runtime == nil
    assert event.principal_id == nil
    assert event.marginal_api_cost_usd == nil
    assert event.subscription_usage_units == nil
    assert ProviderUsageEvent.to_map(event)["subscription_usage_units"] == nil

    for missing <- [
          :event_id,
          :provider,
          :source,
          :model_id,
          :operation,
          :occurred_at,
          :input_tokens,
          :output_tokens,
          :total_tokens,
          :cached_tokens
        ] do
      assert {:error, _} = ProviderUsageEvent.new(Map.delete(@valid, missing))
    end
  end

  test "rejects unknown fields and closed enum values" do
    assert {:error, {:unknown_fields, ["metadata"]}} =
             ProviderUsageEvent.new(Map.put(@valid, :metadata, %{note: "nope"}))

    assert {:error, {:unknown_fields, ["model"]}} =
             ProviderUsageEvent.new(
               @valid
               |> Map.delete(:model_id)
               |> Map.put(:model, "gpt-5")
             )

    assert {:error, {:unknown_fields, ["subscription_usage"]}} =
             ProviderUsageEvent.new(
               @valid
               |> Map.delete(:subscription_usage_units)
               |> Map.put(:subscription_usage, 2.0)
             )

    for {field, value} <- [
          {:operation, :chat},
          {:operation, :prompt},
          {:runtime, :shell},
          {:version, 2}
        ] do
      refute ProviderUsageEvent.valid?(Map.put(@valid, field, value))
    end
  end

  test "mixed atom and string provider aliases are rejected as duplicate" do
    assert {:error, {:duplicate_fields, ["provider"]}} =
             ProviderUsageEvent.new([
               {:provider, "openai"},
               {"provider", "anthropic"} | keyword_valid()
             ])

    mixed_map =
      @valid
      |> Map.delete(:provider)
      |> Map.put(:provider, "openai")
      |> Map.put("provider", "anthropic")

    assert {:error, {:duplicate_fields, ["provider"]}} = ProviderUsageEvent.new(mixed_map)
  end

  test "rejects same-key duplicates and malformed numbers" do
    assert {:error, {:duplicate_fields, ["provider"]}} =
             ProviderUsageEvent.new([
               {:provider, "openai"},
               {:provider, "anthropic"} | keyword_valid()
             ])

    assert {:error, {:invalid_field, "occurred_at"}} =
             ProviderUsageEvent.new(Map.put(@valid, :occurred_at, "not-a-timestamp"))

    for field <- [:input_tokens, :output_tokens, :total_tokens, :cached_tokens] do
      assert {:error, {:invalid_field, _}} = ProviderUsageEvent.new(Map.put(@valid, field, -1))
      assert {:error, {:invalid_field, _}} = ProviderUsageEvent.new(Map.put(@valid, field, 1.5))
    end

    for field <- [:marginal_api_cost_usd, :subscription_usage_units] do
      assert {:error, {:invalid_field, _}} = ProviderUsageEvent.new(Map.put(@valid, field, -0.01))
      assert {:error, {:invalid_field, _}} = ProviderUsageEvent.new(Map.put(@valid, field, "NaN"))
    end
  end

  test "token bound 1_000_000_000 is accepted when invariants hold and +1 is rejected" do
    # input at exact bound
    assert {:ok, event} =
             ProviderUsageEvent.new(%{
               @valid
               | input_tokens: @max_token_count,
                 output_tokens: 0,
                 total_tokens: @max_token_count,
                 cached_tokens: 0
             })

    assert event.input_tokens == @max_token_count

    # output at exact bound
    assert {:ok, event} =
             ProviderUsageEvent.new(%{
               @valid
               | input_tokens: 0,
                 output_tokens: @max_token_count,
                 total_tokens: @max_token_count,
                 cached_tokens: 0
             })

    assert event.output_tokens == @max_token_count

    # total at exact bound (above input+output)
    assert {:ok, event} =
             ProviderUsageEvent.new(%{
               @valid
               | input_tokens: 0,
                 output_tokens: 0,
                 total_tokens: @max_token_count,
                 cached_tokens: 0
             })

    assert event.total_tokens == @max_token_count

    # cached at exact bound, equal to input
    assert {:ok, event} =
             ProviderUsageEvent.new(%{
               @valid
               | input_tokens: @max_token_count,
                 output_tokens: 0,
                 total_tokens: @max_token_count,
                 cached_tokens: @max_token_count
             })

    assert event.cached_tokens == @max_token_count

    for field <- [:input_tokens, :output_tokens, :total_tokens, :cached_tokens] do
      over =
        case field do
          :input_tokens ->
            %{
              @valid
              | input_tokens: @max_token_count + 1,
                output_tokens: 0,
                total_tokens: @max_token_count + 1,
                cached_tokens: 0
            }

          :output_tokens ->
            %{
              @valid
              | input_tokens: 0,
                output_tokens: @max_token_count + 1,
                total_tokens: @max_token_count + 1,
                cached_tokens: 0
            }

          :total_tokens ->
            %{
              @valid
              | input_tokens: 0,
                output_tokens: 0,
                total_tokens: @max_token_count + 1,
                cached_tokens: 0
            }

          :cached_tokens ->
            %{
              @valid
              | input_tokens: @max_token_count,
                output_tokens: 0,
                total_tokens: @max_token_count,
                cached_tokens: @max_token_count + 1
            }
        end

      assert {:error, {:invalid_field, name}} = ProviderUsageEvent.new(over)
      assert name == Atom.to_string(field)
    end
  end

  test "shared number bound 1.0e18 is accepted and above-bound rejected for both cost dimensions" do
    for field <- [:marginal_api_cost_usd, :subscription_usage_units] do
      assert {:ok, event} = ProviderUsageEvent.new(Map.put(@valid, field, @max_number))
      assert Map.fetch!(Map.from_struct(event), field) == @max_number

      assert {:error, {:invalid_field, name}} =
               ProviderUsageEvent.new(Map.put(@valid, field, 1.0e19))

      assert name == Atom.to_string(field)

      assert {:error, {:invalid_field, ^name}} =
               ProviderUsageEvent.new(Map.put(@valid, field, 1_000_000_000_000_000_001))
    end
  end

  test "event_id 64 bytes and ordinary identifiers 512 bytes accept exact bound and reject +1" do
    exact_event_id = String.duplicate("e", @max_event_id_bytes)
    assert {:ok, event} = ProviderUsageEvent.new(Map.put(@valid, :event_id, exact_event_id))
    assert event.event_id == exact_event_id

    assert {:error, {:invalid_field, "event_id"}} =
             ProviderUsageEvent.new(
               Map.put(@valid, :event_id, String.duplicate("e", @max_event_id_bytes + 1))
             )

    for field <- [
          :provider,
          :account_id,
          :source,
          :model_id,
          :principal_id,
          :task_id,
          :goal_id,
          :correlation_id
        ] do
      exact = String.duplicate("x", @max_identifier_bytes)
      assert {:ok, event} = ProviderUsageEvent.new(Map.put(@valid, field, exact))
      assert Map.fetch!(Map.from_struct(event), field) == exact

      assert {:error, {:invalid_field, name}} =
               ProviderUsageEvent.new(
                 Map.put(@valid, field, String.duplicate("x", @max_identifier_bytes + 1))
               )

      assert name == Atom.to_string(field)
    end
  end

  test "rejects cached tokens above input and total below input plus output" do
    assert {:error, {:invalid_field, "cached_tokens"}} =
             ProviderUsageEvent.new(Map.put(@valid, :cached_tokens, 1_001))

    assert {:error, {:invalid_field, "total_tokens"}} =
             ProviderUsageEvent.new(Map.put(@valid, :total_tokens, 1_249))

    assert {:ok, _} = ProviderUsageEvent.new(Map.put(@valid, :total_tokens, 2_000))
    assert {:ok, _} = ProviderUsageEvent.new(Map.put(@valid, :cached_tokens, 1_000))
  end

  test "rejects closed-object authority fields and hostile terms" do
    for key <- [
          "access_token",
          "refresh_token",
          "token_hash",
          "argv",
          "env",
          "capabilities",
          "callback",
          "authority"
        ] do
      assert {:error, {:unknown_fields, [^key]}} =
               ProviderUsageEvent.new(Map.put(@valid, key, "secret"))
    end

    for value <- [self(), fn -> :term end, {:bad, :term}, %{nested: :term}, [1 | :improper]] do
      refute ProviderUsageEvent.valid?(Map.put(@valid, :model_id, value))
      assert {:error, _} = ProviderUsageEvent.canonical_bytes(Map.put(@valid, :model_id, value))
    end
  end

  test "canonical bytes and digest are exact and stable across atom and string keys" do
    string_keyed = Enum.into(@valid, %{}, fn {k, v} -> {Atom.to_string(k), v} end)

    assert {:ok, first_bytes} = ProviderUsageEvent.canonical_bytes(@valid)
    assert {:ok, second_bytes} = ProviderUsageEvent.canonical_bytes(string_keyed)
    assert first_bytes == second_bytes
    assert first_bytes == @canonical_bytes

    expected_digest =
      "sha256:" <> Base.encode16(:crypto.hash(:sha256, @canonical_bytes), case: :lower)

    assert {:ok, digest} = ProviderUsageEvent.digest(@valid)
    assert digest == expected_digest
    assert {:ok, ^digest} = ProviderUsageEvent.digest(string_keyed)
  end

  test "JSON encode/decode preserves canonical bytes and digest exactly" do
    assert {:ok, map} = ProviderUsageEvent.normalize(@valid)
    assert Map.keys(map) |> Enum.all?(&is_binary/1)
    assert ProviderUsageEvent.valid?(map)

    encoded = Jason.encode!(map)
    decoded_map = Jason.decode!(encoded)
    assert decoded_map == map

    assert {:ok, decoded} = ProviderUsageEvent.new(decoded_map)
    assert ProviderUsageEvent.to_map(decoded) == map

    assert {:ok, bytes_before} = ProviderUsageEvent.canonical_bytes(@valid)
    assert {:ok, bytes_after} = ProviderUsageEvent.canonical_bytes(decoded_map)
    assert bytes_before == bytes_after
    assert bytes_after == @canonical_bytes

    assert {:ok, digest_before} = ProviderUsageEvent.digest(@valid)
    assert {:ok, digest_after} = ProviderUsageEvent.digest(decoded_map)
    assert digest_before == digest_after

    assert digest_after ==
             "sha256:" <> Base.encode16(:crypto.hash(:sha256, @canonical_bytes), case: :lower)
  end

  defp keyword_valid do
    [
      event_id: "usage-evt-1",
      source: "req_llm",
      model_id: "gpt-5",
      operation: :complete,
      occurred_at: "2026-07-22T17:00:00-05:00",
      input_tokens: 1_000,
      output_tokens: 250,
      total_tokens: 1_250,
      cached_tokens: 100
    ]
  end
end
