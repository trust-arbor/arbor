defmodule Arbor.Flow.FileTracker do
  @moduledoc """
  Behaviour for tracking processed files in a workflow.

  FileTracker allows processors to track which files they've processed,
  avoiding reprocessing on restart. Implementations can store state in
  ETS (default), PostgreSQL, or other backends.

  ## Default Implementation

  Use `Arbor.Flow.FileTracker.ETS` as a simple in-memory tracker that
  survives within an application run but not across restarts.

  ## Persistent Implementation

  For persistence across restarts, use a backend that stores to disk or
  database. See `Arbor.SDLC.PersistentFileTracker` for an example.

  ## Usage

  ```elixir
  # Use the default ETS tracker
  {:ok, pid} = Arbor.Flow.FileTracker.ETS.start_link(name: :my_tracker)

  # Mark a file as processed
  :ok = FileTracker.ETS.mark_processed(:my_tracker, "path/to/file.md", "processor_1", "hash123")

  # Check if needs processing
  true = FileTracker.ETS.needs_processing?(:my_tracker, "path/to/file.md", "processor_1", "hash456")
  ```
  """

  @type tracker_ref :: atom() | pid()
  @type processor_name :: String.t() | atom()
  @type file_status :: :processed | :skipped | :failed | :moved | :pending
  @type file_record :: %{
          path: String.t(),
          processor: processor_name(),
          status: file_status(),
          content_hash: String.t() | nil,
          processed_at: DateTime.t(),
          metadata: map()
        }

  @doc """
  Mark a file as processed.
  """
  @callback mark_processed(
              ref :: tracker_ref(),
              path :: String.t(),
              processor :: processor_name(),
              content_hash :: String.t()
            ) :: :ok | {:error, term()}

  @doc """
  Mark a file as failed (for retry later).
  """
  @callback mark_failed(
              ref :: tracker_ref(),
              path :: String.t(),
              processor :: processor_name(),
              error_reason :: String.t()
            ) :: :ok | {:error, term()}

  @doc """
  Mark a file as skipped (won't process, but acknowledged).
  """
  @callback mark_skipped(
              ref :: tracker_ref(),
              path :: String.t(),
              processor :: processor_name(),
              reason :: String.t()
            ) :: :ok | {:error, term()}

  @doc """
  Check if a file needs processing.

  Returns true if:
  - File has never been processed by this processor
  - File's content hash has changed since last processing
  - Previous processing attempt failed
  """
  @callback needs_processing?(
              ref :: tracker_ref(),
              path :: String.t(),
              processor :: processor_name(),
              current_hash :: String.t()
            ) :: boolean()

  @doc """
  Get the processing record for a file.
  """
  @callback get_record(
              ref :: tracker_ref(),
              path :: String.t(),
              processor :: processor_name()
            ) :: {:ok, file_record()} | {:error, :not_found}

  @doc """
  Remove a file's processing record (e.g., when file is deleted).
  """
  @callback remove(
              ref :: tracker_ref(),
              path :: String.t(),
              processor :: processor_name()
            ) :: :ok

  @doc """
  Load all known file paths for a processor.
  """
  @callback load_known_files(
              ref :: tracker_ref(),
              processor :: processor_name()
            ) :: MapSet.t()

  @doc """
  Get statistics for a processor.
  """
  @callback stats(
              ref :: tracker_ref(),
              processor :: processor_name()
            ) :: %{
              total: non_neg_integer(),
              by_status: %{file_status() => non_neg_integer()}
            }

  @optional_callbacks [stats: 2]
end

defmodule Arbor.Flow.FileTracker.ETS do
  @moduledoc """
  ETS-based file tracker implementation.

  Provides in-memory tracking that survives within an application run
  but not across restarts. Use for development or when persistence
  isn't required.

  ## Usage

  ```elixir
  # Start the tracker
  {:ok, _pid} = Arbor.Flow.FileTracker.ETS.start_link(name: :flow_tracker)

  # Mark files
  :ok = Arbor.Flow.FileTracker.ETS.mark_processed(:flow_tracker, "file.md", "expander", "abc123")

  # Check status
  false = Arbor.Flow.FileTracker.ETS.needs_processing?(:flow_tracker, "file.md", "expander", "abc123")
  true = Arbor.Flow.FileTracker.ETS.needs_processing?(:flow_tracker, "file.md", "expander", "def456")
  ```
  """

  use GenServer

  @behaviour Arbor.Flow.FileTracker

  # =============================================================================
  # Client API
  # =============================================================================

  @doc """
  Start the ETS file tracker.

  ## Options

  - `:name` - Required. The name to register the tracker under.
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Arbor.Flow.FileTracker
  def mark_processed(ref, path, processor, content_hash) do
    GenServer.call(ref, {:mark, path, processor, :processed, content_hash, %{}})
  end

  @impl Arbor.Flow.FileTracker
  def mark_failed(ref, path, processor, error_reason) do
    GenServer.call(ref, {:mark, path, processor, :failed, nil, %{error: error_reason}})
  end

  @impl Arbor.Flow.FileTracker
  def mark_skipped(ref, path, processor, reason) do
    GenServer.call(ref, {:mark, path, processor, :skipped, nil, %{reason: reason}})
  end

  @impl Arbor.Flow.FileTracker
  def needs_processing?(ref, path, processor, current_hash) do
    GenServer.call(ref, {:needs_processing?, path, processor, current_hash})
  end

  @impl Arbor.Flow.FileTracker
  def get_record(ref, path, processor) do
    GenServer.call(ref, {:get_record, path, processor})
  end

  @impl Arbor.Flow.FileTracker
  def remove(ref, path, processor) do
    GenServer.call(ref, {:remove, path, processor})
  end

  @impl Arbor.Flow.FileTracker
  def load_known_files(ref, processor) do
    GenServer.call(ref, {:load_known_files, processor})
  end

  @impl Arbor.Flow.FileTracker
  def stats(ref, processor) do
    GenServer.call(ref, {:stats, processor})
  end

  # =============================================================================
  # Server Callbacks
  # =============================================================================

  @impl GenServer
  def init(_opts) do
    # Create ETS table: key is {path, processor}
    # Using anonymous table (no name) to avoid atom exhaustion from dynamic names
    table = :ets.new(:file_tracker_table, [:set, :protected])

    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:mark, path, processor, status, content_hash, metadata}, _from, state) do
    processor_name = normalize_processor(processor)
    key = {path, processor_name}

    record = %{
      path: path,
      processor: processor_name,
      status: status,
      content_hash: content_hash,
      processed_at: DateTime.utc_now(),
      metadata: metadata
    }

    :ets.insert(state.table, {key, record})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:needs_processing?, path, processor, current_hash}, _from, state) do
    processor_name = normalize_processor(processor)
    key = {path, processor_name}

    result =
      case :ets.lookup(state.table, key) do
        [] ->
          # Never processed
          true

        [{^key, %{status: :failed}}] ->
          # Failed before, retry
          true

        [{^key, %{status: :skipped}}] ->
          # Skipped files are intentionally not processed, don't reprocess
          false

        [{^key, %{status: :moved}}] ->
          # Moved files shouldn't be reprocessed at the old path
          false

        [{^key, %{content_hash: stored_hash}}] ->
          # Check if content changed
          stored_hash != current_hash
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:get_record, path, processor}, _from, state) do
    processor_name = normalize_processor(processor)
    key = {path, processor_name}

    result =
      case :ets.lookup(state.table, key) do
        [] -> {:error, :not_found}
        [{^key, record}] -> {:ok, record}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:remove, path, processor}, _from, state) do
    processor_name = normalize_processor(processor)
    key = {path, processor_name}

    :ets.delete(state.table, key)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:load_known_files, processor}, _from, state) do
    processor_name = normalize_processor(processor)

    # Match all records for this processor with status in [processed, skipped, moved]
    # Using :orelse guard since ETS doesn't support :in
    pattern = {{:"$1", processor_name}, %{status: :"$2"}}

    guard = [
      {:orelse, {:orelse, {:==, :"$2", :processed}, {:==, :"$2", :skipped}},
       {:==, :"$2", :moved}}
    ]

    result = [:"$1"]

    paths =
      :ets.select(state.table, [{pattern, guard, result}])
      |> MapSet.new()

    {:reply, paths, state}
  end

  @impl GenServer
  def handle_call({:stats, processor}, _from, state) do
    processor_name = normalize_processor(processor)

    # Match all records for this processor
    pattern = {{:_, processor_name}, %{status: :"$1"}}

    statuses =
      :ets.select(state.table, [{pattern, [], [:"$1"]}])

    by_status =
      Enum.reduce(statuses, %{}, fn status, acc ->
        Map.update(acc, status, 1, &(&1 + 1))
      end)

    stats = %{
      total: length(statuses),
      by_status: by_status
    }

    {:reply, stats, state}
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp normalize_processor(processor) when is_atom(processor) do
    processor
    |> Atom.to_string()
    |> String.replace("Elixir.", "")
  end

  defp normalize_processor(processor) when is_binary(processor), do: processor
end
