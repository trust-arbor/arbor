defmodule Mix.Tasks.Arbor.Setup do
  @shortdoc "Set up Arbor for development"
  @moduledoc """
  Sets up Arbor for development from a fresh clone.

      $ mix setup

  This task is idempotent — safe to run multiple times.

  ## Steps

  1. Check prerequisites (Elixir version)
  2. Fetch dependencies (`mix deps.get`)
  3. Set up `.env` from `.env.example` (if `.env` doesn't exist)
  4. Ensure `~/.arbor/` directory exists
  5. Create database (`mix ecto.create`)
  6. Run migrations (`mix ecto.migrate`)
  7. Compile the project
  8. Print summary with next steps

  ## Options

    * `--skip-db` — Skip database creation and migration (for CI or no-database setups)

  ## Database Adapter

  Arbor supports both PostgreSQL and SQLite. The adapter is selected via
  the `ARBOR_DB` environment variable:

    * `ARBOR_DB=sqlite` — Use SQLite (zero-config, recommended for getting started)
    * Default — Use PostgreSQL (existing setup, recommended for production)

  Example:

      $ ARBOR_DB=sqlite mix setup

  """
  use Mix.Task

  @min_elixir_version "1.17.0"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [skip_db: :boolean])

    header()

    step("Checking prerequisites", &check_prerequisites/0)
    step("Fetching dependencies", &fetch_deps/0)
    step("Setting up environment", &setup_env/0)
    step("Ensuring directories", &ensure_directories/0)

    unless opts[:skip_db] do
      step("Creating database", &create_db/0)
      step("Running migrations", &run_migrations/0)
    end

    step("Compiling", &compile/0)

    print_summary(opts)
  end

  # ── Steps ────────────────────────────────────────────────────────────

  defp check_prerequisites do
    current = System.version()

    if Version.match?(current, ">= #{@min_elixir_version}") do
      {:ok, "Elixir #{current}"}
    else
      {:error, "Elixir #{@min_elixir_version}+ required (found #{current})"}
    end
  end

  defp fetch_deps do
    case Mix.Task.run("deps.get") do
      _ -> {:ok, "done"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp setup_env do
    env_path = Path.join(File.cwd!(), ".env")
    example_path = Path.join(File.cwd!(), ".env.example")

    cond do
      File.exists?(env_path) ->
        {:skip, ".env already exists"}

      File.exists?(example_path) ->
        File.cp!(example_path, env_path)
        {:ok, "created .env from .env.example"}

      true ->
        {:skip, "no .env.example found"}
    end
  end

  defp ensure_directories do
    arbor_dir = Path.expand("~/.arbor")

    unless File.dir?(arbor_dir) do
      File.mkdir_p!(arbor_dir)
    end

    {:ok, "~/.arbor/ ready"}
  end

  defp create_db do
    # Load app config so Repo knows its config
    Mix.Task.run("app.config")

    if sqlite?() do
      create_sqlite_db()
    else
      create_postgres_db()
    end
  end

  defp create_sqlite_db do
    db_path = get_sqlite_db_path()
    db_dir = Path.dirname(db_path)

    unless File.dir?(db_dir) do
      File.mkdir_p!(db_dir)
    end

    # ecto.create handles SQLite file creation
    Mix.Task.run("ecto.create", ["-r", "Arbor.Persistence.Repo", "--quiet"])
    {:ok, "SQLite database at #{db_path}"}
  rescue
    e ->
      msg = Exception.message(e)

      if String.contains?(msg, "already exists") do
        {:skip, "database already exists"}
      else
        {:error, msg}
      end
  end

  defp create_postgres_db do
    # Check if Postgres is reachable before attempting ecto.create
    case check_postgres() do
      :ok ->
        Mix.Task.run("ecto.create", ["-r", "Arbor.Persistence.Repo", "--quiet"])
        {:ok, "PostgreSQL database created"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      msg = Exception.message(e)

      if String.contains?(msg, "already exists") do
        {:skip, "database already exists"}
      else
        {:error, "#{msg}\n\n    Hint: Is PostgreSQL running? Try: ARBOR_DB=sqlite mix setup"}
      end
  end

  defp run_migrations do
    Mix.Task.run("ecto.migrate", ["-r", "Arbor.Persistence.Repo", "--quiet"])
    {:ok, "done"}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp compile do
    case Mix.Task.run("compile") do
      _ -> {:ok, "done"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp sqlite? do
    adapter = Application.get_env(:arbor_persistence, :repo_adapter, Ecto.Adapters.Postgres)
    adapter == Ecto.Adapters.SQLite3
  end

  defp get_sqlite_db_path do
    config = Application.get_env(:arbor_persistence, Arbor.Persistence.Repo, [])
    Keyword.get(config, :database, Path.expand("~/.arbor/arbor_dev.db"))
  end

  defp check_postgres do
    config = Application.get_env(:arbor_persistence, Arbor.Persistence.Repo, [])
    hostname = Keyword.get(config, :hostname, "localhost")
    port = Keyword.get(config, :port, 5432)

    case :gen_tcp.connect(String.to_charlist(hostname), port, [], 2_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _} ->
        {:error,
         "PostgreSQL is not reachable at #{hostname}:#{port}\n\n" <>
           "    Options:\n" <>
           "    1. Start PostgreSQL and try again\n" <>
           "    2. Use SQLite instead: ARBOR_DB=sqlite mix setup"}
    end
  end

  # ── Output ───────────────────────────────────────────────────────────

  defp header do
    Mix.shell().info("""

    ╭─────────────────────────────╮
    │       Arbor Setup           │
    ╰─────────────────────────────╯
    """)

    adapter_name = if sqlite?(), do: "SQLite", else: "PostgreSQL"
    Mix.shell().info("  Database: #{adapter_name}\n")
  end

  defp step(label, fun) do
    Mix.shell().info("  #{label}...")

    case fun.() do
      {:ok, detail} ->
        Mix.shell().info("    ✓ #{detail}")

      {:skip, detail} ->
        Mix.shell().info("    → #{detail} (skipped)")

      {:error, detail} ->
        Mix.shell().error("    ✗ #{detail}")
        Mix.shell().error("\n  Setup failed at: #{label}")
        exit({:shutdown, 1})
    end
  end

  defp print_summary(opts) do
    adapter_name = if sqlite?(), do: "SQLite", else: "PostgreSQL"

    Mix.shell().info("""

    ╭─────────────────────────────╮
    │     Setup Complete! 🎉      │
    ╰─────────────────────────────╯

      Database: #{adapter_name}#{if opts[:skip_db], do: " (skipped)", else: ""}

      Next steps:
        mix arbor.start       # Start the Arbor server
        mix phx.server        # Or start interactively
        open http://localhost:4001  # Dashboard

      Optional:
        Add API keys to .env for LLM access
        See .env.example for all available settings
    """)
  end
end
