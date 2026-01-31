defmodule Mix.Tasks.Arbor.Backup.List do
  @shortdoc "List available database backups"
  @moduledoc """
  List all available Arbor database backups.

      $ mix arbor.backup.list

  Shows all encrypted backup files in `~/.arbor/backups/` with their dates and sizes.

  ## Example Output

      Available backups:

        1. arbor-2026-01-30-153045.sql.age  (2026-01-30 15:30:45 UTC)  12.3 MB
        2. arbor-2026-01-29-030000.sql.age  (2026-01-29 03:00:00 UTC)  11.8 MB
        3. arbor-2026-01-28-030000.sql.age  (2026-01-28 03:00:00 UTC)  11.5 MB

      Total: 3 backups, 35.6 MB
  """
  use Mix.Task

  alias Arbor.Persistence.Backup

  @impl Mix.Task
  def run(_args) do
    # Start the application to get config
    Mix.Task.run("app.config")

    backups = Backup.list_backups()

    if Enum.empty?(backups) do
      Mix.shell().info("No backups found.")
      Mix.shell().info("")
      Mix.shell().info("Create your first backup with: mix arbor.backup")
    else
      Mix.shell().info("Available backups:")
      Mix.shell().info("")

      backups
      |> Enum.with_index(1)
      |> Enum.each(fn {backup, index} ->
        date_str = format_date(backup.date)
        size_str = format_size(backup.size)

        Mix.shell().info("  #{pad_number(index)}. #{backup.filename}  (#{date_str})  #{size_str}")
      end)

      total_size = Enum.sum(Enum.map(backups, & &1.size))

      Mix.shell().info("")

      Mix.shell().info("Total: #{length(backups)} backup(s), #{format_size(total_size)}")
    end
  end

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_size(bytes) when bytes < 1_073_741_824,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_size(bytes), do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  defp pad_number(n) when n < 10, do: " #{n}"
  defp pad_number(n), do: "#{n}"
end
