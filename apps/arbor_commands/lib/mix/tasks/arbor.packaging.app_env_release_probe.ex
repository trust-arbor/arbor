defmodule Mix.Tasks.Arbor.Packaging.AppEnvReleaseProbe do
  @shortdoc "Isolated assembled-release probe for owner app-env namespaces"

  @moduledoc """
  Probe-only assembled-release check for `:arbor_kernel` owner namespaces.

  Builds `:arbor_kernel` plus Common, Monitor, and Signals into a temporary
  release using the umbrella locked `deps/` cache as a read-only input, then
  evals the **release artifact** (not a development BEAM).

      mix arbor.packaging.app_env_release_probe
      mix arbor.packaging.app_env_release_probe --json

  This task is not installed in the root `quality` alias. It never runs
  `deps.get`, honors the standard `MIX_DEPS_PATH` for isolated worktrees, and
  never writes the umbrella `mix.lock` or dependency cache. The matching
  ExUnit production-path test is skipped unless
  `ARBOR_APP_ENV_PROBES=1` so a root-wide `mix test` does not nest a
  release build.
  """

  use Mix.Task

  @requirements ["compile"]

  alias Arbor.Commands.AppEnvReleaseProbe

  @impl Mix.Task
  def run(argv) do
    case execute_with_cli(argv) do
      {:ok, payload, cli} ->
        emit(payload, cli.json)
        :ok

      {:error, error} ->
        Mix.shell().error(format_error(error))
        exit({:shutdown, 1})
    end
  end

  @doc false
  @spec execute([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def execute(argv, runtime_opts \\ []) when is_list(argv) and is_list(runtime_opts) do
    case execute_with_cli(argv, runtime_opts) do
      {:ok, payload, _cli} -> {:ok, payload}
      {:error, error} -> {:error, error}
    end
  end

  defp execute_with_cli(argv, runtime_opts \\ []) do
    with {:ok, cli} <- parse_args(argv) do
      case Keyword.keys(runtime_opts) do
        [] ->
          case AppEnvReleaseProbe.run(json: cli.json, root: cli.root) do
            {:ok, payload} -> {:ok, payload, cli}
            {:error, _} = err -> err
          end

        unexpected ->
          {:error, {:production_task_forbids_runtime_hooks, unexpected}}
      end
    end
  end

  defp parse_args(argv) do
    {opts, positional, invalid} =
      OptionParser.parse(argv,
        strict: [
          json: :boolean,
          root: :string
        ]
      )

    cond do
      invalid != [] ->
        {:error, {:arguments, :unknown_or_invalid_option}}

      positional != [] ->
        {:error, {:arguments, :unexpected_positional}}

      true ->
        {:ok,
         %{
           json: Keyword.get(opts, :json, false) == true,
           root: opts[:root]
         }}
    end
  end

  defp emit(payload, json?) when is_boolean(json?) do
    if json? do
      Mix.shell().info(Jason.encode!(payload))
    else
      Mix.shell().info("app-env-release-probe status=ok")
    end
  end

  defp format_error({:arguments, reason}), do: "arguments: #{reason}"

  defp format_error(message) when is_binary(message), do: message

  defp format_error(other), do: "app-env-release-probe failed: #{inspect(other)}"
end
