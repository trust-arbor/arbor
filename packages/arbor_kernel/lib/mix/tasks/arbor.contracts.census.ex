defmodule Mix.Tasks.Arbor.Contracts.Census do
  use Boundary, classify_to: Arbor.Kernel.DevTools
  @shortdoc "Inventory arbor_contracts consumers (AC-1.0 / AC-02)"

  @moduledoc """
  Thin CLI over `Arbor.Contracts.Census`.

      ./bin/mix arbor.contracts.census
      ./bin/mix arbor.contracts.census --format json
      ./bin/mix arbor.contracts.census --format markdown
      ./bin/mix arbor.contracts.census --tier a,a2,shared
      ./bin/mix arbor.contracts.census --fail-on-violation

  Formats: `text` (default), `json`, `markdown`.
  `--tier` accepts a single tier or a comma-separated list.
  `--fail-on-violation` selects enforce mode without changing the default warn
  guard used by the admission test.
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Contracts.Census

  @impl Mix.Task
  def run(argv) do
    case execute(argv) do
      {:ok, report, formatted} ->
        Mix.shell().info(formatted)

        if Census.failed?(report) do
          Mix.shell().error(
            "contracts census: #{length(report.violations)} admission violation(s) (enforce)"
          )

          exit({:shutdown, 1})
        else
          :ok
        end

      {:error, reason} ->
        Mix.shell().error("contracts census failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  @doc false
  @spec execute([String.t()], keyword()) :: {:ok, map(), String.t()} | {:error, term()}
  def execute(argv, runtime_opts \\ []) when is_list(argv) and is_list(runtime_opts) do
    with {:ok, cli} <- parse_args(argv) do
      mode = if cli.fail_on_violation, do: :enforce, else: :warn

      opts =
        [mode: mode, tier: cli.tier, root: cli.root]
        |> Keyword.merge(
          Keyword.take(runtime_opts, [
            :root,
            :env,
            :now,
            :contract_sources,
            :consumer_sources,
            :registry_source,
            :grandfathered,
            :preamble
          ])
        )
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      case Census.run(opts) do
        {:ok, report} ->
          fmt_opts = Keyword.take(runtime_opts, [:preamble])
          {:ok, report, Census.format(report, cli.format, fmt_opts)}

        {:error, _} = err ->
          err
      end
    end
  end

  defp parse_args(argv) do
    {opts, positional, invalid} =
      OptionParser.parse(argv,
        strict: [
          format: :string,
          tier: :string,
          fail_on_violation: :boolean,
          root: :string
        ],
        aliases: [f: :format, t: :tier]
      )

    cond do
      invalid != [] ->
        {:error, {:arguments, :unknown_or_invalid_option, invalid}}

      positional != [] ->
        {:error, {:arguments, :unexpected_positional, positional}}

      true ->
        case Keyword.get(opts, :format, "text") do
          f when f in ["text", "json", "markdown"] ->
            {:ok,
             %{
               format: String.to_existing_atom(f),
               tier: Keyword.get(opts, :tier),
               fail_on_violation: Keyword.get(opts, :fail_on_violation, false) == true,
               root: Keyword.get(opts, :root)
             }}

          other ->
            {:error, {:arguments, :bad_format, other}}
        end
    end
  end
end
