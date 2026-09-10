Code.require_file(
  Path.expand("../../../../arbor_security/test/support/oidc_test_helper.ex", __DIR__)
)

defmodule Arbor.Memory.PrivateConversationSecurityRegressionTest do
  @moduledoc """
  Private Memory feature acceptance through the public facade. Admissions use
  real signed human receipts and Security's exact-caller broker. The test-owned
  stamp adapter uses a dedicated Ed25519 root because the standard test Security
  root is ephemeral; Security's own suite tests persisted-root admission/signing.
  Storage uses real strict records and receipts, reconstructed from JSON on reads.

  The reserved-marker downgrade case is feature hardening, not evidence of a
  historical private producer. M1a/M1b1 retain their original bug regressions.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.VectorRecord
  alias Arbor.Contracts.Security.{Identity, SignedRequest}
  alias Arbor.Memory
  alias Arbor.Memory.{Embedding, Index, IndexSupervisor, Retrieval}
  alias Arbor.Security

  @moduletag :fast
  @moduletag :integration

  defmodule StampAuthority do
    use Agent

    alias Arbor.Contracts.Persistence.VectorRecord

    def start_link(_opts),
      do: Agent.start_link(fn -> :crypto.generate_key(:eddsa, :ed25519) end, name: __MODULE__)

    def authorize_private_memory_turn(token, operation),
      do: Arbor.Security.authorize_private_memory_turn(token, operation)

    def attest_private_memory_record(token, descriptor) do
      with {:ok, scope} <- authorize_private_memory_turn(token, :write),
           true <-
             Enum.all?([:agent_id, :human_id, :engagement_id, :session_id, :turn_id], fn key ->
               descriptor[Atom.to_string(key)] == scope[key]
             end),
           {:ok, bytes} <- VectorRecord.canonical_payload_bytes(descriptor),
           {:ok, digest} <- VectorRecord.payload_digest(descriptor) do
        {_public, private} = Agent.get(__MODULE__, & &1)
        signature = :crypto.sign(:eddsa, :none, bytes, [private, :ed25519])

        {:ok,
         %{
           "version" => 1,
           "issuer_id" => "memory_test_root",
           "descriptor_digest" => digest,
           "signature" => Base.encode64(signature)
         }}
      else
        _ -> {:error, :invalid_private_memory_attestation}
      end
    end

    def verify_private_memory_record(descriptor, stamp) do
      {public, _private} = Agent.get(__MODULE__, & &1)

      with %{
             "version" => 1,
             "issuer_id" => "memory_test_root",
             "descriptor_digest" => digest,
             "signature" => encoded
           } <- stamp,
           true <- map_size(stamp) == 4,
           {:ok, ^digest} <- VectorRecord.payload_digest(descriptor),
           {:ok, bytes} <- VectorRecord.canonical_payload_bytes(descriptor),
           {:ok, signature} <- Base.decode64(encoded),
           true <- :crypto.verify(:eddsa, :none, bytes, signature, [public, :ed25519]) do
        :ok
      else
        _ -> {:error, :invalid_private_memory_attestation}
      end
    end
  end

  defmodule StrictSeam do
    use Agent

    alias Arbor.Contracts.Persistence.{VectorReceipt, VectorRecord}
    alias Arbor.Memory.Embedding

    def start_link(observer) do
      Agent.start_link(
        fn ->
          %{
            records: %{},
            receipts: %{},
            calls: [],
            observer: observer,
            search_error: :unsupported,
            search_override: nil,
            list_override: nil,
            indeterminate: false
          }
        end,
        name: __MODULE__
      )
    end

    def configure(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))
    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    def records, do: Agent.get(__MODULE__, & &1.records)
    def observer, do: Agent.get(__MODULE__, & &1.observer)
    def put(record), do: Agent.update(__MODULE__, &put_in(&1, [:records, record.id], record))
    def encode_operation(input), do: Embedding.encode_strict_operation(input)
    def encode_batch(inputs), do: Embedding.encode_strict_batch(inputs)

    def execute(agent, operation, _opts) do
      note({:execute, agent, operation.fingerprint})

      {:ok, record} =
        operation.record
        |> Map.from_struct()
        |> Map.merge(%{generation: 1, revision: 1})
        |> VectorRecord.new()

      {:ok, receipt} = VectorReceipt.new(%{operation: operation, record: record})

      Agent.get_and_update(__MODULE__, fn state ->
        if Map.has_key?(state.records, record.id) do
          {{:error, :conflict}, state}
        else
          reply = if state.indeterminate, do: {:error, :indeterminate}, else: {:ok, receipt}

          {reply,
           %{
             state
             | records: Map.put(state.records, record.id, record),
               receipts: Map.put(state.receipts, operation.fingerprint, receipt)
           }}
        end
      end)
    end

    def reconcile(agent, operation, _opts) do
      note({:reconcile, agent, operation.fingerprint})
      {:ok, Agent.get(__MODULE__, &Map.get(&1.receipts, operation.fingerprint, :absent))}
    end

    def fetch(agent, namespace, key, _opts) do
      note({:fetch, agent, namespace, key})

      case Enum.find(
             Map.values(records()),
             &(&1.agent_id == agent and &1.source_namespace == namespace and &1.source_key == key)
           ) do
        nil -> {:error, :not_found}
        record -> decode(record)
      end
    end

    def list(agent, opts) do
      note({:list, agent, opts})
      override = Agent.get(__MODULE__, & &1.list_override)
      if is_nil(override), do: {:ok, matching(agent, opts)}, else: {:ok, override}
    end

    def search(agent, _vector, opts) do
      note({:search, agent, opts})
      state = Agent.get(__MODULE__, & &1)

      cond do
        state.search_error -> {:error, state.search_error}
        state.search_override -> {:ok, state.search_override}
        true -> {:ok, Enum.map(matching(agent, opts), &%{match: &1, similarity: 1.0})}
      end
    end

    defp matching(agent, opts) do
      records()
      |> Map.values()
      |> Enum.filter(fn row ->
        row.agent_id == agent and row.source_namespace == Keyword.fetch!(opts, :source_namespace) and
          (is_nil(opts[:model_id]) or row.model_id == opts[:model_id]) and
          (is_nil(opts[:category]) or row.category == opts[:category])
      end)
      |> Enum.sort_by(& &1.id)
      |> Enum.take(Keyword.get(opts, :limit, 1_000))
      |> Enum.map(fn row ->
        {:ok, view} = decode(row)
        view
      end)
    end

    defp decode(record) do
      with {:ok, reconstructed} <-
             record |> Jason.encode!() |> Jason.decode!() |> VectorRecord.new(),
           do: Embedding.decode_strict_record(reconstructed)
    end

    defp note(call), do: Agent.update(__MODULE__, &%{&1 | calls: [call | &1.calls]})
  end

  defmodule ObservingProvider do
    def embed(text) do
      send(StrictSeam.observer(), {:embedding_provider_called, text})
      {:error, :provider_must_not_receive_private_text}
    end
  end

  setup do
    start_supervised!(StampAuthority)
    start_supervised!({StrictSeam, self()})
    set_env(:arbor_memory, :strict_vector_seam, StrictSeam)
    set_env(:arbor_memory, :private_memory_security, StampAuthority)
    owner = pair()
    {:ok, owner: owner, admission: admission(owner)}
  end

  test "private recall isolates the human/agent pair and reconstructs cold rows after admission closure",
       ctx do
    assert {:ok, id} = write(ctx.admission, "private owner pair", "source-1")
    other_human = pair(ctx.owner.agent_id)
    other_agent = pair(nil, ctx.owner.human)

    assert {:ok, []} =
             Memory.recall_private_conversations(admission(other_human), embedding(), [])

    assert {:ok, []} =
             Memory.recall_private_conversations(admission(other_agent), embedding(), [])

    assert :ok = Security.close_private_memory_admission(ctx.admission)
    assert {:error, _} = Memory.recall_private_conversations(ctx.admission, embedding(), [])

    fresh = admission(ctx.owner, "engagement-later", "session-later")

    assert {:ok, [%{id: ^id, content: "private owner pair"}]} =
             Memory.recall_private_conversations(fresh, embedding(), [])

    refute_receive {:embedding_provider_called, _}
  end

  test "public Memory assembles real system-root attestation and recalls after signing-store and root restart",
       ctx do
    fixture_root = persistent_root!()
    Application.put_env(:arbor_memory, :private_memory_security, Security)

    assert {:ok, id} =
             write(ctx.admission, "persisted root owner-positive content", "actual-root")

    original = StrictSeam.records()[id]
    assert is_binary(original.payload["body"]["owner_stamp"]["signature"])
    assert :ok = Security.close_private_memory_admission(ctx.admission)

    # The root is reloaded from its encrypted JSONFile bundle, while the strict
    # seam reconstructs the row from JSON. No original admission or cache entry
    # participates in the read; a later engagement uses a fresh real receipt.
    replace_root_store!(fixture_root)
    restart_root!()
    fresh = admission(ctx.owner, "engagement-after-root-restart")

    assert {:ok, [%{id: ^id, content: "persisted root owner-positive content"}]} =
             Memory.recall_private_conversations(fresh, embedding(), [])

    assert StrictSeam.records()[id] == original
  end

  test "SQLite fallback ranks the owner partition by cosine before threshold and limit", ctx do
    assert {:ok, _low} =
             Memory.index_private_conversation(
               ctx.admission,
               "orthogonal own row",
               embedding(vector: other_vector()),
               source_id: "low"
             )

    assert {:ok, high} = write(ctx.admission, "matching own row", "high")
    other = pair(ctx.owner.agent_id)
    assert {:ok, _foreign} = write(admission(other), "matching other human", "foreign")

    assert {:ok, [%{id: ^high, similarity: similarity}]} =
             Memory.recall_private_conversations(ctx.admission, embedding(),
               threshold: 0.9,
               limit: 1
             )

    assert_in_delta similarity, 1.0, 0.000001
  end

  test "signed transcript source survives root restart and preserves original provenance during later indexing",
       ctx do
    fixture_root = persistent_root!()
    Application.put_env(:arbor_memory, :private_memory_security, Security)

    assert {:ok, source} =
             Memory.prepare_private_conversation_source(
               ctx.admission,
               %{user: "Remember the violet observatory", assistant: "The observatory is violet."}
             )

    assert :ok = Security.verify_private_memory_source(source["descriptor"], source["stamp"])
    assert StrictSeam.records() == %{}

    assert {:ok, {:pending, content}} =
             Memory.prepare_private_conversation_index(ctx.admission, source)

    assert content ==
             "User: Remember the violet observatory\nAssistant: The observatory is violet."

    original_scope =
      Map.take(source["descriptor"], ~w(agent_id human_id engagement_id session_id turn_id))

    durable_source = source |> Jason.encode!() |> Jason.decode!()
    assert :ok = Security.close_private_memory_admission(ctx.admission)

    replace_root_store!(fixture_root)
    restart_root!()
    fresh = admission(ctx.owner, "engagement-new", "session-new")

    assert {:ok, {:pending, ^content}} =
             Memory.prepare_private_conversation_index(fresh, durable_source)

    assert {:ok, id} =
             Memory.index_private_conversation_source(fresh, durable_source, embedding())

    row = StrictSeam.records()[id]
    assert row.payload["body"]["conversation_scope"] == original_scope

    assert {:ok, {:indexed, ^id}} =
             Memory.prepare_private_conversation_index(fresh, durable_source)

    assert {:ok, ^id} =
             Memory.index_private_conversation_source(fresh, durable_source, embedding())

    assert StrictSeam.records()[id] == row

    assert {:ok, [%{id: ^id, content: ^content}]} =
             Memory.recall_private_conversations(fresh, embedding())

    refute_receive {:embedding_provider_called, _}
  end

  test "signed source rejects foreign pairs, copied admissions, changed content and forged scope before storage",
       ctx do
    persistent_root!()
    Application.put_env(:arbor_memory, :private_memory_security, Security)

    assert {:ok, source} =
             Memory.prepare_private_conversation_source(
               ctx.admission,
               %{user: "Original private text", assistant: "Original answer"}
             )

    baseline_calls = StrictSeam.calls()
    other_human = pair(ctx.owner.agent_id)
    other_agent = pair(nil, ctx.owner.human)

    for token <- [admission(other_human), admission(other_agent)] do
      assert {:error, :private_memory_source_owner_mismatch} =
               Memory.prepare_private_conversation_index(token, source)

      assert {:error, :private_memory_source_owner_mismatch} =
               Memory.index_private_conversation_source(token, source, embedding())
    end

    assert {:error, _} =
             Task.async(fn ->
               Memory.prepare_private_conversation_index(ctx.admission, source)
             end)
             |> Task.await()

    for changed <- [
          Map.put(source, "assistant_content", "Tampered answer"),
          put_in(source, ["descriptor", "human_id"], other_human.human.id),
          put_in(source, ["stamp", "signature"], Base.encode64(<<0::512>>)),
          Map.put(source, "owner", ctx.owner.human.id)
        ] do
      assert {:error, _} = Memory.prepare_private_conversation_index(ctx.admission, changed)

      assert {:error, _} =
               Memory.index_private_conversation_source(ctx.admission, changed, embedding())
    end

    assert StrictSeam.calls() == baseline_calls
    assert StrictSeam.records() == %{}
  end

  test "source presence checks verify durable row content and root stamp before claiming indexed",
       ctx do
    persistent_root!()
    Application.put_env(:arbor_memory, :private_memory_security, Security)

    assert {:ok, source} =
             Memory.prepare_private_conversation_source(
               ctx.admission,
               %{user: "Stored source", assistant: "Stored response"}
             )

    assert {:ok, id} =
             Memory.index_private_conversation_source(ctx.admission, source, embedding())

    original = StrictSeam.records()[id]
    forged_body = Map.put(original.payload["body"], "content", "Rehashed forged row")
    StrictSeam.put(reencode(original, %{payload: forged_body}))
    assert {:error, _} = Memory.prepare_private_conversation_index(ctx.admission, source)

    assert {:error, _} =
             Memory.index_private_conversation_source(ctx.admission, source, embedding())

    assert {:error, _} = Memory.recall_private_conversations(ctx.admission, embedding())
    assert map_size(StrictSeam.records()) == 1
  end

  test "same-source replay preserves first sealed provenance across fresh turns; conflicting content or vectors reject",
       ctx do
    assert {:ok, id} = write(ctx.admission, "acknowledged pair", "stable-source")
    original = StrictSeam.records()[id]

    assert original.payload["body"]["conversation_scope"]["session_id"] ==
             "session-private-memory"

    assert :ok = Security.close_private_memory_admission(ctx.admission)
    fresh = admission(ctx.owner, "engagement-new", "session-new")
    assert {:ok, ^id} = write(fresh, "acknowledged pair", "stable-source")
    assert StrictSeam.records()[id] == original

    assert {:error, :private_memory_source_conflict} =
             write(fresh, "different pair", "stable-source")

    assert {:error, :private_memory_source_conflict} =
             Memory.index_private_conversation(
               fresh,
               "acknowledged pair",
               embedding(vector: other_vector()),
               source_id: "stable-source"
             )

    assert Enum.count(StrictSeam.calls(), &match?({:execute, _, _}, &1)) == 1
  end

  test "strict committed receipt reconciliation preserves one immutable operation", ctx do
    StrictSeam.configure(:indeterminate, true)
    assert {:ok, id} = write(ctx.admission, "acknowledged once", "reconciled")

    assert [{:execute, _, fingerprint}] =
             Enum.filter(StrictSeam.calls(), &match?({:execute, _, _}, &1))

    assert [{:reconcile, _, ^fingerprint}] =
             Enum.filter(StrictSeam.calls(), &match?({:reconcile, _, _}, &1))

    assert %{generation: 1, revision: 1} = StrictSeam.records()[id]
  end

  test "copied or fabricated admission and missing ordinary capability reject before storage",
       ctx do
    before = StrictSeam.calls()

    task =
      Task.async(fn -> Memory.recall_private_conversations(ctx.admission, embedding(), []) end)

    assert {:error, _} = Task.await(task)

    assert {:error, _} =
             Memory.recall_private_conversations(
               %{agent_id: ctx.owner.agent_id, human_id: ctx.owner.human.id},
               embedding(),
               []
             )

    assert StrictSeam.calls() == before

    assert :ok = Security.revoke(ctx.owner.write_cap.id)
    assert {:error, _} = write(ctx.admission, "must not persist", "denied")
    assert StrictSeam.calls() == before
    assert StrictSeam.records() == %{}
  end

  test "malformed options and incomplete precomputed results cannot choose scope or invoke providers",
       ctx do
    start_index(ctx.owner.agent_id)
    before = StrictSeam.calls()

    for opts <- [
          [source_id: "s", owner: "other"],
          [source_id: "s", source_id: "s"],
          [{"source_id", "s"}],
          [source_id: "s", metadata: %{human_id: "other"}],
          [source_id: "s", strict_vector_seam: StrictSeam],
          [{:source_id, "s"} | :malformed]
        ] do
      assert {:error, :invalid_private_memory_options} =
               Memory.index_private_conversation(ctx.admission, "secret", embedding(), opts)
    end

    for opts <- [
          [human_id: "other"],
          [source_namespace: "other"],
          [embedding_provider: ObservingProvider],
          [limit: 0],
          [limit: 1, limit: 2],
          [{"limit", 1}],
          [{:limit, 1} | :malformed]
        ] do
      assert {:error, :invalid_private_memory_options} =
               Memory.recall_private_conversations(ctx.admission, embedding(), opts)
    end

    for result <- [
          vector(),
          Map.delete(embedding(), :model),
          Map.put(embedding(), :owner, "other"),
          %{embedding() | dimensions: 1},
          embedding(vector: List.duplicate(0.0, 768))
        ] do
      assert {:error, _} =
               Memory.index_private_conversation(ctx.admission, "secret", result, source_id: "s")

      assert {:error, _} = Memory.recall_private_conversations(ctx.admission, result, [])
    end

    assert StrictSeam.calls() == before
    refute_receive {:embedding_provider_called, _}
  end

  test "rehashing body or vector cannot forge the persisted owner attestation", ctx do
    assert {:ok, id} = write(ctx.admission, "sealed content", "sealed")
    original = StrictSeam.records()[id]

    for change <- [
          %{payload: Map.put(original.payload["body"], "content", "forged content")},
          %{vector: other_vector()},
          %{model_evidence: {:model_id, "local/forged"}}
        ] do
      forged = reencode(original, change)
      StrictSeam.put(forged)
      assert {:error, _} = Memory.recall_private_conversations(ctx.admission, embedding(), [])
      StrictSeam.put(original)
    end
  end

  test "copying another human's stamp onto a correctly partitioned rehashed row is rejected",
       ctx do
    assert {:ok, original_id} = write(ctx.admission, "human A secret", "a")
    other = pair(ctx.owner.agent_id)
    other_admission = admission(other)
    assert {:ok, target_id} = write(other_admission, "human B content", "b")
    original = StrictSeam.records()[original_id]
    target = StrictSeam.records()[target_id]

    forged_body =
      target.payload["body"]
      |> Map.put("content", original.payload["body"]["content"])
      |> Map.put("owner_stamp", original.payload["body"]["owner_stamp"])

    StrictSeam.put(reencode(target, %{payload: forged_body}))
    assert {:error, _} = Memory.recall_private_conversations(other_admission, embedding(), [])
  end

  test "ANN validates the complete returned set before limit and never falls back after malformed records",
       ctx do
    assert {:ok, id} = write(ctx.admission, "valid", "set")
    {:ok, view} = Embedding.decode_strict_record(StrictSeam.records()[id])
    StrictSeam.configure(:search_error, nil)

    StrictSeam.configure(:search_override, [
      %{match: view, similarity: 1.0},
      %{match: %{view | generation: 2}, similarity: -1.0}
    ])

    assert {:error, _} =
             Memory.recall_private_conversations(ctx.admission, embedding(),
               limit: 1,
               threshold: 0.9
             )

    refute Enum.any?(StrictSeam.calls(), &match?({:list, _, _}, &1))
  end

  test "local fallback verifies every row before model filtering and ranking", ctx do
    assert {:ok, id} = write(ctx.admission, "valid", "local-set")
    {:ok, view} = Embedding.decode_strict_record(StrictSeam.records()[id])
    StrictSeam.configure(:list_override, [view, %{view | model_id: "another/model"}])
    assert {:error, _} = Memory.recall_private_conversations(ctx.admission, embedding(), limit: 1)
    assert Enum.any?(StrictSeam.calls(), &match?({:list, _, _}, &1))
  end

  test "existing general readers never use caller-supplied owner or private namespace selectors",
       ctx do
    assert {:ok, id} = write(ctx.admission, "private selector sentinel", "selectors")
    private_namespace = StrictSeam.records()[id].source_namespace
    pid = start_index(ctx.owner.agent_id)
    StrictSeam.configure(:search_error, nil)

    assert {:error, _} =
             Memory.recall(ctx.owner.agent_id, "query",
               embedding: vector(),
               human_id: ctx.owner.human.id
             )

    assert {:error, _} =
             Retrieval.recall(ctx.owner.agent_id, "query",
               backend: :persistent,
               embedding: vector(),
               source_namespace: private_namespace
             )

    assert {:error, :not_found} = Index.get(pid, id)

    assert {:ok, []} =
             Memory.search_embeddings(ctx.owner.agent_id, vector(),
               source_namespace: private_namespace,
               admission: ctx.admission,
               owner: ctx.owner.human.id
             )

    assert {:search, _, opts} = List.last(StrictSeam.calls())
    assert opts[:source_namespace] == "memory_index"
    refute_receive {:embedding_provider_called, _}
  end

  test "reserved private body markers remain excluded after category downgrade on general readers",
       ctx do
    assert {:ok, id} = write(ctx.admission, "private downgrade sentinel", "downgrade")
    row = StrictSeam.records()[id]
    body = Map.put(row.payload["body"], "metadata", %{"type" => "fact"})

    downgraded =
      reencode(row, %{
        id: "mem_downgraded",
        source_key: "mem_downgraded",
        source_namespace: "memory_index",
        category: "fact",
        payload: body,
        model_evidence: :absent
      })

    StrictSeam.put(downgraded)
    StrictSeam.configure(:search_error, nil)

    assert {:ok, visible} =
             Memory.store_embedding(ctx.owner.agent_id, "ordinary fact", vector(), %{type: :fact})

    assert {:ok, [%{id: ^visible}]} =
             Memory.search_embeddings(ctx.owner.agent_id, vector(), threshold: -1.0)
  end

  defp pair(agent_id \\ nil, human \\ nil) do
    agent_id = agent_id || new_agent()
    human = human || new_human()
    read_cap = grant(agent_id, "arbor://memory/read")
    write_cap = grant(agent_id, "arbor://memory/write")
    grant(human.id, "arbor://chat/agent/" <> agent_id)
    %{agent_id: agent_id, human: human, read_cap: read_cap, write_cap: write_cap}
  end

  defp new_agent do
    {:ok, identity} = Identity.generate()
    assert :ok = Security.register_identity(identity)
    on_exit(fn -> Security.deregister_identity(identity.agent_id) end)
    identity.agent_id
  end

  defp new_human do
    fixture = Arbor.Security.OIDCTestHelper.issue_identity()

    assert :ok =
             Security.register_oidc_identity(fixture.identity, fixture.id_token, fixture.provider)

    on_exit(fn ->
      fixture.cleanup.()
      Security.deregister_identity(fixture.identity.agent_id)
    end)

    %{id: fixture.identity.agent_id, private_key: fixture.identity.private_key}
  end

  defp grant(principal, resource) do
    assert {:ok, cap} = Security.grant(principal: principal, resource: resource)
    on_exit(fn -> Security.revoke(cap.id) end)
    cap
  end

  defp admission(
         owner,
         engagement \\ "engagement-original",
         session_id \\ "session-private-memory"
       ) do
    assert {:ok, signed} =
             SignedRequest.sign("authorize", owner.human.id, owner.human.private_key)

    assert {:ok, receipt} =
             Security.authorize_and_issue_delivery_receipt(
               owner.human.id,
               "arbor://chat/agent/" <> owner.agent_id,
               :chat,
               signed_request: signed
             )

    assert {:ok, admission} =
             Security.exchange_private_memory_receipt(receipt, owner.agent_id, owner.human.id, %{
               session_id: session_id,
               turn_id: "turn-#{System.unique_integer([:positive])}"
             })

    assert :ok = Security.activate_private_memory_admission(admission, engagement)
    admission
  end

  defp write(admission, content, source_id),
    do: Memory.index_private_conversation(admission, content, embedding(), source_id: source_id)

  defp embedding(opts \\ []),
    do: %{
      embedding: Keyword.get(opts, :vector, vector()),
      provider: "local",
      model: "test-embedding",
      dimensions: 768
    }

  defp vector, do: [1.0 | List.duplicate(0.0, 767)]
  defp other_vector, do: [0.0, 1.0 | List.duplicate(0.0, 766)]

  defp reencode(record, changes) do
    input = %{
      kind: :insert,
      id: record.id,
      agent_id: record.agent_id,
      source_namespace: record.source_namespace,
      source_key: record.source_key,
      payload: record.payload["body"],
      vector: record.vector,
      category: record.category,
      generation: 0,
      revision: 0,
      tombstone: false,
      expected_generation: nil,
      expected_revision: nil,
      model_evidence: {:model_id, record.model_id},
      taint: Arbor.Contracts.Security.TaintEnvelope.missing_fallback()
    }

    {:ok, operation, _view} = Embedding.encode_strict_operation(Map.merge(input, changes))

    {:ok, record} =
      operation.record
      |> Map.from_struct()
      |> Map.merge(%{generation: 1, revision: 1})
      |> VectorRecord.new()

    record
  end

  defp start_index(agent_id) do
    assert {:ok, pid} =
             IndexSupervisor.start_index(agent_id,
               backend: :ets,
               embedding_provider: ObservingProvider
             )

    on_exit(fn -> IndexSupervisor.stop_index(agent_id) end)
    pid
  end

  # This is fixture ownership of a global test service, matching Security's
  # persistence suite. It never points a store or master key at a user's tree.
  defp persistent_root! do
    root = Path.join(System.tmp_dir!(), "arbor_memory_root_#{System.unique_integer([:positive])}")
    previous_mode = Application.fetch_env(:arbor_security, :system_authority_mode)
    previous_key = Application.fetch_env(:arbor_security, :master_key_path)

    on_exit(fn ->
      restore_env(:arbor_security, :system_authority_mode, previous_mode)
      restore_env(:arbor_security, :master_key_path, previous_key)
      stop_root_store!()
      Arbor.Security.TestBootstrap.restore_supervised_tree!()

      if Path.dirname(Path.expand(root)) != Path.expand(System.tmp_dir!()) or
           not String.starts_with?(Path.basename(root), "arbor_memory_root_") do
        raise "invalid private Memory root fixture"
      end

      File.rm_rf!(root)
    end)

    Application.put_env(:arbor_security, :system_authority_mode, :persistent)
    Application.put_env(:arbor_security, :master_key_path, Path.join(root, "master.key"))
    replace_root_store!(root)
    restart_root!()
    root
  end

  defp replace_root_store!(root) do
    stop_root_store!()

    assert {:ok, pid} =
             Arbor.Security.AuthorityStore.start_link(
               name: :arbor_security_signing_keys,
               backend: Arbor.Security.Store.JSONFile,
               backend_opts: [base_dir: Path.join(root, "store")],
               namespace: "signing_keys",
               hydration_limit: 100
             )

    Process.unlink(pid)
  end

  defp stop_root_store! do
    for operation <- [:terminate_child, :delete_child] do
      case apply(Supervisor, operation, [Arbor.Security.Supervisor, :arbor_security_signing_keys]) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end
    end

    if pid = Process.whereis(:arbor_security_signing_keys), do: GenServer.stop(pid)
  end

  defp restart_root! do
    assert :ok =
             Supervisor.terminate_child(Arbor.Security.Supervisor, Arbor.Security.SystemAuthority)

    assert {:ok, _pid} =
             Supervisor.restart_child(Arbor.Security.Supervisor, Arbor.Security.SystemAuthority)
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)

  defp set_env(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)
    on_exit(fn -> restore_env(app, key, previous) end)
  end
end
