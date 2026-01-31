defmodule Mix.Tasks.Arbor.Backup do
  @shortdoc "Create an encrypted database backup"
  @moduledoc """
  Create an encrypted backup of the Arbor PostgreSQL database.

      $ mix arbor.backup

  The backup is encrypted with age using the public key from `~/.arbor/backup-key.txt`
  and stored in `~/.arbor/backups/`.

  ## Options

  - `--skip-cleanup` - Skip retention cleanup after backup

  ## Example

      $ mix arbor.backup
      Backup created: ~/.arbor/backups/arbor-2026-01-30-153045.sql.age

  ## Prerequisites

  - `pg_dump` must be installed and on PATH
  - `age` must be installed and on PATH
  - `~/.arbor/backup-key.txt` must contain an age public key

  ## Configuration

  Configure backup settings in your config:

      config :arbor_persistence, :backup,
        enabled: true,
        backup_dir: "~/.arbor/backups",
        age_key_file: "~/.arbor/backup-key.txt",
        retention: [daily: 7, weekly: 4, monthly: 3]
  """
  use Mix.Task

  alias Arbor.Persistence.Backup

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [skip_cleanup: :boolean])

    # Start the application to get config
    Mix.Task.run("app.config")

    Mix.shell().info("Creating database backup...")

    case Backup.backup(opts) do
      {:ok, path} ->
        Mix.shell().info("Backup created: #{path}")

      {:error, {:missing_command, cmd}} ->
        Mix.shell().error("Error: #{cmd} not found on PATH")
        Mix.shell().error("Please install #{cmd} to use this command.")
        exit({:shutdown, 1})

      {:error, {:missing_key_file, path}} ->
        Mix.shell().error("Error: Age public key file not found: #{path}")
        Mix.shell().error("")
        Mix.shell().error("To create a key pair:")
        Mix.shell().error("  age-keygen -o ~/.arbor/backup-key-private.txt")

        Mix.shell().error(
          "  age-keygen -y ~/.arbor/backup-key-private.txt > ~/.arbor/backup-key.txt"
        )

        exit({:shutdown, 1})

      {:error, :no_database_configured} ->
        Mix.shell().error("Error: No database configured for Arbor.Persistence.Repo")
        Mix.shell().error("Configure the database in config/config.exs or config/runtime.exs")
        exit({:shutdown, 1})

      {:error, {:pg_dump_failed, code, output}} ->
        Mix.shell().error("Error: pg_dump failed with exit code #{code}")
        Mix.shell().error(output)
        exit({:shutdown, 1})

      {:error, {:age_encrypt_failed, code, output}} ->
        Mix.shell().error("Error: age encryption failed with exit code #{code}")
        Mix.shell().error(output)
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("Error: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
