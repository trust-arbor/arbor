defmodule Mix.Tasks.Arbor.Start do
  @shortdoc "Start Arbor as a background daemon"
  @moduledoc """
  Starts Arbor as a detached background process for development.

      $ mix arbor.start

  The server runs in the background with:
  - Node name: `arbor_dev@localhost` (or `arbor_dev@<ip>` with ARBOR_NODE_HOST)
  - Cookie: from ARBOR_COOKIE env var
  - Logs: `~/.arbor/logs/arbor-dev.log`
  - PID file: `~/.arbor/arbor-dev.pid`
  - Metadata: `~/.arbor/arbor-dev.meta.json` (persisted node/host/pid identity)

  ## Persisted identity and admission

  `start` persists the exact node name, host, and OS PID it launches to
  `~/.arbor/arbor-dev.meta.json` immediately after spawning (before waiting
  for readiness), so a failed or slow launch is never left untracked. Before
  spawning anything, it resolves whatever daemon is *actually* currently
  managed — via the persisted metadata (or, absent that, the legacy PID
  file) — and verifies liveness through an exact, bounded process-identity
  check, never a freshly re-detected host name and never a bare PID. If a
  verified managed daemon is already alive (reachable or not under the
  currently detected host), start refuses rather than spawning a duplicate.
  Admission is serialized through an exclusive lifecycle lock shared with
  `mix arbor.stop` / `mix arbor.restart`.

  ## Readiness

  Node reachability and application readiness are distinct:

  1. **Node reachability** — distribution ping answers (`:net_adm.ping`).
     Bounded by a short timeout (default 15s).
  2. **Application readiness** — every umbrella app from `Mix.Project.apps_paths/0`
     appears in remote `:application.which_applications/0`. Bounded by a longer
     cold-start budget (default 600s) because sequential umbrella boot can take
     minutes on a cold machine.

  Success is reported only when both phases pass. Timeout diagnostics distinguish
  unreachable node, partially started apps, and unavailable RPC observation.

  ## Environment Variables

  - `ARBOR_COOKIE` (required) — distribution cookie for cluster authentication
  - `ARBOR_NODE_HOST` (optional) — IP or FQDN for cross-machine clustering.
    An explicit value here is an operator relocation request; if a different
    persisted managed daemon is verified alive, start refuses until it is
    stopped (`mix arbor.stop`) rather than relocating out from under it.

  ## Examples

      # Local development (shortnames)
      ARBOR_COOKIE=secret mix arbor.start

      # Cross-machine clustering (longnames)
      ARBOR_NODE_HOST=10.42.42.101 ARBOR_COOKIE=secret mix arbor.start

  Use `mix arbor.status` to check on it and
  `mix arbor.stop` to shut it down.
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config
  alias Mix.Tasks.Arbor.LifecycleIdentity
  alias Mix.Tasks.Arbor.Readiness

  # Short bound for distribution ping only — not full application readiness.
  @node_timeout_ms 15_000
  # Cold umbrella boot measured ~296s (2026-07-17); 600s keeps operational margin.
  @app_timeout_ms 600_000
  @poll_interval_ms 500
  # Per-RPC ceiling; each call is also clamped to the remaining absolute budget.
  @rpc_timeout_ms 5_000
  # Bound for confirming a launch-tracking-failure SIGTERM actually took effect.
  @force_stop_confirm_timeout_ms 5_000

  @impl Mix.Task
  def run(args) do
    Config.ensure_distribution()

    case Config.with_lock(fn -> launch_locked(args, nil) end) do
      {:refuse, reason, detail} ->
        Mix.shell().error(Config.describe_lock_refusal(reason, detail))
        exit({:shutdown, 1})

      _ ->
        :ok
    end
  end

  @doc false
  # Called directly by `Mix.Tasks.Arbor.Restart`, which already holds the
  # lifecycle lock for the whole stop+start sequence — this must never
  # re-acquire the lock itself (it would see its own lock as held by a live
  # owner and self-block). `internal_launch_host`, when non-nil, is the host
  # Restart captured from the persisted identity BEFORE stopping the old
  # daemon; it wins over auto-detection but loses to an explicit
  # ARBOR_NODE_HOST operator override.
  def launch_locked(args, internal_launch_host) do
    Config.ensure_distribution()

    facts = gather_start_facts(internal_launch_host)

    case LifecycleIdentity.decide_start(facts) do
      {:refuse, reason, detail} ->
        report_refusal(reason, detail)
        exit({:shutdown, 1})

      {:proceed, host} ->
        do_launch(args, host)
    end
  end

  defp gather_start_facts(internal_launch_host) do
    metadata = Config.read_metadata()

    metadata_pid_check =
      case metadata do
        {:ok, meta} -> Config.verify_pid_as_arbor_node(meta.pid)
        _ -> nil
      end

    {legacy_pid_present?, legacy_pid, legacy_pid_check} =
      if metadata == :absent, do: legacy_pid_facts(), else: {false, nil, nil}

    %{
      metadata: metadata,
      metadata_pid_check: metadata_pid_check,
      legacy_pid_present?: legacy_pid_present?,
      legacy_pid: legacy_pid,
      legacy_pid_check: legacy_pid_check,
      host_intent: resolve_host_intent(internal_launch_host)
    }
  end

  # A malformed legacy PID file (unreadable, non-numeric content) means
  # something is there but we can't trust it — treated as present-but-
  # unverified (ambiguous), never as :absent, so admission fails closed
  # rather than proceeding as if nothing were tracked.
  defp legacy_pid_facts do
    case Config.read_pid() do
      :absent -> {false, nil, nil}
      {:error, :malformed} -> {true, nil, :unverified}
      {:ok, pid} -> {true, pid, Config.verify_pid_as_arbor_node(pid)}
    end
  end

  defp resolve_host_intent(internal_launch_host) do
    cond do
      host = System.get_env("ARBOR_NODE_HOST") -> {:operator_relocation, host}
      internal_launch_host -> {:internal_continuity, internal_launch_host}
      true -> {:auto, Config.node_hostname()}
    end
  end

  defp report_refusal(:malformed_metadata, _detail) do
    Mix.shell().error("""

    Metadata file #{Config.metadata_file()} is malformed or fails local
    identity validation. It has been left untouched. Inspect it manually
    and remove it only once you have confirmed no managed daemon depends
    on it, then retry.
    """)
  end

  defp report_refusal(:already_running, %{node: node, pid: pid}) do
    Mix.shell().error("Arbor is already running at #{node} (pid #{pid}).")
  end

  defp report_refusal(:node_identity_mismatch, %{expected: expected, observed: observed}) do
    Mix.shell().error("""

    Persisted metadata claims #{expected}, but the live process at that PID
    is actually #{observed}. Refusing to start until this is resolved
    manually — inspect #{Config.metadata_file()}.
    """)
  end

  defp report_refusal(:ambiguous_metadata_pid, _detail) do
    Mix.shell().error("""

    Cannot verify whether the PID recorded in #{Config.metadata_file()}
    belongs to a managed Arbor daemon. Refusing to start (ambiguous).
    """)
  end

  defp report_refusal(:legacy_daemon_alive, %{node: node}) do
    Mix.shell().error("""

    A legacy (pre-metadata) Arbor daemon is verified alive at #{node}.
    Run `mix arbor.stop` first.
    """)
  end

  defp report_refusal(:ambiguous_legacy_state, _detail) do
    Mix.shell().error("""

    Cannot verify the process recorded in #{Config.pid_file()}.
    Refusing to start (ambiguous).
    """)
  end

  defp do_launch(_args, host) do
    host_source =
      cond do
        System.get_env("ARBOR_NODE_HOST") -> "(from ARBOR_NODE_HOST)"
        Config.detect_wireguard_ip() -> "(WireGuard auto-detected)"
        true -> "(persisted/detected)"
      end

    Mix.shell().info("Starting Arbor server...")
    Mix.shell().info("  Host: #{host} #{host_source}")

    project_dir = File.cwd!()
    log_file = Config.log_file()

    # Fresh nodes don't have ~/.arbor/logs yet — create it before the shell
    # redirect below writes to it (otherwise: "cannot create … Directory
    # nonexistent"). Covers `mix arbor.restart` too (it delegates to Start.run).
    Config.ensure_runtime_dirs()

    # Rotate the previous log before the `> log_file` truncate below wipes it. Keeps 3 generations
    # (arbor-dev.log.1/.2/.3) so a crash's evidence survives a restart — truncating on every start is
    # exactly what erased the 2026-07-04 node-crash logs and forced a Postgres-EventLog reconstruction.
    rotate_log(log_file)

    # Resolve the real elixir and mix paths from the running Elixir installation.
    # This avoids mise/asdf shim binaries which are Mach-O executables that
    # crash when loaded by `elixir -S mix` (Code.require_file tries to parse
    # the binary as Elixir source).
    {elixir_path, mix_path} = resolve_real_paths()

    # Background via shell so stdout/stderr flow to the log file for `mix arbor.logs`.
    # The shell returns the PID immediately via `echo $!`.
    name_flag = if Config.longnames?(), do: "--name", else: "--sname"

    node = Config.node_atom(node_string_for(host))

    # Pin Erlang distribution to a predictable port range for firewalls
    # Increase net_ticktime to 120s (disconnect after ~8 min of no response)
    # to tolerate brief network hiccups and idle periods
    erl_flags =
      "--erl '-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9155 net_ticktime 120'"

    elixir_cmd =
      "#{elixir_path} #{name_flag} #{node} " <>
        "--cookie #{Config.cookie()} #{erl_flags} #{mix_path} run --no-halt " <>
        "> #{log_file} 2>&1 & echo $!"

    # Inherit the full environment so API keys, PATH, etc. are available.
    # Only override MIX_ENV explicitly.
    env =
      System.get_env()
      |> Map.put("MIX_ENV", to_string(Mix.env()))
      |> Enum.to_list()

    {output, 0} =
      System.cmd("sh", ["-c", elixir_cmd],
        cd: project_dir,
        env: env
      )

    pid =
      output
      |> String.trim()
      |> String.split("\n")
      |> List.last()
      |> String.to_integer()

    track_launch(node_string_for(host), host, pid)

    expected = Readiness.expected_umbrella_apps(Mix.Project.apps_paths())

    case await_ready(node, expected) do
      :ok ->
        Config.write_metadata!(%{
          node: node_string_for(host),
          host: host,
          pid: pid,
          state: :ready
        })

        Mix.shell().info("""

        Arbor server started successfully.
          Node:  #{node}
          PID:   #{pid}
          Log:   #{log_file}
          Apps:  #{length(expected)} umbrella applications ready

        Use `mix arbor.status` for details.
        Use `mix arbor.stop` to shut down.
        """)

      {:error, :node_unreachable} ->
        Mix.shell().error("""

        #{Readiness.timeout_diagnostic(:node_unreachable, expected, @node_timeout_ms)}
        Check the log file for errors: #{log_file}

        The launched process (pid #{pid}) is still recorded in
        #{Config.metadata_file()} as `state: "starting"` — `mix arbor.stop`
        will target it accurately if it needs to be cleaned up.
        """)

        exit({:shutdown, 1})

      {:error, last_result} ->
        Mix.shell().error("""

        #{Readiness.timeout_diagnostic(last_result, expected, @app_timeout_ms)}
        Check the log file for errors: #{log_file}

        The launched process (pid #{pid}) is still recorded in
        #{Config.metadata_file()} as `state: "starting"` — `mix arbor.stop`
        will target it accurately if it needs to be cleaned up.
        """)

        exit({:shutdown, 1})
    end
  end

  defp node_string_for(host), do: "#{Config.node_name()}@#{host}"

  # `write_pid_file` (legacy compat evidence) and the canonical metadata
  # publish are two *independently fallible* writes — treat both that way.
  # Canonical (metadata) success is required to continue startup; a legacy
  # write failure alone is logged but non-fatal (metadata supersedes the
  # legacy file as the authoritative record from here on). Neither write's
  # exception is allowed to escape unhandled — that would crash Start with
  # the daemon already spawned and nothing on disk to find it by.
  @doc false
  def track_launch(node_string, host, pid, home \\ Config.arbor_home()) do
    legacy_result = write_pid_file_safe(pid, home)

    case write_metadata_safe(node_string, host, pid, home) do
      :ok ->
        # Canonical evidence is present, so startup continues either way —
        # but a legacy-write failure must never be silent. Without this,
        # the operator has no way to know legacy-only tooling has nothing
        # to find for this daemon if canonical metadata is intentionally
        # removed after manual inspection.
        if legacy_result == :error do
          Mix.shell().error("""

          Warning: failed to write the legacy PID file #{Config.pid_file(home)}
          (best-effort compatibility evidence). Canonical metadata at
          #{Config.metadata_file(home)} was published successfully and is
          the authoritative record for this daemon — startup continues
          normally, but legacy-only tooling will not be able to find this
          process via the PID file.
          """)
        end

        :ok

      :error ->
        handle_publish_failure(node_string, pid, legacy_result == :ok, home)
    end
  end

  defp write_pid_file(pid, home) do
    File.write!(Config.pid_file(home), to_string(pid))
  end

  defp write_pid_file_safe(pid, home) do
    write_pid_file(pid, home)
    :ok
  rescue
    _ -> :error
  end

  defp write_metadata_safe(node_string, host, pid, home) do
    Config.write_metadata!(%{node: node_string, host: host, pid: pid, state: :starting}, home)
    :ok
  rescue
    _ -> :error
  end

  # If canonical metadata publish fails, the "never trust a PID alone
  # before signaling it" rule still applies even though we hold this PID
  # first-hand: the process could already have exited and had its PID
  # reused in the window since spawn. `Config.signal_if_verified/3` (the
  # sole boundary in this codebase allowed to deliver `kill <pid>`)
  # re-verifies its exact argv immediately before ever signaling it, and
  # whichever tracking evidence *did* get written successfully (the legacy
  # PID file) is only ever deleted once exit is actually confirmed — never
  # on the strength of merely having sent a signal.
  defp handle_publish_failure(node_string, pid, legacy_preserved?, home) do
    case Config.signal_if_verified(pid, node_string, :sigterm) do
      {:signaled, _check} ->
        if Config.await_exit?(pid, @force_stop_confirm_timeout_ms) do
          if legacy_preserved?, do: File.rm(Config.pid_file(home))

          Mix.shell().error(
            "Failed to publish launch tracking; terminated the verified newly spawned process #{pid}. Nothing left running."
          )
        else
          Mix.shell().error("""

          Failed to publish launch tracking for process #{pid} and sent
          SIGTERM, but its exit was not confirmed after
          #{div(@force_stop_confirm_timeout_ms, 1000)}s. #{evidence_note(pid, legacy_preserved?, home)}
          """)
        end

      {:refused, check} ->
        Mix.shell().error("""

        Failed to publish launch tracking for the newly spawned process
        #{pid}, and its identity could not be re-verified (#{inspect(check)}).
        It was NOT signaled. #{evidence_note(pid, legacy_preserved?, home)}
        """)
    end

    exit({:shutdown, 1})
  end

  defp evidence_note(_pid, true, home) do
    "#{Config.pid_file(home)} has been preserved as legacy evidence — run " <>
      "`mix arbor.status` or inspect the process manually, then " <>
      "`mix arbor.stop` (or a manual kill once confirmed) to clean up."
  end

  defp evidence_note(pid, false, _home) do
    "No tracking evidence could be written for this process at all — " <>
      "locate and inspect pid #{pid} manually (check the log file for context)."
  end

  # Phase 1: node reachability (short bound).
  # Phase 2: application readiness (long cold-start bound).
  defp await_ready(node, expected) do
    node_deadline = System.monotonic_time(:millisecond) + @node_timeout_ms

    case poll_node_reachable(node, node_deadline) do
      :ok ->
        app_deadline = System.monotonic_time(:millisecond) + @app_timeout_ms
        poll_apps_ready(node, expected, app_deadline, :no_observation)

      :timeout ->
        {:error, :node_unreachable}
    end
  end

  defp poll_node_reachable(node, deadline_mono_ms) do
    now = System.monotonic_time(:millisecond)
    remaining = Readiness.remaining_ms(deadline_mono_ms, now)

    cond do
      remaining <= 0 ->
        :timeout

      :net_adm.ping(node) == :pong ->
        :ok

      true ->
        sleep = Readiness.sleep_ms(remaining, @poll_interval_ms)
        if sleep > 0, do: Process.sleep(sleep)
        poll_node_reachable(node, deadline_mono_ms)
    end
  end

  defp poll_apps_ready(node, expected, deadline_mono_ms, last_result) do
    now = System.monotonic_time(:millisecond)

    case Readiness.poll_decision(deadline_mono_ms, now, last_result) do
      :done_ready ->
        :ok

      {:done_timeout, result} ->
        {:error, result}

      {:continue, remaining} ->
        observation = observe_started_apps(node, remaining)
        classified = Readiness.classify_observation(expected, observation)

        case Readiness.poll_decision(
               deadline_mono_ms,
               System.monotonic_time(:millisecond),
               classified
             ) do
          :done_ready ->
            :ok

          {:done_timeout, result} ->
            {:error, result}

          {:continue, remaining_after} ->
            sleep = Readiness.sleep_ms(remaining_after, @poll_interval_ms)
            if sleep > 0, do: Process.sleep(sleep)
            poll_apps_ready(node, expected, deadline_mono_ms, classified)
        end
    end
  end

  # Observe only — never start or force-start applications on the remote node.
  defp observe_started_apps(node, remaining_ms) do
    timeout = Readiness.rpc_timeout_ms(remaining_ms, @rpc_timeout_ms)

    if timeout <= 0 do
      {:error, :rpc_budget_exhausted}
    else
      case :rpc.call(node, :application, :which_applications, [], timeout) do
        {:badrpc, reason} -> {:error, {:badrpc, reason}}
        apps when is_list(apps) -> {:ok, apps}
        other -> {:error, {:unexpected_rpc_result, other}}
      end
    end
  end

  # Keep the last 3 log generations (.1 newest → .3 oldest) so the shell's `> log_file` truncate on
  # start doesn't erase the previous run's log. Shift .2→.3, .1→.2, log→.1; the truncate then makes a
  # fresh log. No-op for a missing/empty log. Best-effort — never block startup on a rename error.
  defp rotate_log(log_file) do
    if File.exists?(log_file) and File.stat!(log_file).size > 0 do
      for n <- 3..1//-1 do
        src = if n == 1, do: log_file, else: "#{log_file}.#{n - 1}"
        dst = "#{log_file}.#{n}"
        if File.exists?(src), do: File.rename(src, dst)
      end
    end
  rescue
    _ -> :ok
  end

  defp resolve_real_paths do
    # Derive the real elixir and mix scripts from the Elixir installation
    # powering this VM. :code.lib_dir(:elixir) returns e.g. ".../lib/elixir",
    # so we go up to the installation root and find bin/elixir and bin/mix —
    # guaranteed to be the real scripts, not version-manager shim binaries.
    elixir_lib = :code.lib_dir(:elixir) |> to_string() |> Path.expand()
    elixir_root = elixir_lib |> Path.dirname() |> Path.dirname()
    real_elixir = Path.join([elixir_root, "bin", "elixir"])
    real_mix = Path.join([elixir_root, "bin", "mix"])

    elixir_path = if File.exists?(real_elixir), do: real_elixir, else: "elixir"
    mix_path = if File.exists?(real_mix), do: real_mix, else: "-S mix"

    {elixir_path, mix_path}
  end
end
