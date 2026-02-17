defmodule Arbor.Orchestrator.Mix.Helpers do
  @moduledoc "Shared CLI utilities for Mix tasks: color output, tables, prompts, progress."

  # Color output

  def info(msg), do: Mix.shell().info(msg)
  def success(msg), do: Mix.shell().info([:green, to_string(msg)])
  def warn(msg), do: Mix.shell().info([:yellow, to_string(msg)])
  def error(msg), do: Mix.shell().error([:red, to_string(msg)])

  # Table formatting

  @doc "Print a formatted table with headers and rows."
  def table(headers, rows) do
    all = [headers | rows]

    widths =
      Enum.reduce(all, List.duplicate(0, length(headers)), fn row, acc ->
        row
        |> Enum.map(&String.length(to_string(&1)))
        |> Enum.zip(acc)
        |> Enum.map(fn {a, b} -> max(a, b) end)
      end)

    separator = Enum.map_join(widths, "+", &String.duplicate("-", &1 + 2))
    info("+" <> separator <> "+")

    header_line =
      headers
      |> Enum.zip(widths)
      |> Enum.map_join("|", fn {h, w} -> " " <> String.pad_trailing(to_string(h), w) <> " " end)

    Mix.shell().info([:bright, "| " <> header_line <> "|"])
    info("+" <> separator <> "+")

    Enum.each(rows, fn row ->
      line =
        row
        |> Enum.zip(widths)
        |> Enum.map_join("|", fn {c, w} -> " " <> String.pad_trailing(to_string(c), w) <> " " end)

      info("| " <> line <> "|")
    end)

    info("+" <> separator <> "+")
  end

  # Application startup

  @doc """
  Start the orchestrator without the full umbrella app tree.

  Avoids port conflicts when the dev server is already running
  (e.g., gateway's :ranch listener). Only starts the orchestrator
  and its minimal deps (logger, jason).
  """
  def ensure_orchestrator_started do
    Mix.Task.run("compile")

    for app <- [:logger, :jason, :arbor_orchestrator] do
      Application.ensure_all_started(app)
    end
  end

  # Progress

  @doc "Show a spinner while running a function."
  def spinner(label, fun) do
    info("#{label}...")
    result = fun.()
    success("#{label}... done")
    result
  end

  # File operations

  @doc "Read and parse a DOT file, printing errors on failure."
  def parse_dot_file(path) do
    unless File.exists?(path) do
      error("File not found: #{path}")
      System.halt(1)
    end

    case File.read(path)
         |> then(fn
           {:ok, src} -> Arbor.Orchestrator.parse(src)
           err -> err
         end) do
      {:ok, graph} ->
        {:ok, graph}

      {:error, reason} ->
        error("Parse error: #{reason}")
        {:error, reason}
    end
  end
end
