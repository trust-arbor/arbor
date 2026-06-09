defmodule Mix.Tasks.Arbor.Security.Triage do
  @shortdoc "Set the status of a Security Sentinel finding (the feedback channel)"

  @moduledoc """
  Triage a Security Sentinel finding by setting its status. This is the human
  feedback channel: marking a finding `false_positive` or `wontfix` stops it
  reappearing on the next scan; `false_positive` additionally signals detector
  tuning is warranted.

      mix arbor.security.triage list
      mix arbor.security.triage list --status open

      mix arbor.security.triage sec-finding_ab12cd34ef56 false_positive --note "matches a test fixture"
      mix arbor.security.triage sec-finding_ab12cd34ef56 wontfix
      mix arbor.security.triage sec-finding_ab12cd34ef56 accepted

  ## Statuses

  `open`, `triaged`, `accepted`, `wontfix`, `in_remediation`, `fixed`,
  `regressed`, `false_positive`.

  ## Options

    * `--note TEXT`      — note appended to the finding (recommended for FP/wontfix)
    * `--dir DIR`        — finding directory (default `.arbor/security/findings`)
    * `--status STATUS`  — filter for the `list` subcommand
  """

  use Mix.Task

  alias Arbor.Actions.Security.FindingStore

  @switches [note: :string, dir: :string, status: :string]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile")
    {opts, args, _} = OptionParser.parse(argv, switches: @switches)
    dir = Keyword.get(opts, :dir, FindingStore.default_dir())

    case args do
      ["list"] -> list(dir, opts)
      [id, status] -> triage(id, status, dir, opts)
      _ -> Mix.shell().error("usage: mix arbor.security.triage <id> <status> | list")
    end
  end

  defp list(dir, opts) do
    status_filter = opts[:status] && parse_status(opts[:status])
    entries = FindingStore.list(dir: dir, status: status_filter)

    if entries == [] do
      Mix.shell().info("No findings#{if status_filter, do: " with status #{status_filter}"}.")
    else
      Enum.each(entries, fn {id, status} -> Mix.shell().info("  [#{status}] #{id}") end)
    end
  end

  defp triage(id, status_str, dir, opts) do
    case parse_status(status_str) do
      nil ->
        Mix.shell().error("invalid status: #{status_str}")

      status ->
        case FindingStore.set_status(id, status, dir: dir, note: opts[:note]) do
          :ok -> Mix.shell().info("#{id} → #{status}")
          {:error, :not_found} -> Mix.shell().error("finding not found: #{id}")
          {:error, reason} -> Mix.shell().error("failed: #{inspect(reason)}")
        end
    end
  end

  @valid ~w(open triaged accepted wontfix in_remediation fixed regressed false_positive)a

  defp parse_status(str) do
    Enum.find(@valid, &(Atom.to_string(&1) == str))
  end
end
