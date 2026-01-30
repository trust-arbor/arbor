defmodule Mix.Tasks.Arbor.Backup.Restore do
  @shortdoc "Restore database from an encrypted backup"
  @moduledoc """
  Restore the Arbor PostgreSQL database from an encrypted backup.

      $ mix arbor.backup.restore <filename> --private-key <path>

  This will decrypt the backup and restore it to the configured database.

  **WARNING**: This will overwrite all data in the current database!

  ## Arguments

  - `<filename>` - The backup filename (e.g., `arbor-2026-01-30-030000.sql.age`)

  ## Options

  - `--private-key` - Path to the age private key file (required)
  - `--yes` - Skip confirmation prompt

  ## Example

      $ mix arbor.backup.restore arbor-2026-01-30-030000.sql.age \\
          --private-key ~/.arbor/backup-key-private.txt

  ## Prerequisites

  - `pg_restore` must be installed and on PATH
  - `age` must be installed and on PATH
  - You must have the age private key that corresponds to the public key used for encryption
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [private_key: :string, yes: :boolean],
        aliases: [y: :yes, k: :private_key]
      )

    filename =
      case positional do
        [f | _] -> f
        [] -> usage_error("Missing backup filename")
      end

    private_key =
      case Keyword.fetch(opts, :private_key) do
        {:ok, k} -> k
        :error -> usage_error("Missing --private-key option")
      end

    # Start the application to get config
    Mix.Task.run("app.config")

    # Confirm unless --yes flag
    unless Keyword.get(opts, :yes, false) do
      Mix.shell().info("")
      Mix.shell().info("WARNING: This will overwrite all data in the current database!")
      Mix.shell().info("")
      Mix.shell().info("Backup file: #{filename}")
      Mix.shell().info("Private key: #{private_key}")
      Mix.shell().info("")

      unless Mix.shell().yes?("Are you sure you want to restore this backup?") do
        Mix.shell().info("Restore cancelled.")
        exit({:shutdown, 0})
      end
    end

    Mix.shell().info("")
    Mix.shell().info("Restoring database from #{filename}...")

    case Arbor.Persistence.Backup.restore(filename, private_key: private_key) do
      :ok ->
        Mix.shell().info("")
        Mix.shell().info("Database restored successfully from #{filename}")

      {:error, {:missing_command, cmd}} ->
        Mix.shell().error("Error: #{cmd} not found on PATH")
        Mix.shell().error("Please install #{cmd} to use this command.")
        exit({:shutdown, 1})

      {:error, :private_key_required} ->
        Mix.shell().error("Error: Private key path is required")
        Mix.shell().error("Use --private-key <path> to specify the age private key")
        exit({:shutdown, 1})

      {:error, {:backup_not_found, path}} ->
        Mix.shell().error("Error: Backup file not found: #{path}")
        Mix.shell().error("")
        Mix.shell().error("Use `mix arbor.backup.list` to see available backups.")
        exit({:shutdown, 1})

      {:error, :no_database_configured} ->
        Mix.shell().error("Error: No database configured for Arbor.Persistence.Repo")
        Mix.shell().error("Configure the database in config/config.exs or config/runtime.exs")
        exit({:shutdown, 1})

      {:error, {:age_decrypt_failed, code, output}} ->
        Mix.shell().error("Error: age decryption failed with exit code #{code}")
        Mix.shell().error(output)
        Mix.shell().error("")
        Mix.shell().error("Make sure you're using the correct private key.")
        exit({:shutdown, 1})

      {:error, {:pg_restore_failed, code, output}} ->
        Mix.shell().error("Error: pg_restore failed with exit code #{code}")
        Mix.shell().error(output)
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Error: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp usage_error(message) do
    Mix.shell().error("Error: #{message}")
    Mix.shell().error("")
    Mix.shell().error("Usage: mix arbor.backup.restore <filename> --private-key <path>")
    Mix.shell().error("")
    Mix.shell().error("Example:")
    Mix.shell().error("  mix arbor.backup.restore arbor-2026-01-30-030000.sql.age \\")
    Mix.shell().error("      --private-key ~/.arbor/backup-key-private.txt")
    exit({:shutdown, 1})
  end
end
