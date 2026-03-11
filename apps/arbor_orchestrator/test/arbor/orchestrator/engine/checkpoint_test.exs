defmodule Arbor.Orchestrator.Engine.CheckpointTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Engine.Checkpoint
  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @secret "test_hmac_secret_key_32bytes!!"

  setup do
    tmp = Path.join(System.tmp_dir!(), "checkpoint_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  describe "from_state/6" do
    test "includes graph_hash when provided" do
      ctx = Context.new(%{"key" => "value"})

      cp =
        Checkpoint.from_state("node1", ["start"], %{}, ctx, %{},
          run_id: "run_1",
          graph_hash: "abc123"
        )

      assert cp.run_id == "run_1"
      assert cp.graph_hash == "abc123"
      assert cp.current_node == "node1"
    end
  end

  describe "write + load (file)" do
    test "round-trips checkpoint data through file", %{tmp: tmp} do
      ctx = Context.new(%{"key" => "value", "count" => 42})

      outcome = %Outcome{
        status: :success,
        context_updates: %{"result" => "done"}
      }

      cp =
        Checkpoint.from_state(
          "node2",
          ["start", "node1"],
          %{"node1" => 1},
          ctx,
          %{
            "node1" => outcome
          },
          run_id: "run_file_test",
          graph_hash: "filehash",
          content_hashes: %{"node1" => "hash1"}
        )

      assert :ok = Checkpoint.write(cp, tmp)
      assert File.exists?(Path.join(tmp, "checkpoint.json"))

      {:ok, loaded} = Checkpoint.load(Path.join(tmp, "checkpoint.json"))

      assert loaded.run_id == "run_file_test"
      assert loaded.graph_hash == "filehash"
      assert loaded.current_node == "node2"
      assert loaded.completed_nodes == ["start", "node1"]
      assert loaded.node_retries == %{"node1" => 1}
      assert loaded.content_hashes == %{"node1" => "hash1"}
      assert loaded.context_values["key"] == "value"

      assert %Outcome{status: :success} = loaded.node_outcomes["node1"]
    end
  end

  describe "HMAC signing with expanded AAD" do
    test "sign and verify with AAD succeeds", %{tmp: tmp} do
      ctx = Context.new(%{"data" => "sensitive"})

      cp =
        Checkpoint.from_state("n1", [], %{}, ctx, %{},
          run_id: "run_hmac",
          graph_hash: "graphhash123"
        )

      assert :ok = Checkpoint.write(cp, tmp, hmac_secret: @secret)

      # File should contain __hmac
      {:ok, raw} = File.read(Path.join(tmp, "checkpoint.json"))
      assert raw =~ "__hmac"

      # Load with correct secret succeeds
      {:ok, loaded} = Checkpoint.load(Path.join(tmp, "checkpoint.json"), hmac_secret: @secret)
      assert loaded.run_id == "run_hmac"
    end

    test "verify fails with wrong secret", %{tmp: tmp} do
      ctx = Context.new(%{})

      cp =
        Checkpoint.from_state("n1", [], %{}, ctx, %{},
          run_id: "run_wrong_secret",
          graph_hash: "gh"
        )

      :ok = Checkpoint.write(cp, tmp, hmac_secret: @secret)

      assert {:error, :tampered} =
               Checkpoint.load(
                 Path.join(tmp, "checkpoint.json"),
                 hmac_secret: "wrong_secret_key_definitely!!"
               )
    end

    test "AAD binding prevents cross-pipeline replay" do
      data = %{"run_id" => "run_A", "current_node" => "n1", "graph_hash" => "hash1"}

      signed =
        Checkpoint.sign(data, @secret, run_id: "run_A", current_node: "n1", graph_hash: "hash1")

      # Verify with same AAD succeeds
      assert {:ok, _} =
               Checkpoint.verify(signed, @secret,
                 run_id: "run_A",
                 current_node: "n1",
                 graph_hash: "hash1"
               )

      # Verify with different run_id fails (replay attack)
      assert {:error, :tampered} =
               Checkpoint.verify(signed, @secret,
                 run_id: "run_B",
                 current_node: "n1",
                 graph_hash: "hash1"
               )

      # Verify with different graph_hash fails (graph modification)
      assert {:error, :tampered} =
               Checkpoint.verify(signed, @secret,
                 run_id: "run_A",
                 current_node: "n1",
                 graph_hash: "hash2"
               )
    end
  end

  describe "cleanup/1" do
    test "cleanup is idempotent and doesn't crash" do
      assert :ok = Checkpoint.cleanup("nonexistent_run_id")
    end
  end

  describe "cleanup_older_than/1" do
    test "returns count of deleted entries" do
      assert {:ok, count} = Checkpoint.cleanup_older_than(3600)
      assert is_integer(count)
    end
  end

  describe "pending_intents and execution_digests" do
    test "from_state includes WAL fields when provided" do
      ctx = Context.new(%{})

      intent = Checkpoint.build_pending_intent("ToolHandler", "hash123", "exec_run1_n1_hash123")

      digest =
        Checkpoint.build_execution_digest("hash456", :success, "exec_run1_n2_hash456")

      cp =
        Checkpoint.from_state("n1", [], %{}, ctx, %{},
          run_id: "run_wal",
          pending_intents: %{"n1" => intent},
          execution_digests: %{"n2" => digest}
        )

      assert cp.pending_intents == %{"n1" => intent}
      assert cp.execution_digests == %{"n2" => digest}
    end

    test "round-trips WAL fields through file", %{tmp: tmp} do
      ctx = Context.new(%{})

      intent = Checkpoint.build_pending_intent("ShellHandler", "inputhash1", "exec_r1_n1_input")

      digest =
        Checkpoint.build_execution_digest("inputhash2", :success, "exec_r1_n2_input")

      cp =
        Checkpoint.from_state("n2", ["n1"], %{}, ctx, %{},
          run_id: "run_wal_rt",
          pending_intents: %{"n1" => intent},
          execution_digests: %{"n2" => digest}
        )

      :ok = Checkpoint.write(cp, tmp)
      {:ok, loaded} = Checkpoint.load(Path.join(tmp, "checkpoint.json"))

      assert loaded.pending_intents["n1"].handler == "ShellHandler"
      assert loaded.pending_intents["n1"].execution_id == "exec_r1_n1_input"
      assert loaded.execution_digests["n2"].outcome_status == :success
      assert loaded.execution_digests["n2"].execution_id == "exec_r1_n2_input"
    end

    test "empty WAL fields round-trip correctly", %{tmp: tmp} do
      ctx = Context.new(%{})
      cp = Checkpoint.from_state("n1", [], %{}, ctx, %{}, run_id: "run_empty_wal")

      :ok = Checkpoint.write(cp, tmp)
      {:ok, loaded} = Checkpoint.load(Path.join(tmp, "checkpoint.json"))

      assert loaded.pending_intents == %{}
      assert loaded.execution_digests == %{}
    end
  end

  describe "execution ID generation" do
    test "generates deterministic IDs" do
      id1 = Checkpoint.generate_execution_id("run_1", "node_a", "abcdef123456789")
      id2 = Checkpoint.generate_execution_id("run_1", "node_a", "abcdef123456789")

      assert id1 == id2
      assert id1 == "exec_run_1_node_a_abcdef123456"
    end

    test "different inputs produce different IDs" do
      id1 = Checkpoint.generate_execution_id("run_1", "node_a", "hash1_______")
      id2 = Checkpoint.generate_execution_id("run_1", "node_b", "hash1_______")
      id3 = Checkpoint.generate_execution_id("run_2", "node_a", "hash1_______")

      assert id1 != id2
      assert id1 != id3
    end

    test "handles nil run_id" do
      id = Checkpoint.generate_execution_id(nil, "node_a", "hash123456xx")
      assert id =~ "exec_unknown_node_a_"
    end
  end

  describe "orphaned_intents/1" do
    test "returns empty list when no pending intents" do
      cp = %Checkpoint{pending_intents: %{}, execution_digests: %{}}
      assert Checkpoint.orphaned_intents(cp) == []
    end

    test "returns empty list when all intents have digests" do
      cp = %Checkpoint{
        pending_intents: %{"n1" => %{execution_id: "e1"}},
        execution_digests: %{"n1" => %{execution_id: "e1"}}
      }

      assert Checkpoint.orphaned_intents(cp) == []
    end

    test "returns orphaned intents without matching digests" do
      intent = %{handler: "ToolHandler", execution_id: "e1", input_hash: "h", started_at: "t"}

      cp = %Checkpoint{
        pending_intents: %{"n1" => intent, "n2" => %{execution_id: "e2"}},
        execution_digests: %{"n2" => %{execution_id: "e2"}}
      }

      orphaned = Checkpoint.orphaned_intents(cp)
      assert length(orphaned) == 1
      assert {"n1", ^intent} = hd(orphaned)
    end
  end

  describe "write to store" do
    test "checkpoint written to store can be loaded by run_id", %{tmp: tmp} do
      ctx = Context.new(%{"store_key" => "store_value"})

      cp =
        Checkpoint.from_state("store_node", ["start"], %{}, ctx, %{},
          run_id: "run_store_test",
          graph_hash: "storehash"
        )

      :ok = Checkpoint.write(cp, tmp)

      # Load by run_id (should hit store first)
      {:ok, loaded} =
        Checkpoint.load(
          Path.join(tmp, "checkpoint.json"),
          run_id: "run_store_test"
        )

      assert loaded.run_id == "run_store_test"
      assert loaded.graph_hash == "storehash"
      assert loaded.context_values["store_key"] == "store_value"

      # Cleanup
      Checkpoint.cleanup("run_store_test")
    end
  end
end
