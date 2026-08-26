defmodule Mix.Tasks.Arbor.Baseline.Build do
  @shortdoc "Build an operator-owned Linux validation-runtime baseline"

  @moduledoc """
  From a clean checkout, produce a deps tree, labeled OCI image, and
  `$ARBOR_HOME/baseline/<tree-digest>/` (owner-only).

  May use the network to fetch locked Hex/Rebar. Does not mutate the active
  `$ARBOR_HOME/validation-runtime.json`. Activate is a separate command.

      mix arbor.baseline.build

  Image production uses `/usr/bin/podman build --pull=never`. Pull the
  reviewed Debian base once first (`podman pull debian:bookworm-slim`);
  see `images/validation-runtime/README.md`.
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
        Mix.shell().error("baseline build failed: #{format_error(reason)}")
        exit({:shutdown, 1})
    end
  end

  @doc false
  @spec execute([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def execute(args, runtime_opts \\ [])

  def execute(args, runtime_opts) when is_list(args) and is_list(runtime_opts) do
    if Keyword.keyword?(runtime_opts) do
      case OptionParser.parse(args, strict: [platform: :string]) do
        {opts, [], []} ->
          Baseline.build(Keyword.merge(runtime_opts, filter_opts(opts)))

        {_opts, _positional, _invalid} ->
          {:error, :invalid_arguments}
      end
    else
      {:error, :invalid_runtime_opts}
    end
  end

  def execute(_args, _runtime_opts), do: {:error, :invalid_arguments}

  defp filter_opts(opts) do
    case Keyword.get(opts, :platform) do
      platform when is_binary(platform) -> [platform: platform]
      _other -> []
    end
  end

  defp render(report) when is_map(report) do
    """
    baseline build complete
      platform=#{report["platform"]}
      tree_digest=#{report["tree_digest"]}
      mix_lock_digest=#{report["mix_lock_digest"]}
      baseline_root=#{report["baseline_root"]}
    Activate with mix arbor.baseline.activate #{report["tree_digest"]}
    """
  end

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
