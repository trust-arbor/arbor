defmodule Arbor.Orchestrator.Engine.ArtifactStoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.ArtifactStore

  setup do
    dir =
      Path.join(System.tmp_dir!(), "artifact_store_test_#{System.unique_integer([:positive])}")

    File.rm_rf!(dir)
    {:ok, store} = ArtifactStore.start_link(logs_root: dir, file_threshold: 100)
    on_exit(fn -> File.rm_rf(dir) end)
    %{store: store, dir: dir}
  end

  describe "store and retrieve" do
    test "stores and retrieves small artifact in memory", %{store: store} do
      :ok = ArtifactStore.store(store, "node_1", "output.txt", "hello world")
      assert {:ok, "hello world"} = ArtifactStore.retrieve(store, "node_1", "output.txt")
    end

    test "stores large artifact on disk", %{store: store, dir: dir} do
      content = String.duplicate("x", 200)
      :ok = ArtifactStore.store(store, "node_1", "big.txt", content)
      assert {:ok, ^content} = ArtifactStore.retrieve(store, "node_1", "big.txt")

      # Verify file exists on disk
      assert File.exists?(Path.join([dir, "artifacts", "node_1", "big.txt"]))
    end

    test "returns not_found for missing artifact", %{store: store} do
      assert {:error, :not_found} = ArtifactStore.retrieve(store, "missing", "nope.txt")
    end

    test "overwrites existing artifact", %{store: store} do
      :ok = ArtifactStore.store(store, "node_1", "out.txt", "v1")
      :ok = ArtifactStore.store(store, "node_1", "out.txt", "v2")
      assert {:ok, "v2"} = ArtifactStore.retrieve(store, "node_1", "out.txt")
    end

    test "stores multiple artifacts per node", %{store: store} do
      :ok = ArtifactStore.store(store, "node_1", "prompt.md", "write code")
      :ok = ArtifactStore.store(store, "node_1", "response.md", "def hello, do: :world")

      assert {:ok, "write code"} = ArtifactStore.retrieve(store, "node_1", "prompt.md")

      assert {:ok, "def hello, do: :world"} =
               ArtifactStore.retrieve(store, "node_1", "response.md")
    end
  end

  describe "list" do
    test "lists all artifacts", %{store: store} do
      :ok = ArtifactStore.store(store, "node_1", "a.txt", "aaa")
      :ok = ArtifactStore.store(store, "node_2", "b.txt", "bbb")

      artifacts = ArtifactStore.list(store)
      assert length(artifacts) == 2
      assert Enum.all?(artifacts, &is_map/1)
      node_ids = Enum.map(artifacts, & &1.node_id)
      assert "node_1" in node_ids
      assert "node_2" in node_ids
    end

    test "lists artifacts for a specific node", %{store: store} do
      :ok = ArtifactStore.store(store, "node_1", "a.txt", "aaa")
      :ok = ArtifactStore.store(store, "node_2", "b.txt", "bbb")

      artifacts = ArtifactStore.list(store, "node_1")
      assert length(artifacts) == 1
      assert hd(artifacts).node_id == "node_1"
    end

    test "artifact refs include metadata", %{store: store} do
      :ok = ArtifactStore.store(store, "node_1", "a.txt", "hello")

      [artifact] = ArtifactStore.list(store, "node_1")
      assert artifact.node_id == "node_1"
      assert artifact.name == "a.txt"
      assert artifact.size == 5
      assert artifact.storage == :memory
      assert is_binary(artifact.stored_at)
    end

    test "artifact refs don't leak content", %{store: store} do
      :ok = ArtifactStore.store(store, "node_1", "a.txt", "secret content")

      [artifact] = ArtifactStore.list(store, "node_1")
      refute Map.has_key?(artifact, :content)
      refute Map.has_key?(artifact, :file_path)
    end
  end

  describe "clear" do
    test "removes all artifacts", %{store: store} do
      :ok = ArtifactStore.store(store, "node_1", "a.txt", "aaa")
      :ok = ArtifactStore.store(store, "node_2", "b.txt", "bbb")
      :ok = ArtifactStore.clear(store)

      assert ArtifactStore.list(store) == []
      assert {:error, :not_found} = ArtifactStore.retrieve(store, "node_1", "a.txt")
    end
  end

  describe "without logs_root" do
    test "stores everything in memory" do
      {:ok, store} = ArtifactStore.start_link()
      content = String.duplicate("x", 200)
      :ok = ArtifactStore.store(store, "node_1", "big.txt", content)
      assert {:ok, ^content} = ArtifactStore.retrieve(store, "node_1", "big.txt")

      [artifact] = ArtifactStore.list(store, "node_1")
      assert artifact.storage == :memory
      GenServer.stop(store)
    end
  end
end
