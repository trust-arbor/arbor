defmodule Mix.Tasks.Arbor.Eval.Salience do
  @moduledoc """
  Run the salience scoring validation eval.

  Compares compaction retention with and without salience modulation.
  High-salience messages (errors, decisions, person names, emotions)
  should survive compression longer than routine messages.

  ## Usage

      # Default settings
      mix arbor.eval.salience

      # Custom window size
      mix arbor.eval.salience --window 3000

      # Skip persistence
      mix arbor.eval.salience --no-persist

      # With experiment tag
      mix arbor.eval.salience --tag "v1"

  ## Options

    - `--window` — effective window size in tokens (default: 2000)
    - `--tag` — experiment tag for tracking
    - `--no-persist` — skip database persistence
  """

  use Mix.Task

  @shortdoc "Run salience scoring validation eval"

  @switches [
    window: :integer,
    tag: :string,
    persist: :boolean
  ]

  @aliases [
    w: :window,
    t: :tag
  ]

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:arbor_agent)
    _ = Application.ensure_all_started(:arbor_persistence_ecto)

    {opts, _, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    window = opts[:window] || 2000
    persist = Keyword.get(opts, :persist, true)
    tag = opts[:tag]

    Mix.shell().info("""

    ╔══════════════════════════════════════════════╗
    ║       Salience Scoring Validation             ║
    ╠══════════════════════════════════════════════╣
    ║  Window:  #{pad(to_string(window), 34)}║
    ║  Persist: #{pad(to_string(persist), 34)}║
    ║  Tag:     #{pad(tag || "(none)", 34)}║
    ╚══════════════════════════════════════════════╝
    """)

    {:ok, _results} =
      Arbor.Agent.Eval.SalienceEval.run(
        effective_window: window,
        persist: persist,
        tag: tag
      )

    Mix.shell().info("Salience eval complete.")
  end

  defp pad(str, width) do
    len = String.length(str)
    if len >= width, do: str, else: str <> String.duplicate(" ", width - len)
  end
end
