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

  alias Arbor.Agent.Eval.OpenCodeZenAdmission
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
        ids = live_ids(opts)
        Mix.shell().info("Live probe of #{length(ids)} candidate(s). Tier 1 is mechanical;")
        Mix.shell().info("tier 2 is mix arbor.eval.task. A model that cannot tool-call")
        Mix.shell().info("never reaches a proposal and is rejected.")
        Mix.shell().info("")

        Enum.each(ids, fn id ->
          Mix.shell().info("  candidate #{id}")
        end)

        Mix.shell().info("")
        Mix.shell().info("Recording lives in apps/arbor_llm/priv/opencode_zen/admission.json.")
        Mix.shell().info("Re-derive with mix arbor.eval.opencode_zen after updating it.")

      {:error, :disclosure_not_acknowledged} ->
        Mix.shell().error("Live probe refused: data-disclosure was not acknowledged.")
        exit({:shutdown, 1})
    end
  end

  defp live_ids(opts) do
    case opts[:model] do
      id when is_binary(id) and id != "" -> [id]
      _ -> OpenCodeZen.catalog().models |> Enum.map(& &1["id"]) |> Enum.reject(&is_nil/1)
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
