defmodule Mix.Tasks.Arbor.Baseline.Activate do
  @shortdoc "Activate an operator-owned Linux validation-runtime baseline"

  @moduledoc """
  Writes `$ARBOR_HOME/validation-runtime.json` (mode 0400) from a previously
  built `$ARBOR_HOME/baseline/<digest>/baseline.json`.

  Never fetches, never compiles, never talks to a registry.

  A process restart is required so `config/runtime.exs` re-pins the
  authority. `ARBOR_VALIDATION_RUNTIME_CONFIG_PATH` overrides the dest path.

      mix arbor.baseline.activate <tree-digest>
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Commands.Baseline
  alias Mix.Tasks.Arbor.Helpers, as: ArborConfig

  @impl Mix.Task
  def run(args) do
    ArborConfig.load_dotenv()

    case execute(args) do
      {:ok, report} ->
        Mix.shell().info(render(report))
        :ok

      {:error, reason} ->
        Mix.shell().error("baseline activate failed: #{format_error(reason)}")
        exit({:shutdown, 1})
    end
  end

  @doc false
  @spec execute([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def execute(args, runtime_opts \\ [])

  def execute(args, runtime_opts) when is_list(args) and is_list(runtime_opts) do
    if Keyword.keyword?(runtime_opts) do
      case OptionParser.parse(args, strict: []) do
        {_opts, [digest], []} ->
          config_path =
            Keyword.get(runtime_opts, :config_path) ||
              System.get_env("ARBOR_VALIDATION_RUNTIME_CONFIG_PATH")

          Baseline.activate(digest, Keyword.put(runtime_opts, :config_path, config_path))

        {_opts, [], []} ->
          {:error, :missing_digest}

        {_opts, _positional, _invalid} ->
          {:error, :invalid_arguments}
      end
    else
      {:error, :invalid_runtime_opts}
    end
  end

  def execute(_args, _runtime_opts), do: {:error, :invalid_arguments}

  defp render(report) when is_map(report) do
    """
    baseline activated
      digest=#{report["digest"]}
      path=#{report["path"]}
    Restart Arbor so config/runtime.exs re-pins this document.
    """
  end

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
