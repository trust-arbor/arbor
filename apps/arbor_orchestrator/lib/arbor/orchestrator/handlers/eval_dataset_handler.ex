defmodule Arbor.Orchestrator.Handlers.EvalDatasetHandler do
  @moduledoc """
  Handler that loads a JSONL dataset into the pipeline context.

  Node attributes:
    - `dataset` — path to JSONL file (required)
    - `limit` — max samples to load (optional)
    - `shuffle` — "true" to randomize order (optional)
    - `seed` — random seed for reproducibility (optional)
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Eval

  import Arbor.Orchestrator.Handlers.Helpers

  @impl true
  def execute(node, context, _graph, opts) do
    dataset_path = Map.get(node.attrs, "dataset")

    unless dataset_path do
      raise "eval.dataset requires 'dataset' attribute"
    end

    workdir = Context.get(context, "workdir") || Keyword.get(opts, :workdir, ".")
    resolved = resolve_path(dataset_path, workdir)

    load_opts = []

    load_opts =
      if Map.get(node.attrs, "shuffle") in ["true", true],
        do: [{:shuffle, true} | load_opts],
        else: load_opts

    load_opts =
      if Map.get(node.attrs, "seed"),
        do: [{:seed, parse_int(Map.get(node.attrs, "seed"), 0)} | load_opts],
        else: load_opts

    load_opts =
      if Map.get(node.attrs, "limit"),
        do: [{:limit, parse_int(Map.get(node.attrs, "limit"), 0)} | load_opts],
        else: load_opts

    case Eval.load_dataset(resolved, load_opts) do
      {:ok, samples} ->
        %Outcome{
          status: :success,
          notes: "Loaded #{length(samples)} samples from #{dataset_path}",
          context_updates: %{
            "eval.dataset" => samples,
            "eval.dataset.count" => length(samples),
            "eval.dataset.path" => resolved
          }
        }

      {:error, reason} ->
        %Outcome{
          status: :fail,
          failure_reason: "Failed to load dataset: #{reason}"
        }
    end
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "eval.dataset error: #{Exception.message(e)}"
      }
  end

  @impl true
  def idempotency, do: :read_only

  defp resolve_path(path, workdir) do
    if Path.type(path) == :absolute, do: path, else: Path.join(workdir, path)
  end

end
