defmodule Arbor.SDLC.PersistentFileTracker do
  @moduledoc """
  Persistence-backed file tracker for SDLC workflow.

  Implements the `Arbor.Flow.FileTracker` behaviour with persistence
  via `Arbor.Persistence`. This ensures file processing state survives
  application restarts.

  ## Architecture

  The tracker stores records in the persistence layer keyed by
  `{path, processor}` pairs. Each record contains:

  - `:path` - The file path
  - `:processor` - Processor ID that handled the file
  - `:status` - Current status (:processed, :failed, :skipped, :moved)
  - `:content_hash` - Hash of file content when processed
  - `:processed_at` - Timestamp of processing
  - `:metadata` - Additional metadata (error info, etc.)

  ## Configuration

  Configure the backend via application environment:

      config :arbor_sdlc,
        persistence_backend: Arbor.Persistence.Store.ETS,
        persistence_name: :sdlc_tracker

  Or via `Arbor.SDLC.Config`.

  ## Usage

      # Start the tracker
      {:ok, _pid} = PersistentFileTracker.start_link(name: :sdlc_tracker)

      # Use via the Watcher
      {:ok, _} = Arbor.Flow.Watcher.start_link(
        tracker: :sdlc_tracker,
        tracker_module: Arbor.SDLC.PersistentFileTracker,
        ...
      )
  """

  use GenServer

  @behaviour Arbor.Flow.FileTracker

  require Logger

  alias Arbor.SDLC.Config

  defstruct [:name, :backend, :store_name, :config]

  @type state :: %__MODULE__{
          name: atom(),
          backend: module(),
          store_name: atom(),
          config: Config.t()
        }

  # =============================================================================
  # Client API
  # =============================================================================

  @doc """
  Start the persistent file tracker.

  ## Options

  - `:name` - Required. Name to register the tracker under
  - `:config` - Optional. Config struct (default: Config.new())
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

  @doc """
  Mark a file as moved to a new path.

  This is SDLC-specific - used when items transition between stages.
  """
  @spec mark_moved(GenServer.server(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def mark_moved(ref, old_path, new_path, processor, content_hash) do
    GenServer.call(ref, {:mark_moved, old_path, new_path, processor, content_hash})
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
  # GenServer Callbacks
  # =============================================================================

  @impl GenServer
  def init(opts) do
    config = Keyword.get(opts, :config, Config.new())
    name = Keyword.fetch!(opts, :name)

    state = %__MODULE__{
      name: name,
      backend: config.persistence_backend,
      store_name: config.persistence_name,
      config: config
    }

    # Ensure the persistence store is started if using ETS
    ensure_store_started(state)

    Logger.info("PersistentFileTracker started",
      name: name,
      backend: config.persistence_backend,
      store_name: config.persistence_name
    )

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:mark, path, processor, status, content_hash, metadata}, _from, state) do
    processor_name = normalize_processor(processor)
    key = build_key(path, processor_name)

    record = %{
      path: path,
      processor: processor_name,
      status: status,
      content_hash: content_hash,
      processed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      metadata: metadata
    }

    result = put_record(state, key, record)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:mark_moved, old_path, new_path, processor, content_hash}, _from, state) do
    processor_name = normalize_processor(processor)
    old_key = build_key(old_path, processor_name)
    new_key = build_key(new_path, processor_name)

    # Mark old path as moved
    old_record = %{
      path: old_path,
      processor: processor_name,
      status: :moved,
      content_hash: content_hash,
      processed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      metadata: %{moved_to: new_path}
    }

    # Create record for new path
    new_record = %{
      path: new_path,
      processor: processor_name,
      status: :processed,
      content_hash: content_hash,
      processed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      metadata: %{moved_from: old_path}
    }

    with :ok <- put_record(state, old_key, old_record),
         :ok <- put_record(state, new_key, new_record) do
      {:reply, :ok, state}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_call({:needs_processing?, path, processor, current_hash}, _from, state) do
    processor_name = normalize_processor(processor)
    key = build_key(path, processor_name)

    result =
      case get_record_by_key(state, key) do
        {:ok, %{status: :failed}} ->
          # Failed before, retry
          true

        {:ok, %{status: :skipped}} ->
          # Skipped intentionally
          false

        {:ok, %{status: :moved}} ->
          # Moved to new path
          false

        {:ok, %{content_hash: stored_hash}} ->
          # Check if content changed
          stored_hash != current_hash

        {:error, :not_found} ->
          # Never processed
          true
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:get_record, path, processor}, _from, state) do
    processor_name = normalize_processor(processor)
    key = build_key(path, processor_name)
    result = get_record_by_key(state, key)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:remove, path, processor}, _from, state) do
    processor_name = normalize_processor(processor)
    key = build_key(path, processor_name)
    result = delete_record(state, key)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:load_known_files, processor}, _from, state) do
    processor_name = normalize_processor(processor)
    paths = load_paths_for_processor(state, processor_name)
    {:reply, paths, state}
  end

  @impl GenServer
  def handle_call({:stats, processor}, _from, state) do
    processor_name = normalize_processor(processor)
    stats = compute_stats(state, processor_name)
    {:reply, stats, state}
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp ensure_store_started(%{backend: backend, store_name: store_name}) do
    # For ETS backend, start the store if not already running
    if backend == Arbor.Persistence.Store.ETS do
      case GenServer.whereis(store_name) do
        nil ->
          {:ok, _} = backend.start_link(name: store_name)

        _pid ->
          :ok
      end
    end

    :ok
  end

  defp build_key(path, processor) do
    "sdlc_tracker:#{processor}:#{path}"
  end

  defp put_record(%{backend: backend, store_name: name}, key, record) do
    Arbor.Persistence.put(name, backend, key, record)
  end

  defp get_record_by_key(%{backend: backend, store_name: name}, key) do
    case Arbor.Persistence.get(name, backend, key) do
      {:ok, record} when is_map(record) ->
        {:ok, record}

      {:error, :not_found} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  defp delete_record(%{backend: backend, store_name: name}, key) do
    Arbor.Persistence.delete(name, backend, key)
  end

  defp load_paths_for_processor(%{backend: backend, store_name: name}, processor_name) do
    prefix = "sdlc_tracker:#{processor_name}:"
    state = %{backend: backend, store_name: name}

    case Arbor.Persistence.list(name, backend) do
      {:ok, keys} ->
        keys
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.reduce(MapSet.new(), &collect_path_if_valid(&1, &2, state))

      {:error, _} ->
        MapSet.new()
    end
  end

  defp collect_path_if_valid(key, acc, state) do
    case get_record_by_key(state, key) do
      {:ok, %{path: path, status: status}} ->
        if valid_known_status?(status) do
          MapSet.put(acc, path)
        else
          acc
        end

      _ ->
        acc
    end
  end

  # Status may be atom or string depending on decode path
  defp valid_known_status?(status) when status in [:processed, :skipped, :moved], do: true
  defp valid_known_status?("processed"), do: true
  defp valid_known_status?("skipped"), do: true
  defp valid_known_status?("moved"), do: true
  defp valid_known_status?(_), do: false

  defp compute_stats(%{backend: backend, store_name: name}, processor_name) do
    prefix = "sdlc_tracker:#{processor_name}:"
    state = %{backend: backend, store_name: name}

    case Arbor.Persistence.list(name, backend) do
      {:ok, keys} ->
        records = fetch_records_for_keys(keys, prefix, state)
        build_stats(records)

      {:error, _} ->
        %{total: 0, by_status: %{}}
    end
  end

  defp fetch_records_for_keys(keys, prefix, state) do
    keys
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.flat_map(fn key ->
      case get_record_by_key(state, key) do
        {:ok, record} -> [record]
        _ -> []
      end
    end)
  end

  defp build_stats(records) do
    by_status =
      Enum.reduce(records, %{}, fn %{status: status}, acc ->
        status_atom = normalize_status(status)
        Map.update(acc, status_atom, 1, &(&1 + 1))
      end)

    %{
      total: length(records),
      by_status: by_status
    }
  end

  defp normalize_status(status) when is_binary(status) do
    String.to_existing_atom(status)
  end

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_processor(processor) when is_atom(processor) do
    processor
    |> Atom.to_string()
    |> String.replace("Elixir.", "")
  end

  defp normalize_processor(processor) when is_binary(processor), do: processor
end
