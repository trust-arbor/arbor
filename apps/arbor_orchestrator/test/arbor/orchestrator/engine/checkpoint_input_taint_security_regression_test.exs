defmodule Arbor.Orchestrator.Engine.CheckpointInputTaintSecurityRegressionTest do
  use ExUnit.Case, async: true
  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Orchestrator.Engine.{Checkpoint, Context, EffectOwner, Outcome}
  alias Arbor.Orchestrator.RunLifecycle.{EffectEnvelope, EffectRecoveryCore}

  @secret "input-taint-checkpoint-test-secret"
  @completed_at "2026-10-06T12:00:01.000000Z"
  @input_hash String.duplicate("a", 64)

  defmodule MemoryStore do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, %{}, name: Keyword.fetch!(opts, :name))

    def durability_class(_opts), do: :process_lifetime
    def put(key, value, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})
    def get(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
    @impl true
    def init(data), do: {:ok, data}
    @impl true
    def handle_call({:put, key, value}, _from, data), do: {:reply, :ok, Map.put(data, key, value)}

    def handle_call({:get, key}, _from, data) do
      reply =
        case Map.fetch(data, key) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, :not_found}
        end

      {:reply, reply, data}
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "checkpoint_input_taint_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, path: Path.join(root, "checkpoint.json")}
  end

  test "legacy receipt digest remains readable when the additive field is absent", c do
    original = %Outcome{status: :success, context_updates: %{"summary" => "old result"}}
    # This is the predecessor's actual deterministic ETF input, not a digest
    # recaptured through the candidate's compatibility function.
    legacy_digest = original |> Map.delete(:input_taint) |> raw_digest()
    {checkpoint, record} = checkpoint(original, legacy_digest)
    assert :ok = Checkpoint.write(checkpoint, c.root, store: nil, hmac_secret: @secret)
    raw = c.path |> File.read!() |> Jason.decode!()
    raw = update_in(raw, ["node_outcomes", "task"], &Map.delete(&1, "input_taint"))
    write_signed(c.path, raw)
    assert {:ok, loaded} = Checkpoint.load(c.path, store: nil, hmac_secret: @secret)
    assert Map.get(loaded.node_outcomes["task"], :input_taint, %{}) == %{}
    assert EffectOwner.outcome_result_digest(loaded.node_outcomes["task"]) == legacy_digest
    assert {:ok, :continue} = EffectRecoveryCore.decide(record, loaded)
  end

  test "security regression: classified input survives file and configured-store receipt recovery",
       c do
    outcome = classified_outcome()
    digest = EffectOwner.outcome_result_digest(outcome)
    {checkpoint, record} = checkpoint(outcome, digest)
    assert :ok = Checkpoint.write(checkpoint, c.root, store: nil, hmac_secret: @secret)
    assert {:ok, loaded} = Checkpoint.load(c.path, store: nil, hmac_secret: @secret)

    assert Map.get(loaded.node_outcomes["task"], :input_taint, %{}) ==
             Map.fetch!(outcome, :input_taint)

    assert {:ok, :continue} = EffectRecoveryCore.decide(record, loaded)

    name = :"input_taint_store_#{System.unique_integer([:positive])}"
    start_supervised!({MemoryStore, name: name})
    opts = [store: MemoryStore, store_name: name, run_id: checkpoint.run_id, hmac_secret: @secret]
    assert {:ok, _receipt} = Checkpoint.persist(checkpoint, c.root, opts)
    File.rm!(c.path)
    assert {:ok, from_store} = Checkpoint.load(c.path, opts)

    assert Map.get(from_store.node_outcomes["task"], :input_taint, %{}) ==
             Map.fetch!(outcome, :input_taint)

    assert {:ok, :continue} = EffectRecoveryCore.decide(record, from_store)
  end

  test "security regression: nonempty evidence tampering cannot match an existing receipt", c do
    outcome = classified_outcome()
    {checkpoint, record} = checkpoint(outcome, EffectOwner.outcome_result_digest(outcome))
    assert :ok = Checkpoint.write(checkpoint, c.root, store: nil, hmac_secret: @secret)
    raw = c.path |> File.read!() |> Jason.decode!()

    assert get_in(raw, ["node_outcomes", "task", "input_taint", "secret", "taint_sensitivity"]) ==
             "restricted"

    tampered =
      put_in(
        raw,
        ["node_outcomes", "task", "input_taint", "secret", "taint_sensitivity"],
        "public"
      )

    File.write!(c.path, Jason.encode!(tampered))
    assert {:error, :tampered} = Checkpoint.load(c.path, store: nil, hmac_secret: @secret)
    # Even an authenticated checkpoint cannot erase the independently retained
    # receipt's nonempty classification evidence.
    write_signed(c.path, tampered)
    assert {:ok, loaded} = Checkpoint.load(c.path, store: nil, hmac_secret: @secret)

    assert {:error, {:effect_recovery_inconsistent, :result_digest_mismatch}} =
             EffectRecoveryCore.decide(record, loaded)
  end

  test "security regression: only the exact empty map receives legacy digest compatibility" do
    empty = %Outcome{}
    digest = EffectOwner.outcome_result_digest(empty)

    for evidence <- [nil, [], %{"secret" => nil}, %{"secret" => :hostile}] do
      malformed = Map.put(empty, :input_taint, evidence)
      assert EffectOwner.outcome_result_digest(malformed) == raw_digest(malformed)
      refute EffectOwner.outcome_result_digest(malformed) == digest
    end
  end

  defp classified_outcome do
    label = %Taint{level: :untrusted, sensitivity: :restricted, source: "scan", chain: ["secret"]}
    # Keep this witness compilable on the predecessor: red must be a behavioral
    # receipt failure rather than an unknown struct-field compile failure.
    Map.put(%Outcome{context_updates: %{"summary" => "opaque"}}, :input_taint, %{
      "secret" => label
    })
  end

  defp checkpoint(outcome, digest) do
    run_id = "input-taint-receipt"
    execution_id = "exec_" <> String.duplicate("a", 32)

    {:ok, pending} =
      EffectEnvelope.new_pending(%{
        "generation" => 1,
        "run_id" => run_id,
        "node_id" => "task",
        "execution_id" => execution_id,
        "handler" => "Arbor.Orchestrator.Handlers.ExecHandler",
        "input_hash" => @input_hash,
        "idempotency_class" => "side_effecting",
        "started_at" => "2026-10-06T12:00:00.000000Z"
      })

    {:ok, completed} =
      EffectEnvelope.complete(pending, %{
        "completed_at" => @completed_at,
        "outcome_status" => "success",
        "result_digest" => digest
      })

    {:ok, settled} = EffectEnvelope.settle(completed)
    nodes = ["start", "task"]

    marker = %{
      execution_id: execution_id,
      input_hash: @input_hash,
      outcome_status: :success,
      completed_at: @completed_at
    }

    cp =
      Checkpoint.from_state(
        "task",
        nodes,
        %{},
        Context.new(%{"summary" => "opaque"}),
        %{"task" => outcome},
        run_id: run_id,
        graph_hash: "receipt-graph",
        execution_digests: %{"task" => marker}
      )

    {cp, %{current_effect: settled, completed_nodes: nodes}}
  end

  defp raw_digest(value),
    do:
      value
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  defp write_signed(path, data) do
    signed =
      Checkpoint.sign(data, @secret,
        run_id: data["run_id"],
        current_node: data["current_node"],
        graph_hash: data["graph_hash"]
      )

    File.write!(path, Jason.encode!(signed))
  end
end
