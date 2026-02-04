defmodule Arbor.Persistence.Backup do
  @moduledoc """
  PostgreSQL backup with age encryption and retention management.

  Provides automated backup of the arbor_persistence database with:
  - pg_dump for efficient database export
  - age encryption for secure storage
  - Configurable retention policy (daily/weekly/monthly)

  ## Configuration

      config :arbor_persistence, :backup,
        enabled: true,
        backup_dir: "~/.arbor/backups",
        age_key_file: "~/.arbor/backup-key.txt",
        schedule: {3, 0},  # {hour, minute} in local time
        retention: [daily: 7, weekly: 4, monthly: 3]

  ## Usage

      # Create a backup
      {:ok, path} = Arbor.Persistence.Backup.backup()

      # List available backups
      backups = Arbor.Persistence.Backup.list_backups()

      # Restore from a backup (requires private key path)
      :ok = Arbor.Persistence.Backup.restore("arbor-2026-01-30-030000.sql.age",
        private_key: "~/.arbor/backup-key-private.txt")

      # Run retention cleanup
      {:ok, deleted} = Arbor.Persistence.Backup.cleanup()
  """

  alias Arbor.Signals

  require Logger

  @backup_prefix "arbor-"
  @backup_suffix ".sql.age"
  @temp_suffix ".dump"

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Create an encrypted backup of the database.

  Returns `{:ok, backup_path}` on success or `{:error, reason}` on failure.

  ## Options

  - `:backup_dir` - Override the backup directory
  - `:age_key_file` - Override the age public key file
  - `:skip_cleanup` - If true, skip retention cleanup after backup (default: false)
  """
  @spec backup(keyword()) :: {:ok, String.t()} | {:error, term()}
  def backup(opts \\ []) do
    emit_backup_started()

    result =
      with :ok <- check_prerequisites(),
           {:ok, config} <- get_config(opts),
           {:ok, db_config} <- get_db_config(),
           {:ok, temp_path} <- run_pg_dump(db_config, config.backup_dir),
           {:ok, backup_path} <- encrypt_backup(temp_path, config) do
        # Clean up temp file
        File.rm(temp_path)

        # Run retention cleanup unless skipped
        unless Keyword.get(opts, :skip_cleanup, false) do
          cleanup(opts)
        end

        Logger.info("Backup created: #{backup_path}")
        {:ok, backup_path}
      end

    case result do
      {:ok, path} ->
        emit_backup_completed(path)
        result

      {:error, reason} ->
        emit_backup_failed(reason)
        result
    end
  end

  @doc """
  Restore the database from an encrypted backup.

  Requires the path to an age private key for decryption.

  Returns `:ok` on success or `{:error, reason}` on failure.

  ## Options

  - `:private_key` - Path to age private key file (required)
  - `:backup_dir` - Override the backup directory
  """
  @spec restore(String.t(), keyword()) :: :ok | {:error, term()}
  def restore(backup_filename, opts \\ []) do
    with :ok <- check_restore_prerequisites(),
         {:ok, config} <- get_config(opts),
         {:ok, private_key_path} <- get_private_key(opts),
         {:ok, db_config} <- get_db_config(),
         backup_path = Path.join(config.backup_dir, backup_filename),
         :ok <- verify_backup_exists(backup_path),
         {:ok, temp_path} <- decrypt_backup(backup_path, private_key_path, config.backup_dir),
         :ok <- run_pg_restore(temp_path, db_config) do
      # Clean up temp file
      File.rm(temp_path)

      Logger.info("Database restored from: #{backup_filename}")
      :ok
    end
  end

  @doc """
  Apply retention policy and delete old backups.

  Retention policy:
  - Keep last N daily backups (default: 7)
  - Keep first backup of each of last N weeks (default: 4)
  - Keep first backup of each of last N months (default: 3)

  Returns `{:ok, deleted_count}` with the number of deleted backups.
  """
  @spec cleanup(keyword()) :: {:ok, non_neg_integer()}
  def cleanup(opts \\ []) do
    config = get_config_readonly(opts)
    backups = list_backups(opts)

    to_keep = calculate_retention(backups, config.retention)
    to_delete = Enum.reject(backups, fn b -> MapSet.member?(to_keep, b.path) end)

    deleted_count =
      Enum.reduce(to_delete, 0, fn backup, count ->
        case File.rm(backup.path) do
          :ok ->
            Logger.info("Deleted old backup: #{Path.basename(backup.path)}")
            count + 1

          {:error, reason} ->
            Logger.warning("Failed to delete #{backup.path}: #{reason}")
            count
        end
      end)

    {:ok, deleted_count}
  end

  @doc """
  List all available backups with metadata.

  Returns a list of maps with `:path`, `:filename`, `:date`, and `:size` keys,
  sorted by date (newest first).
  """
  @spec list_backups(keyword()) :: [map()]
  def list_backups(opts \\ []) do
    config = get_config_readonly(opts)

    case File.ls(config.backup_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&backup_file?/1)
        |> Enum.map(fn filename ->
          path = Path.join(config.backup_dir, filename)
          stat = File.stat!(path)

          %{
            path: path,
            filename: filename,
            date: parse_backup_date(filename),
            size: stat.size
          }
        end)
        |> Enum.sort_by(& &1.date, {:desc, DateTime})

      {:error, :enoent} ->
        []
    end
  end

  # ============================================================================
  # Prerequisites Checking
  # ============================================================================

  defp check_prerequisites do
    with :ok <- check_command("pg_dump") do
      check_command("age")
    end
  end

  defp check_restore_prerequisites do
    with :ok <- check_command("pg_restore") do
      check_command("age")
    end
  end

  defp check_command(cmd) do
    case System.find_executable(cmd) do
      nil -> {:error, {:missing_command, cmd}}
      _path -> :ok
    end
  end

  # ============================================================================
  # Configuration
  # ============================================================================

  # Read-only config getter for list/cleanup operations
  defp get_config_readonly(opts) do
    app_config = Application.get_env(:arbor_persistence, :backup, [])

    backup_dir =
      Keyword.get(opts, :backup_dir) ||
        Keyword.get(app_config, :backup_dir, "~/.arbor/backups")
        |> Path.expand()

    retention = Keyword.get(app_config, :retention, daily: 7, weekly: 4, monthly: 3)

    %{
      backup_dir: backup_dir,
      retention: retention
    }
  end

  defp get_config(opts) do
    app_config = Application.get_env(:arbor_persistence, :backup, [])

    backup_dir =
      Keyword.get(opts, :backup_dir) ||
        Keyword.get(app_config, :backup_dir, "~/.arbor/backups")
        |> Path.expand()

    age_key_file =
      Keyword.get(opts, :age_key_file) ||
        Keyword.get(app_config, :age_key_file, "~/.arbor/backup-key.txt")
        |> Path.expand()

    retention = Keyword.get(app_config, :retention, daily: 7, weekly: 4, monthly: 3)

    # Ensure backup directory exists
    File.mkdir_p!(backup_dir)

    # Verify age key file exists
    if File.exists?(age_key_file) do
      {:ok,
       %{
         backup_dir: backup_dir,
         age_key_file: age_key_file,
         retention: retention
       }}
    else
      {:error, {:missing_key_file, age_key_file}}
    end
  end

  defp get_db_config do
    config = Application.get_env(:arbor_persistence, Arbor.Persistence.Repo, [])

    case Keyword.fetch(config, :database) do
      {:ok, database} ->
        {:ok,
         %{
           database: database,
           hostname: Keyword.get(config, :hostname, "localhost"),
           port: Keyword.get(config, :port, 5432),
           username: Keyword.get(config, :username, "postgres"),
           password: Keyword.get(config, :password, "")
         }}

      :error ->
        {:error, :no_database_configured}
    end
  end

  defp get_private_key(opts) do
    case Keyword.fetch(opts, :private_key) do
      {:ok, path} -> {:ok, Path.expand(path)}
      :error -> {:error, :private_key_required}
    end
  end

  # ============================================================================
  # Backup Operations
  # ============================================================================

  defp run_pg_dump(db_config, backup_dir) do
    timestamp = format_timestamp(DateTime.utc_now())
    temp_path = Path.join(backup_dir, "temp-#{timestamp}#{@temp_suffix}")

    # Build pg_dump command
    args = [
      "--format=custom",
      "--host=#{db_config.hostname}",
      "--port=#{db_config.port}",
      "--username=#{db_config.username}",
      "--file=#{temp_path}",
      db_config.database
    ]

    env = if db_config.password != "", do: [{"PGPASSWORD", db_config.password}], else: []

    # Build shell command with args
    cmd = "pg_dump #{Enum.join(args, " ")}"

    shell_env =
      case env do
        [] -> %{}
        list -> Map.new(list)
      end

    case Arbor.Shell.execute(cmd, env: shell_env, sandbox: :none, timeout: 300_000) do
      {:ok, %{exit_code: 0}} ->
        {:ok, temp_path}

      {:ok, %{exit_code: code, stdout: output}} ->
        File.rm(temp_path)
        {:error, {:pg_dump_failed, code, output}}

      {:error, reason} ->
        File.rm(temp_path)
        {:error, {:pg_dump_failed, 1, inspect(reason)}}
    end
  end

  defp encrypt_backup(temp_path, config) do
    timestamp = format_timestamp(DateTime.utc_now())
    backup_filename = "#{@backup_prefix}#{timestamp}#{@backup_suffix}"
    backup_path = Path.join(config.backup_dir, backup_filename)

    args = [
      "-R",
      config.age_key_file,
      "-o",
      backup_path,
      temp_path
    ]

    cmd = "age #{Enum.join(args, " ")}"

    case Arbor.Shell.execute(cmd, sandbox: :none, timeout: 120_000) do
      {:ok, %{exit_code: 0}} ->
        {:ok, backup_path}

      {:ok, %{exit_code: code, stdout: output}} ->
        {:error, {:age_encrypt_failed, code, output}}

      {:error, reason} ->
        {:error, {:age_encrypt_failed, 1, inspect(reason)}}
    end
  end

  # ============================================================================
  # Restore Operations
  # ============================================================================

  defp verify_backup_exists(path) do
    if File.exists?(path) do
      :ok
    else
      {:error, {:backup_not_found, path}}
    end
  end

  defp decrypt_backup(backup_path, private_key_path, backup_dir) do
    timestamp = format_timestamp(DateTime.utc_now())
    temp_path = Path.join(backup_dir, "restore-#{timestamp}#{@temp_suffix}")

    args = [
      "-d",
      "-i",
      private_key_path,
      "-o",
      temp_path,
      backup_path
    ]

    cmd = "age #{Enum.join(args, " ")}"

    case Arbor.Shell.execute(cmd, sandbox: :none, timeout: 120_000) do
      {:ok, %{exit_code: 0}} ->
        {:ok, temp_path}

      {:ok, %{exit_code: code, stdout: output}} ->
        {:error, {:age_decrypt_failed, code, output}}

      {:error, reason} ->
        {:error, {:age_decrypt_failed, 1, inspect(reason)}}
    end
  end

  defp run_pg_restore(temp_path, db_config) do
    args = [
      "--clean",
      "--if-exists",
      "--host=#{db_config.hostname}",
      "--port=#{db_config.port}",
      "--username=#{db_config.username}",
      "--dbname=#{db_config.database}",
      temp_path
    ]

    env = if db_config.password != "", do: [{"PGPASSWORD", db_config.password}], else: []

    cmd = "pg_restore #{Enum.join(args, " ")}"

    shell_env =
      case env do
        [] -> %{}
        list -> Map.new(list)
      end

    case Arbor.Shell.execute(cmd, env: shell_env, sandbox: :none, timeout: 300_000) do
      {:ok, %{exit_code: 0}} ->
        :ok

      {:ok, %{exit_code: code, stdout: output}} ->
        # pg_restore returns non-zero for warnings too, check for actual errors
        if String.contains?(output, "ERROR") do
          {:error, {:pg_restore_failed, code, output}}
        else
          # Warnings are okay
          :ok
        end
    end
  end

  # ============================================================================
  # Retention Policy
  # ============================================================================

  @doc false
  def calculate_retention(backups, retention) do
    daily_count = Keyword.get(retention, :daily, 7)
    weekly_count = Keyword.get(retention, :weekly, 4)
    monthly_count = Keyword.get(retention, :monthly, 3)

    # Sort by date descending (newest first)
    sorted = Enum.sort_by(backups, & &1.date, {:desc, DateTime})

    # Keep last N daily backups
    daily_keeps =
      sorted
      |> Enum.take(daily_count)
      |> MapSet.new(& &1.path)

    # Keep first backup of each of last N weeks
    weekly_keeps =
      sorted
      |> Enum.group_by(fn b -> week_of_year(b.date) end)
      |> Enum.sort_by(fn {week, _} -> week end, :desc)
      |> Enum.take(weekly_count)
      |> Enum.flat_map(fn {_week, backups} ->
        # First backup of the week (earliest)
        backups
        |> Enum.sort_by(& &1.date, {:asc, DateTime})
        |> Enum.take(1)
      end)
      |> MapSet.new(& &1.path)

    # Keep first backup of each of last N months
    monthly_keeps =
      sorted
      |> Enum.group_by(fn b -> {b.date.year, b.date.month} end)
      |> Enum.sort_by(fn {ym, _} -> ym end, :desc)
      |> Enum.take(monthly_count)
      |> Enum.flat_map(fn {_month, backups} ->
        # First backup of the month (earliest)
        backups
        |> Enum.sort_by(& &1.date, {:asc, DateTime})
        |> Enum.take(1)
      end)
      |> MapSet.new(& &1.path)

    # Union of all keeps
    daily_keeps
    |> MapSet.union(weekly_keeps)
    |> MapSet.union(monthly_keeps)
  end

  defp week_of_year(datetime) do
    date = DateTime.to_date(datetime)
    {year, week} = :calendar.iso_week_number({date.year, date.month, date.day})
    {year, week}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp backup_file?(filename) do
    String.starts_with?(filename, @backup_prefix) and String.ends_with?(filename, @backup_suffix)
  end

  defp format_timestamp(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d-%H%M%S")
  end

  @doc false
  def parse_backup_date(filename) do
    # Extract timestamp from "arbor-YYYY-MM-DD-HHMMSS.sql.age"
    case Regex.run(~r/arbor-(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})\.sql\.age/, filename) do
      [_, year, month, day, hour, minute, second] ->
        {:ok, datetime, _offset} =
          DateTime.from_iso8601("#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}Z")

        datetime

      nil ->
        # Fallback for malformed filenames
        DateTime.utc_now()
    end
  end

  # ============================================================================
  # Signal Emissions
  # ============================================================================

  defp emit_backup_started do
    Signals.emit(:persistence, :backup_started, %{})
  end

  defp emit_backup_completed(path) do
    Signals.emit(:persistence, :backup_completed, %{
      backup_path: path,
      backup_filename: Path.basename(path)
    })
  end

  defp emit_backup_failed(reason) do
    Signals.emit(:persistence, :backup_failed, %{
      reason: inspect(reason, limit: 200)
    })
  end
end
