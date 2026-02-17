defmodule Arbor.Orchestrator.Engine.ArtifactStore do
  @moduledoc """
  ETS-backed artifact store for pipeline stage outputs.

  Provides per-pipeline-run storage with optional file backing for large artifacts.
  Each pipeline run gets a unique run_id. Artifacts are keyed by `{run_id, node_id, name}`.

  ## Storage Model
  - Small artifacts (< file_threshold): stored only in ETS for fast access
  - Large artifacts (>= file_threshold): written to disk, ETS stores the file path

  ## Usage

      {:ok, store} = ArtifactStore.start_link(logs_root: "/tmp/pipeline_run")
      :ok = ArtifactStore.store(store, "codergen_1", "response.md", code_text)
      {:ok, content} = ArtifactStore.retrieve(store, "codergen_1", "response.md")
      artifacts = ArtifactStore.list(store, "codergen_1")
      :ok = ArtifactStore.clear(store)
  """

  use GenServer

  @default_file_threshold 100_000
  @ets_table_prefix :arbor_artifacts_

  # Client API

  @type artifact_ref :: %{
          node_id: String.t(),
          name: String.t(),
          size: non_neg_integer(),
          stored_at: String.t(),
          storage: :memory | :file
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Store an artifact for a node."
  @spec store(GenServer.server(), String.t(), String.t(), binary()) :: :ok
  def store(server, node_id, name, content) when is_binary(content) do
    GenServer.call(server, {:store, node_id, name, content})
  end

  @doc "Retrieve an artifact by node_id and name."
  @spec retrieve(GenServer.server(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, :not_found}
  def retrieve(server, node_id, name) do
    GenServer.call(server, {:retrieve, node_id, name})
  end

  @doc "List all artifacts for a node (or all nodes if node_id is nil)."
  @spec list(GenServer.server(), String.t() | nil) :: [artifact_ref()]
  def list(server, node_id \\ nil) do
    GenServer.call(server, {:list, node_id})
  end

  @doc "Clear all artifacts."
  @spec clear(GenServer.server()) :: :ok
  def clear(server) do
    GenServer.call(server, :clear)
  end

  # Server

  @impl true
  def init(opts) do
    # ETS table is not :named_table, so the atom name is unused after creation.
    # Use the fixed prefix atom to avoid dynamic atom creation (DoS risk).
    table = :ets.new(@ets_table_prefix, [:set, :protected])
    logs_root = Keyword.get(opts, :logs_root)
    file_threshold = Keyword.get(opts, :file_threshold, @default_file_threshold)

    artifacts_dir =
      if logs_root do
        dir = Path.join(logs_root, "artifacts")
        File.mkdir_p!(dir)
        dir
      end

    {:ok,
     %{
       table: table,
       artifacts_dir: artifacts_dir,
       file_threshold: file_threshold
     }}
  end

  @impl true
  def handle_call({:store, node_id, name, content}, _from, state) do
    size = byte_size(content)
    key = {node_id, name}
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    if size >= state.file_threshold and state.artifacts_dir != nil do
      # Large artifact — write to file
      node_dir = Path.join(state.artifacts_dir, node_id)
      File.mkdir_p!(node_dir)
      file_path = Path.join(node_dir, name)
      File.write!(file_path, content)

      meta = %{
        node_id: node_id,
        name: name,
        size: size,
        stored_at: now,
        storage: :file,
        file_path: file_path
      }

      :ets.insert(state.table, {key, meta})
    else
      # Small artifact — store in ETS
      meta = %{
        node_id: node_id,
        name: name,
        size: size,
        stored_at: now,
        storage: :memory,
        content: content
      }

      :ets.insert(state.table, {key, meta})
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:retrieve, node_id, name}, _from, state) do
    key = {node_id, name}

    result =
      case :ets.lookup(state.table, key) do
        [{^key, %{storage: :memory, content: content}}] ->
          {:ok, content}

        [{^key, %{storage: :file, file_path: path}}] ->
          case File.read(path) do
            {:ok, _} = ok -> ok
            {:error, _} -> {:error, :not_found}
          end

        [] ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:list, nil}, _from, state) do
    artifacts =
      :ets.tab2list(state.table)
      |> Enum.map(fn {_key, meta} -> Map.drop(meta, [:content, :file_path]) end)
      |> Enum.sort_by(& &1.stored_at)

    {:reply, artifacts, state}
  end

  @impl true
  def handle_call({:list, node_id}, _from, state) do
    artifacts =
      :ets.tab2list(state.table)
      |> Enum.filter(fn {_key, meta} -> meta.node_id == node_id end)
      |> Enum.map(fn {_key, meta} -> Map.drop(meta, [:content, :file_path]) end)
      |> Enum.sort_by(& &1.stored_at)

    {:reply, artifacts, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    :ets.delete(state.table)
    :ok
  end
end
