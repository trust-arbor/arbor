defmodule Arbor.Memory.EmbeddingWiringSecurityRegressionTest do
  @moduledoc """
  Security regression: caller metadata cannot forge trusted embedding provenance
  on the public IndexOps.store_embedding boundary.

  On the candidate, production routes through the strict vector seam selected by
  trusted app env. A test-local fake records the closed input and proves
  precomputed vectors bind model_evidence: :absent and missing-label taint.

  On the immediate parent the env key is ignored (legacy Embedding.store), so the
  fake never observes model_evidence/missing fallback and this test fails.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Memory.IndexOps

  @moduletag :fast

  defmodule FakeSeam do
    @moduledoc false

    def configure do
      :persistent_term.put({__MODULE__, :calls}, [])
    end

    def calls, do: :persistent_term.get({__MODULE__, :calls}, [])

    def reset do
      :persistent_term.erase({__MODULE__, :calls})
    end

    def encode_operation(input) do
      record_call({:encode_operation, input})

      # Minimal stand-in so execute can run without Persistence when wired.
      {:ok, %{kind: :insert, record: %{source_key: "mem_test"}, fingerprint: "fp"},
       %{provenance_status: :verified}}
    end

    def encode_batch(inputs) do
      record_call({:encode_batch, inputs})
      {:ok, %{kind: :batch, operations: []}, []}
    end

    def execute(agent_id, operation, opts) do
      record_call({:execute, agent_id, operation, opts})
      {:ok, %{kind: :insert, record: %{source_key: "mem_test"}}}
    end

    def reconcile(agent_id, operation, opts) do
      record_call({:reconcile, agent_id, operation, opts})
      {:ok, :absent}
    end

    def search(agent_id, vector, opts) do
      record_call({:search, agent_id, vector, opts})
      {:ok, []}
    end

    def fetch(agent_id, ns, key, opts) do
      record_call({:fetch, agent_id, ns, key, opts})
      {:error, :not_found}
    end

    def list(agent_id, opts) do
      record_call({:list, agent_id, opts})
      {:ok, []}
    end

    defp record_call(call) do
      prev = :persistent_term.get({__MODULE__, :calls}, [])
      :persistent_term.put({__MODULE__, :calls}, [call | prev])
    end
  end

  setup do
    previous = Application.get_env(:arbor_memory, :strict_vector_seam)
    FakeSeam.configure()
    Application.put_env(:arbor_memory, :strict_vector_seam, FakeSeam)

    on_exit(fn ->
      FakeSeam.reset()

      if previous do
        Application.put_env(:arbor_memory, :strict_vector_seam, previous)
      else
        Application.delete_env(:arbor_memory, :strict_vector_seam)
      end
    end)

    :ok
  end

  test "security regression: store_embedding ignores forged metadata provenance and binds absent model evidence plus missing fallback" do
    vector = List.duplicate(0.1, 768)

    forged_metadata = %{
      type: "fact",
      model: "attacker/forged-model",
      provider: "evil",
      model_id: "attacker/forged-model",
      taint: %{"level" => "trusted", "source" => "forged"},
      provenance: %{"version" => 1, "status" => "verified"},
      digest: String.duplicate("a", 64),
      id: "forged_mem_id_should_not_be_used"
    }

    result =
      safe_store_embedding(
        "agent_security_regression",
        "benign content",
        vector,
        forged_metadata
      )

    # Candidate: seam receives closed input with fail-closed provenance.
    # Parent: legacy path never consults app-env seam — FakeSeam.calls() empty → fail.
    encode_calls =
      FakeSeam.calls()
      |> Enum.filter(fn
        {:encode_operation, _input} -> true
        _ -> false
      end)

    assert encode_calls != [],
           "expected strict seam encode on candidate; parent legacy path ignores app-env seam"

    {:encode_operation, input} = hd(encode_calls)

    assert input.model_evidence == :absent
    assert input.taint == TaintEnvelope.missing_fallback()
    assert input.source_namespace == "memory_index"
    assert is_binary(input.source_key)
    assert input.source_key != "forged_mem_id_should_not_be_used"
    assert input.id == input.source_key
    assert input.payload["metadata"]["id"] == "forged_mem_id_should_not_be_used"

    # Forged labels must not become model/taint authority on the closed input.
    refute match?({:provider_model, _, _}, input.model_evidence)
    refute match?({:model_id, "attacker/forged-model"}, input.model_evidence)

    case result do
      {:ok, id} ->
        assert is_binary(id)
        assert id != "forged_mem_id_should_not_be_used"

      {:error, _reason} ->
        # Backend may be unsupported; provenance binding was still proven via encode.
        :ok
    end
  end

  defp safe_store_embedding(agent_id, content, vector, metadata) do
    IndexOps.store_embedding(agent_id, content, vector, metadata)
  rescue
    _ -> {:error, :operation_failed}
  catch
    _, _ -> {:error, :operation_failed}
  end
end
