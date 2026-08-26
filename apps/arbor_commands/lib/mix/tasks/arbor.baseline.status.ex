defmodule Mix.Tasks.Arbor.Baseline.Status do
  @shortdoc "Show Linux validation-runtime and baseline status"

  @moduledoc """
  Operator diagnostic for the validation runtime: driver, host/guest
  platform, mix.lock pin vs HEAD, and whether the image is reachable by
  digest.

  Goes through the `Arbor.Shell` facade. This is the validation row; do
  not hang it off `mix arbor.doctor --runtimes`.

      mix arbor.baseline.status
      mix arbor.baseline.status --json
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Commands.Baseline
  alias Mix.Tasks.Arbor.Helpers, as: ArborConfig

  @impl Mix.Task
  def run(args) do
    ArborConfig.load_dotenv()

    case execute(args) do
      {:ok, report, json?} ->
        Mix.shell().info(render(report, json?))
        :ok

      {:error, reason} ->
        Mix.shell().error("baseline status failed: #{format_error(reason)}")
        exit({:shutdown, 1})
    end
  end

  @doc false
  @spec execute([String.t()], keyword()) :: {:ok, map(), boolean()} | {:error, term()}
  def execute(args, runtime_opts \\ [])

  def execute(args, runtime_opts) when is_list(args) and is_list(runtime_opts) do
    if Keyword.keyword?(runtime_opts) do
      case OptionParser.parse(args, strict: [json: :boolean]) do
        {opts, [], []} ->
          maybe_start_shell(runtime_opts)

          case Baseline.status(runtime_opts) do
            {:ok, report} -> {:ok, report, opts[:json] == true}
            {:error, reason} -> {:error, reason}
          end

        {_opts, _positional, _invalid} ->
          {:error, :invalid_arguments}
      end
    else
      {:error, :invalid_runtime_opts}
    end
  end

  def execute(_args, _runtime_opts), do: {:error, :invalid_arguments}

  defp maybe_start_shell(runtime_opts) do
    if Keyword.has_key?(runtime_opts, :shell) do
      :ok
    else
      _ = Application.ensure_all_started(:arbor_shell)
      :ok
    end
  end

  defp render(report, true) when is_map(report), do: Jason.encode!(report)

  defp render(report, false) when is_map(report) do
    """
    validation runtime
      driver=#{report["driver"]}
      runtime_state=#{report["runtime_state"]}
      baseline_state=#{report["baseline_state"]}
      host_platform=#{report["host_platform"]}
      guest_platform=#{report["guest_platform"]}
      mix_lock_digest=#{report["mix_lock_digest"]}
      mix_lock_matches_head=#{report["mix_lock_matches_head"]}
      image_reachable=#{report["image_reachable"]}
    """
  end

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
