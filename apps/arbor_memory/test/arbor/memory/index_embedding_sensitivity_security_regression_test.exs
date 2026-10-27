defmodule Arbor.Memory.IndexEmbeddingSensitivitySecurityRegressionTest do
  @moduledoc """
  Security regression: semantic indexing preserves recorded sensitivity at its
  outbound embedding-provider boundary.

  Exercises the public Memory facade and real Index/ETS implementation. Only
  the embedding provider is injected to record its inputs; these assertions
  prove propagation of source-owned labels, not the provider's policy gate.
  The LLM security regressions separately exercise production egress admission.
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.VectorRecord
  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory
  alias Arbor.Memory.IndexSupervisor

  @moduletag :fast

  defmodule CapturingEmbeddingProvider do
    @moduledoc false

    # Keep embed/1 so the vulnerable implementation reaches the provider and
    # returns successfully; the regression fails on lost options, not a missing
    # function. The repaired implementation can pass source labels via embed/2.
    def embed(content), do: embed(content, [])

    def embed(content, opts) do
      [{:observer, observer}] = :ets.lookup(__MODULE__, :observer)
      send(observer, {:embedding_input, content, opts})

      {:ok,
       %{
         embedding: [1.0 | List.duplicate(0.0, VectorRecord.dimensions() - 1)],
         dimensions: VectorRecord.dimensions(),
         model: "sensitivity-capture",
         provider: :test,
         usage: %{prompt_tokens: 1, total_tokens: 1}
       }}
    end
  end

  setup do
    :ets.new(CapturingEmbeddingProvider, [:named_table, :protected, :set])
    :ets.insert(CapturingEmbeddingProvider, {:observer, self()})

    agent = "embedding_sensitivity_#{System.unique_integer([:positive])}"

    assert {:ok, _index} =
             Memory.init_for_agent(agent,
               graph_enabled: false,
               backend: :ets,
               embedding_provider: CapturingEmbeddingProvider
             )

    on_exit(fn -> IndexSupervisor.stop_index(agent) end)

    %{agent: agent, taint: restricted_taint()}
  end

  test "security regression: indexing forwards recorded restricted taint before embedding", %{
    agent: agent,
    taint: taint
  } do
    content = "The internal project milestone is ready for review."

    assert {:ok, _entry_id} = Memory.index(agent, content, %{type: :fact}, taint: taint)

    assert_receive {:embedding_input, ^content, opts}
    assert Keyword.get(opts, :taint) == taint
    assert Keyword.get(opts, :agent_id) == agent
  end

  test "security regression: batch indexing forwards restricted taint for every embedding", %{
    agent: agent,
    taint: taint
  } do
    first = "The first unreleased project milestone is complete."
    second = "The second unreleased project milestone is under review."

    assert {:ok, [_first_id, _second_id]} =
             Memory.batch_index(agent, [{first, %{}}, {second, %{}}], taint: taint)

    for content <- [first, second] do
      assert_receive {:embedding_input, ^content, opts}
      assert Keyword.get(opts, :taint) == taint
      assert Keyword.get(opts, :agent_id) == agent
    end
  end

  test "security regression: recall forwards the query's restricted taint before embedding", %{
    agent: agent,
    taint: taint
  } do
    query = "Which unreleased project milestone is ready?"

    assert {:ok, _entry_id} =
             Memory.index(agent, "A milestone is ready.", %{}, taint: taint)

    assert_receive {:embedding_input, "A milestone is ready.", _seed_opts}

    assert {:ok, [_match]} = Memory.recall(agent, query, taint: taint)

    assert_receive {:embedding_input, ^query, opts}
    assert Keyword.get(opts, :taint) == taint
    assert Keyword.get(opts, :agent_id) == agent
  end

  defp restricted_taint do
    %Taint{
      level: :derived,
      sensitivity: :restricted,
      confidence: :verified,
      sanitizations: 0,
      source: "private-memory",
      chain: ["source:private-memory", "memory:index"]
    }
  end
end
