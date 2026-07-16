defmodule Mix.Tasks.Arbor.EventLog.Repair do
  @shortdoc "Audit or explicitly repair legacy PostgreSQL EventLog rows"
  @moduledoc """
  Runs the explicit PostgreSQL EventLog repair procedure without starting the
  full Arbor umbrella.

      ./bin/mix arbor.event_log.repair
      ARBOR_DB=postgres ARBOR_DB_NAME=arbor_clone ./bin/mix arbor.event_log.repair --apply-positions --expected-count 3550132 --expected-old-max 2874929 --source-backup-digest SHA256

  Modes are mutually exclusive. Audit is the default. Position repair requires
  the exact count and old maximum from an audit. Identity remediation is split
  into staging and application so the reviewed source-backup digest and staged
  snapshot are durable before an exclusive-lock update occurs.

  PostgreSQL built-in `sha256(bytea)` support is required for retained source-row
  checksums.

  Identity provenance anchors a trusted cutover snapshot; synthetic operation
  IDs do not reconstruct original append boundaries or prove integrity of events
  that predate that snapshot. Position rollback is unavailable after a unique
  `global_position` index is installed unless an operator restores a database
  snapshot or performs an explicitly reviewed index downgrade.
  """

  use Mix.Task

  alias Arbor.Persistence.EventLog.PostgresRepair
  alias Arbor.Persistence.Repo

  @switches [
    apply_positions: :boolean,
    expected_count: :integer,
    expected_old_max: :integer,
    rollback_batch: :string,
    confirm_rollback: :string,
    stage_identities: :boolean,
    apply_identities: :boolean,
    batch_id: :string,
    source_backup_digest: :string,
    batch_size: :integer
  ]

  @impl Mix.Task
  def run(args), do: run(args, Repo)

  @doc false
  def run(args, repo) when is_atom(repo) do
    {opts, positional, invalid} = OptionParser.parse(args, switches: @switches)

    unless positional == [] and invalid == [] do
      usage_error("unrecognized arguments")
    end

    Mix.Task.run("app.config")
    start_database_apps!()
    start_repo!(repo)

    case mode(opts) do
      :audit -> print_result(PostgresRepair.audit(repo))
      :apply_positions -> apply_positions(repo, opts)
      :rollback -> rollback(repo, opts)
      :stage_identities -> stage_identities(repo, opts)
      :apply_identities -> apply_identities(repo, opts)
      :invalid -> usage_error("select at most one explicit repair mode")
    end
  end

  defp mode(opts) do
    selected =
      [
        {:apply_positions, Keyword.get(opts, :apply_positions, false)},
        {:rollback, is_binary(Keyword.get(opts, :rollback_batch))},
        {:stage_identities, Keyword.get(opts, :stage_identities, false)},
        {:apply_identities, Keyword.get(opts, :apply_identities, false)}
      ]
      |> Enum.filter(fn {_mode, selected?} -> selected? end)

    case selected do
      [] -> :audit
      [{selected_mode, true}] -> selected_mode
      _ -> :invalid
    end
  end

  defp apply_positions(repo, opts) do
    count = required_integer!(opts, :expected_count)
    old_maximum = required_integer!(opts, :expected_old_max)
    digest = required_string!(opts, :source_backup_digest)
    print_result(PostgresRepair.apply_positions(repo, count, old_maximum, digest))
  end

  defp rollback(repo, opts) do
    batch_id = Keyword.fetch!(opts, :rollback_batch)
    confirmation = required_string!(opts, :confirm_rollback)
    print_result(PostgresRepair.rollback_positions(repo, batch_id, confirmation))
  end

  defp stage_identities(repo, opts) do
    batch_id = required_string!(opts, :batch_id)
    digest = required_string!(opts, :source_backup_digest)
    batch_size = Keyword.get(opts, :batch_size, 1_000)
    print_result(PostgresRepair.stage_identity(repo, batch_id, digest, batch_size))
  end

  defp apply_identities(repo, opts) do
    batch_id = required_string!(opts, :batch_id)
    batch_size = Keyword.get(opts, :batch_size, 1_000)
    print_result(PostgresRepair.apply_staged_identity(repo, batch_id, batch_size))
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> Mix.raise("could not start #{inspect(repo)}: #{inspect(reason)}")
    end
  end

  defp start_database_apps! do
    Enum.each([:ecto_sql, :postgrex], fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _started} ->
          :ok

        {:error, reason} ->
          Mix.raise("could not start required database application #{app}: #{inspect(reason)}")
      end
    end)
  end

  defp required_integer!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> value
      _ -> usage_error("--#{option_name(key)} is required and must be a non-negative integer")
    end
  end

  defp required_string!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> value
      _ -> usage_error("--#{option_name(key)} is required")
    end
  end

  defp option_name(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  defp print_result({:ok, result}),
    do: Mix.shell().info(inspect(result, pretty: true, limit: :infinity))

  defp print_result({:error, reason}) do
    Mix.shell().error(
      "EventLog repair refused: #{inspect(reason, pretty: true, limit: :infinity)}"
    )

    exit({:shutdown, 1})
  end

  defp usage_error(message) do
    Mix.raise("""
    #{message}

    Usage:
      ./bin/mix arbor.event_log.repair
      ./bin/mix arbor.event_log.repair --apply-positions --expected-count COUNT --expected-old-max MAX --source-backup-digest SHA256
      ./bin/mix arbor.event_log.repair --rollback-batch BATCH --confirm-rollback BATCH
      ./bin/mix arbor.event_log.repair --stage-identities --batch-id BATCH --source-backup-digest SHA256 [--batch-size N]
      ./bin/mix arbor.event_log.repair --apply-identities --batch-id BATCH [--batch-size N]
    """)
  end
end
