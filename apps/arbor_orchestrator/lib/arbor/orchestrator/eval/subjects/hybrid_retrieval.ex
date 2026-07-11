defmodule Arbor.Orchestrator.Eval.Subjects.HybridRetrieval do
  @moduledoc """
  Compatibility wrapper for `Arbor.AI.Eval.Subjects.HybridRetrieval`.
  """

  @behaviour Arbor.Orchestrator.Eval.Subject

  @default_index_path "priv/eval_datasets/preprocessor_tool_retrieval/action_index.json"

  @impl true
  def run(input, opts \\ [])

  def run(input, opts) when is_list(opts) do
    opts =
      if Keyword.keyword?(opts),
        do: Keyword.put_new(opts, :index_path, default_index_path()),
        else: opts

    Arbor.AI.Eval.Subjects.HybridRetrieval.run(input, opts)
  end

  def run(input, opts), do: Arbor.AI.Eval.Subjects.HybridRetrieval.run(input, opts)

  defp default_index_path do
    Application.get_env(
      :arbor_orchestrator,
      :eval_retrieval_index_path,
      Application.app_dir(:arbor_orchestrator, @default_index_path)
    )
  end
end
