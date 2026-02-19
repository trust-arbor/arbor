defmodule Arbor.Orchestrator.Eval.RunStore do
  @moduledoc """
  Simple JSON file persistence for eval run results.

  Tracks model performance over time by saving eval results to JSON files
  in a configurable directory (default: `.arbor/eval_runs/`).

  Each run is a JSON file named `<run_id>.json` containing:
    - `id` — unique run identifier
    - `timestamp` — ISO 8601 timestamp
    - `model` — model name evaluated
    - `provider` — provider used
    - `dataset` — dataset path
    - `graders` — list of grader names used
    - `metrics` — computed metrics (accuracy, mean_score, etc.)
    - `sample_count` — number of samples
    - `duration_ms` — total eval duration
    - `results` — per-sample results
  """

  @default_dir ".arbor/eval_runs"

  @type run_data :: %{
          id: String.t(),
          timestamp: String.t(),
          model: String.t(),
          provider: String.t(),
          dataset: String.t(),
          graders: [String.t()],
          metrics: map(),
          sample_count: non_neg_integer(),
          duration_ms: non_neg_integer(),
          results: [map()]
        }

  @doc "Saves a run to disk."
  @spec save_run(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def save_run(run_id, run_data, opts \\ []) do
    dir = Keyword.get(opts, :dir, @default_dir)
    File.mkdir_p!(dir)

    data =
      run_data
      |> Map.put(:id, run_id)
      |> Map.put_new(:timestamp, DateTime.utc_now() |> DateTime.to_iso8601())

    path = Path.join(dir, "#{run_id}.json")

    case Jason.encode(data, pretty: true) do
      {:ok, json} -> File.write(path, json)
      {:error, reason} -> {:error, {:encode_error, reason}}
    end
  end

  @doc "Loads a run from disk."
  @spec load_run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load_run(run_id, opts \\ []) do
    dir = Keyword.get(opts, :dir, @default_dir)
    path = Path.join(dir, "#{run_id}.json")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:decode_error, reason}}
        end

      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  @doc "Lists all runs, sorted by timestamp (newest first). Filterable by model/provider."
  @spec list_runs(keyword()) :: {:ok, [map()]}
  def list_runs(opts \\ []) do
    dir = Keyword.get(opts, :dir, @default_dir)
    model_filter = Keyword.get(opts, :model)
    provider_filter = Keyword.get(opts, :provider)

    runs =
      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.flat_map(&read_run_file(Path.join(dir, &1)))
          |> maybe_filter(:model, model_filter)
          |> maybe_filter(:provider, provider_filter)
          |> Enum.sort_by(& &1["timestamp"], :desc)

        {:error, _} ->
          []
      end

    {:ok, runs}
  end

  defp read_run_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      [data]
    else
      _ -> []
    end
  end

  @doc "Returns the most recent run matching optional filters."
  @spec latest_run(keyword()) :: {:ok, map()} | {:error, :no_runs}
  def latest_run(opts \\ []) do
    case list_runs(opts) do
      {:ok, [latest | _]} -> {:ok, latest}
      {:ok, []} -> {:error, :no_runs}
    end
  end

  @doc "Compares metrics between two runs."
  @spec compare_runs(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def compare_runs(run_id_a, run_id_b, opts \\ []) do
    with {:ok, run_a} <- load_run(run_id_a, opts),
         {:ok, run_b} <- load_run(run_id_b, opts) do
      metrics_a = run_a["metrics"] || %{}
      metrics_b = run_b["metrics"] || %{}

      all_keys = MapSet.union(MapSet.new(Map.keys(metrics_a)), MapSet.new(Map.keys(metrics_b)))

      diffs =
        Map.new(all_keys, fn key ->
          val_a = metrics_a[key] || 0.0
          val_b = metrics_b[key] || 0.0

          diff =
            if is_number(val_a) and is_number(val_b) do
              val_b - val_a
            else
              nil
            end

          {key, %{"run_a" => val_a, "run_b" => val_b, "diff" => diff}}
        end)

      {:ok,
       %{
         "run_a" => %{
           "id" => run_id_a,
           "model" => run_a["model"],
           "timestamp" => run_a["timestamp"]
         },
         "run_b" => %{
           "id" => run_id_b,
           "model" => run_b["model"],
           "timestamp" => run_b["timestamp"]
         },
         "metrics_diff" => diffs
       }}
    end
  end

  defp maybe_filter(runs, _field, nil), do: runs

  defp maybe_filter(runs, field, value) do
    key = to_string(field)
    Enum.filter(runs, fn run -> run[key] == value end)
  end
end
