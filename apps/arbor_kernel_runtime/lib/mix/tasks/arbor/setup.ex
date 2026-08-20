defmodule Mix.Tasks.Arbor.Setup do
  use Boundary, classify_to: Arbor.KernelRuntime.DevTools
  @shortdoc "Set up Arbor for development"
  @moduledoc """
  Sets up Arbor for development from a fresh clone.

      $ ./bin/mix arbor.setup

  This task is idempotent — safe to run multiple times.

  ## Steps

  1. Check prerequisites (Elixir + OTP version)
  2. Fetch dependencies (`mix deps.get`)
  3. Set up `.env` from `.env.example` (if `.env` doesn't exist)
  4. Generate `ARBOR_COOKIE` if not already set in `.env`
  5. Ensure `~/.arbor/` directory structure exists
  6. Create database (`mix ecto.create`)
  7. Run migrations (`mix ecto.migrate`)
  8. Compile the project
  9. Print summary with next steps

  ## Options

    * `--skip-db` — Skip database creation and migration (for CI or no-database setups)
    * `--node-host HOST` — Set ARBOR_NODE_HOST for cross-machine clustering

  ## Database Adapter

  SQLite is the default (zero-config). For PostgreSQL, set `ARBOR_DB`:

    * Default — Use SQLite (zero-config, recommended for getting started)
    * `ARBOR_DB=postgres` — Use PostgreSQL (recommended for production)

  ## Clustering

  For cross-machine clustering, set `ARBOR_NODE_HOST` to this machine's IP
  or hostname (e.g. Tailscale MagicDNS name). The setup task auto-generates
  `ARBOR_COOKIE` if not present.

  Example:

      $ ./bin/mix arbor.setup --node-host 10.42.42.101
      $ ARBOR_DB=postgres ./bin/mix arbor.setup --node-host myhost.tailnet.ts.net

  """
  use Mix.Task

  @min_elixir_version "1.17.0"
  @min_otp_version 26

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [skip_db: :boolean, node_host: :string]
      )

    header()

    step("Checking prerequisites", &check_prerequisites/0)
    step("Installing Hex and Rebar", &ensure_hex_and_rebar/0)
    step("Fetching dependencies", &fetch_deps/0)
    step("Setting up environment", &setup_env/0)
    step("Configuring distribution cookie", fn -> setup_cookie(opts) end)

    if opts[:node_host] do
      step("Setting node host", fn -> setup_node_host(opts[:node_host]) end)
    end

    step("Ensuring directories", &ensure_directories/0)
    step("Ensuring operator identity", &ensure_operator_identity/0)

    unless opts[:skip_db] do
      step("Creating database", &create_db/0)
      step("Running migrations", &run_migrations/0)
    end

    step("Compiling", &compile/0)
    step("Seeding agent templates", &seed_templates/0)

    print_summary(opts)
  end

  # ── Steps ────────────────────────────────────────────────────────────

  defp check_prerequisites do
    elixir_version = System.version()
    otp_version = System.otp_release() |> to_string() |> String.to_integer()

    cond do
      not Version.match?(elixir_version, ">= #{@min_elixir_version}") ->
        {:error, "Elixir #{@min_elixir_version}+ required (found #{elixir_version})"}

      otp_version < @min_otp_version ->
        {:error, "OTP #{@min_otp_version}+ required (found OTP #{otp_version})"}

      true ->
        {:ok, "Elixir #{elixir_version} / OTP #{otp_version}"}
    end
  end

  defp ensure_hex_and_rebar do
    # `--if-missing` is already a no-op when the archive is installed, so do
    # not gate on `Code.ensure_loaded?(Hex)`. That guard produced a FALSE
    # POSITIVE on a clean machine: `Hex` was loadable while `Hex.Stdlib` was
    # not, so the install was skipped and the next step failed inside a
    # half-loaded Hex.
    Mix.Task.run("local.hex", ["--force", "--if-missing"])
    Mix.Task.run("local.rebar", ["--force", "--if-missing"])
    {:ok, "hex + rebar ready"}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Runs in a FRESH VM, never `Mix.Task.run("deps.get")`.
  #
  # Hex is only partially usable in the VM that is running this task: on a
  # clean Debian 13 box `Code.ensure_loaded?(Hex)` was true while
  # `Code.ensure_loaded?(Hex.Stdlib)` was false, and in-process `deps.get`
  # died with `function Hex.Stdlib.ensure_application!/1 is undefined` — an
  # error that reads like a corrupt Hex install rather than a VM-state
  # problem. A subprocess loads the archive normally at boot, which is why
  # running `./bin/mix deps.get` by hand always worked.
  #
  # This is invisible on a developer machine that already has a fully loaded
  # Hex, which is how it survived to a first-run onboarding path.
  defp fetch_deps do
    with {:ok, project_root} <- project_root() do
      fetch_deps(project_root)
    end
  end

  @doc false
  @spec fetch_deps(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def fetch_deps(project_root) when is_binary(project_root) do
    project_root = Path.expand(project_root)

    with {:ok, mix_wrapper} <- resolve_mix_wrapper(project_root) do
      run_deps_fetch(mix_wrapper, project_root)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def fetch_deps(_project_root), do: {:error, "could not determine the Arbor project root"}

  @doc false
  @spec resolve_mix_wrapper(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_mix_wrapper(project_root) when is_binary(project_root) do
    project_root = Path.expand(project_root)
    mix_wrapper = Path.join(project_root, "bin/mix")

    case File.stat(mix_wrapper) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o111) != 0 do
          {:ok, mix_wrapper}
        else
          {:error, mix_wrapper_error(mix_wrapper, "is not executable")}
        end

      {:ok, _stat} ->
        {:error, mix_wrapper_error(mix_wrapper, "is not a regular file")}

      {:error, :enoent} ->
        {:error, mix_wrapper_error(mix_wrapper, "does not exist")}

      {:error, reason} ->
        detail = reason |> :file.format_error() |> to_string()
        {:error, mix_wrapper_error(mix_wrapper, "could not be inspected (#{detail})")}
    end
  end

  def resolve_mix_wrapper(_project_root),
    do: {:error, "could not determine the Arbor project root"}

  defp run_deps_fetch(mix_wrapper, project_root) do
    case System.cmd(mix_wrapper, ["deps.get"],
           cd: project_root,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        {:ok, "done"}

      {output, status} ->
        {:error, "mix deps.get exited #{status}\n#{String.trim(output)}"}
    end
  end

  defp project_root do
    case Mix.Project.project_file() do
      nil -> {:error, "could not determine the Arbor project root"}
      project_file -> {:ok, project_file |> Path.expand() |> Path.dirname()}
    end
  end

  defp mix_wrapper_error(path, problem) do
    "reviewed Mix wrapper #{problem} at #{path}; " <>
      "restore bin/mix with executable mode in the Arbor project root"
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

  defp setup_cookie(opts) do
    env_path = Path.join(File.cwd!(), ".env")

    cond do
      # Already set in environment
      System.get_env("ARBOR_COOKIE") ->
        {:skip, "ARBOR_COOKIE already set in environment"}

      # Already in .env file
      env_has_key?(env_path, "ARBOR_COOKIE") ->
        {:skip, "ARBOR_COOKIE already in .env"}

      # Need to generate one
      File.exists?(env_path) ->
        cookie = generate_cookie()
        append_to_env(env_path, "ARBOR_COOKIE", cookie)
        System.put_env("ARBOR_COOKIE", cookie)

        if opts[:node_host] do
          {:ok, "generated and added to .env"}
        else
          {:ok, "generated and added to .env"}
        end

      true ->
        cookie = generate_cookie()
        # No .env file — just set it in the environment for this session
        System.put_env("ARBOR_COOKIE", cookie)
        {:ok, "generated (add ARBOR_COOKIE=#{cookie} to your shell profile)"}
    end
  end

  defp setup_node_host(host) do
    env_path = Path.join(File.cwd!(), ".env")

    if File.exists?(env_path) do
      if env_has_key?(env_path, "ARBOR_NODE_HOST") do
        update_env_key(env_path, "ARBOR_NODE_HOST", host)
        {:ok, "updated ARBOR_NODE_HOST=#{host} in .env"}
      else
        append_to_env(env_path, "ARBOR_NODE_HOST", host)
        {:ok, "set ARBOR_NODE_HOST=#{host} in .env"}
      end
    else
      {:ok, "set ARBOR_NODE_HOST=#{host} (add to shell profile for persistence)"}
    end
  end

  defp ensure_directories do
    arbor_dir = Path.expand("~/.arbor")
    logs_dir = Path.join(arbor_dir, "logs")

    File.mkdir_p!(arbor_dir)
    File.mkdir_p!(logs_dir)

    {:ok, "~/.arbor/ ready (including logs/)"}
  end

  # The operator's Ed25519 key. Needed by `mix arbor.signer` (signed MCP), the
  # software factory, and the checkpoint HMAC that makes
  # `arbor.pipeline.run/resume` resumable. IDENTITY.md previously said "there's
  # no dedicated CLI task yet; generate via the Elixir API" and gave a 12-line
  # iex snippet — so a fresh install simply had none, and the quickstart could
  # not honestly tell anyone how to get one.
  #
  # NOTE this is the AGENT identity (`agent_<hex>`), not an operator *principal*.
  # It does not satisfy the `human_` `principal_scope` an egress-disclosure
  # capability requires. See
  # `.arbor/roadmap/0-inbox/cli-operator-principal-and-identity.md`.
  defp ensure_operator_identity do
    ensure_operator_identity(Path.expand("~/.arbor/identity.key"))
  end

  @doc false
  @spec ensure_operator_identity(String.t()) ::
          {:ok, String.t()} | {:skip, String.t()} | {:error, String.t()}
  def ensure_operator_identity(path) when is_binary(path) do
    # NEVER overwrite. The checkpoint HMAC secret is derived from this key, so
    # replacing it silently orphans every existing checkpoint.
    if File.exists?(path) do
      {:skip, "#{path} already exists"}
    else
      write_operator_identity(path)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp write_operator_identity(path) do
    case Arbor.Contracts.Security.Identity.generate(name: operator_identity_name()) do
      {:ok, identity} ->
        contents = """
        agent_id=#{identity.agent_id}
        private_key_b64=#{Base.encode64(identity.private_key)}
        """

        File.mkdir_p!(Path.dirname(path))
        File.write!(path, contents)
        File.chmod!(path, 0o600)

        {:ok, "generated #{identity.agent_id} at #{path} (mode 600)"}

      {:error, reason} ->
        {:error, "could not generate operator identity: #{inspect(reason)}"}
    end
  end

  defp operator_identity_name do
    case System.get_env("USER") || System.get_env("USERNAME") do
      name when is_binary(name) and name != "" -> "#{name}-operator"
      _ -> "arbor-operator"
    end
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

  defp seed_templates do
    store = Arbor.Agent.TemplateStore

    # Builtins now ship as `.md` files in `priv/templates/` (the data-first
    # template migration removed the module-seeding path). Nothing to seed at
    # setup time — just confirm the shipped builtins are loadable.
    if Code.ensure_loaded?(store) and function_exported?(store, :builtin_names, 0) do
      apply(store, :ensure_table, [])
      count = store |> apply(:builtin_names, []) |> length()
      {:skip, "#{count} builtin template(s) ship as files (no seeding needed)"}
    else
      {:skip, "TemplateStore not available"}
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

  defp generate_cookie do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  defp env_has_key?(env_path, key) do
    case File.read(env_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.any?(fn line ->
          line = String.trim(line)
          not String.starts_with?(line, "#") and String.starts_with?(line, key <> "=")
        end)

      _ ->
        false
    end
  end

  defp append_to_env(env_path, key, value) do
    content = File.read!(env_path)

    # Ensure there's a newline before appending
    separator = if String.ends_with?(content, "\n"), do: "", else: "\n"

    File.write!(env_path, content <> separator <> "#{key}=#{value}\n")
  end

  defp update_env_key(env_path, key, value) do
    content = File.read!(env_path)

    updated =
      content
      |> String.split("\n")
      |> Enum.map_join("\n", fn line ->
        trimmed = String.trim(line)

        if not String.starts_with?(trimmed, "#") and String.starts_with?(trimmed, key <> "=") do
          "#{key}=#{value}"
        else
          line
        end
      end)

    File.write!(env_path, updated)
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
    node_host = opts[:node_host] || System.get_env("ARBOR_NODE_HOST")
    clustering = node_host != nil

    Mix.shell().info("""

    ╭─────────────────────────────╮
    │     Setup Complete!         │
    ╰─────────────────────────────╯

      Database: #{adapter_name}#{if opts[:skip_db], do: " (skipped)", else: ""}

      Next steps:
        See docs/QUICKSTART.md for clone-to-first-reply (SQLite, free LLM,
        arbor.start, conversationalist).

        mix arbor.start       # Start the Arbor server
        mix phx.server        # Or start interactively
        open http://localhost:4001  # Dashboard

      Configure LLM:
        mix arbor.doctor --configure  # Prefers OpenRouter / local / ACP

      Optional:
        Add OPENROUTER_API_KEY (or start Ollama/LM Studio) in .env
        See .env.example for all available settings
    """)

    if clustering do
      Mix.shell().info("""
        Clustering:
          Node host:  #{node_host}
          Cookie:     set in .env (shared across all cluster nodes)

          To join this node to an existing cluster:
            mix arbor.start
            mix arbor.cluster connect arbor_dev@<other-host>

          Ensure these ports are open between cluster nodes:
            4369      (EPMD — node discovery)
            9100-9155 (Erlang distribution — node communication)

          Tip: Use the same ARBOR_COOKIE value on all machines.
               Copy it from .env on this machine to .env on others.
      """)
    end
  end
end
