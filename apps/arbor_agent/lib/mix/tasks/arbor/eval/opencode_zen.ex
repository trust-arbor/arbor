defmodule Mix.Tasks.Arbor.Eval.OpencodeZen do
  @shortdoc "Admit OpenCode Zen free models from recorded eval evidence"
  @moduledoc """
  Derive (or re-run) the OpenCode Zen free-tier admission list.

  Default: load `priv/opencode_zen/admission.json` and print the list
  derived from recorded evidence. This is how "running the admission eval
  reproduces the list" is checked without a live network call.

      mix arbor.eval.opencode_zen

  Live two-tier probe (requires disclosure acknowledgement):

      mix arbor.eval.opencode_zen --live --max-heartbeats 3

    * Tier 1 — mechanical well-formed tool call (cheap, per candidate)
    * Tier 2 — `mix arbor.eval.task` with a small `--max-heartbeats`

  Prints the data-disclosure warning. Live mode refuses to probe until
  the warning is acknowledged.
  """

  use Mix.Task

  alias Arbor.Agent.Eval.{OpenCodeZenAdmission, OpenCodeZenLive}
  alias Arbor.LLM.OpenCodeZen
  alias Arbor.LLM.OpenCodeZen.AdmissionCore

  @switches [
    live: :boolean,
    max_heartbeats: :integer,
    model: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    Mix.shell().info("")
    Mix.shell().info(OpenCodeZen.listing())

    if opts[:live] do
      run_live(opts)
    else
      Mix.shell().info("Derived from recorded evidence. Pass --live to re-probe.")
      Mix.shell().info("")
    end
  end

  defp run_live(opts) do
    case OpenCodeZen.prompt_acknowledgement() do
      :ok ->
        start_live_apps()
        ids = live_ids(opts)
        max_heartbeats = opts[:max_heartbeats] || 3

        Mix.shell().info("Live probe of #{length(ids)} candidate(s). Tier 1 is mechanical;")
        Mix.shell().info("tier 2 is mix arbor.eval.task. A model that cannot tool-call")
        Mix.shell().info("never reaches a proposal and is rejected.")
        Mix.shell().info("")

        result =
          OpenCodeZen.with_probe_models(ids, fn ->
            OpenCodeZenLive.run(
              ids: ids,
              max_heartbeats: max_heartbeats,
              log: fn line -> Mix.shell().info(line) end
            )
          end)

        case result do
          {:ok, _payload} ->
            Mix.shell().info("")
            Mix.shell().info(OpenCodeZen.listing())

            Mix.shell().info(
              "Recording lives in apps/arbor_llm/priv/opencode_zen/admission.json."
            )

          {:error, reason} ->
            Mix.shell().error("Live probe failed: #{inspect(reason)}")
            exit({:shutdown, 1})
        end

      {:error, :disclosure_not_acknowledged} ->
        Mix.shell().error("Live probe refused: data-disclosure was not acknowledged.")
        exit({:shutdown, 1})
    end
  end

  defp start_live_apps do
    {:ok, _} = Application.ensure_all_started(:arbor_memory)
    {:ok, _} = Application.ensure_all_started(:arbor_ai)
    {:ok, _} = Application.ensure_all_started(:arbor_orchestrator)
    {:ok, _} = Application.ensure_all_started(:arbor_agent)
    _ = Application.ensure_all_started(:arbor_persistence_ecto)
    :ok
  end

  defp live_ids(opts) do
    case opts[:model] do
      id when is_binary(id) and id != "" ->
        [id]

      _ ->
        # Discover from the relay, NOT from the local admission file. Sourcing
        # candidates from the file this probe writes made discovery circular:
        # it could only ever re-probe what was already recorded, which is how a
        # catalog of models the relay does not serve survived unchallenged.
        case OpenCodeZen.discover_free_candidates() do
          {:ok, [_ | _] = ids} ->
            ids

          {:ok, []} ->
            Mix.raise("OpenCode Zen returned no free-tier candidates.")

          {:error, reason} ->
            Mix.raise("Could not discover OpenCode Zen candidates: #{inspect(reason)}")
        end
    end
  end

  @doc false
  def derive_from_recorded do
    catalog = OpenCodeZen.catalog()
    {AdmissionCore.admitted_ids(catalog), AdmissionCore.rejected(catalog)}
  end

  @doc false
  def record_from_eval(id, response, trial) do
    OpenCodeZenAdmission.record(
      id,
      OpenCodeZenAdmission.tier1_from_response(response),
      OpenCodeZenAdmission.tier2_from_trial(trial)
    )
  end
end
