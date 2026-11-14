defmodule Mix.Tasks.Arbor.Agent do
  @moduledoc """
  Manage agent lifecycle via RPC to the running Arbor server.

  All commands execute on the running `arbor_dev@localhost` node.
  Start the server first with `mix arbor.start`.

  ## Usage

      mix arbor.agent                           # list running agents
      mix arbor.agent list                      # same (running only)
      mix arbor.agent list --all                # running + stopped
      mix arbor.agent templates                 # list available templates
      mix arbor.agent start <template>          # create & start from template
      mix arbor.agent resume <name|id>          # resume persisted agent
      mix arbor.agent stop <name|id>            # stop running agent
      mix arbor.agent destroy <name|id>         # delete agent + all data
      mix arbor.agent status <name|id>          # detailed agent status
      mix arbor.agent summary <name|id>         # 2am-rule summary across all 4 domains
      mix arbor.agent chat <name|id> "message"  # send message, print response
      mix arbor.agent auto-start <name|id>      # toggle auto-start on/off

  ## Options

    * `--name` / `-n` — display name (default: template's character name)
    * `--model` / `-m` — model ID (default: the template's model, else
      `ARBOR_DEFAULT_MODEL` from `.env` as written by `mix arbor.doctor --configure`)
    * `--provider` — provider atom (default: the template's provider, else
      `ARBOR_DEFAULT_PROVIDER` from `.env`; e.g. `opencode_zen`, `openrouter`, `acp`)
    * `--auto-start` — set auto-start on creation (with start)
    * `--timeout` — response timeout in seconds (default: 300, with chat;
      capped at 300 by the authenticated delivery path)
    * `--key-file` — local operator key for start, resume and chat (default
      `~/.arbor/operator.key`, created by `mix arbor.user.init`)

  ## How start and resume prove who you are

  `start` and `resume` sign one lifecycle request with the operator key file
  in this process (`Arbor.Agent.lifecycle_request_payload/2`): the operation,
  your principal, and the template, name, provider and model (or the agent id).
  Only the request and its signature go to the server, which verifies them
  against your registered key and runs the one operation with a one-use
  authority (`Arbor.Agent.submit_signed_lifecycle_request/4`). Your private key
  never leaves this machine's key file. `stop` and `status` need no key.
    * `--all` — show both running and stopped agents (with list)
    * `--yes` — skip the destroy confirmation (required when stdin is not a
      TTY, e.g. scripted or non-interactive ssh runs)
  """

  use Mix.Task

  # `config/runtime.exs` is applied by the `app.config` task, which `mix run` and
  # `mix test` invoke for you. A custom task that starts applications itself does
  # NOT get it, so every runtime-configured value — including everything loaded
  # from `.env` — was nil here.
  #
  # Concretely: `ARBOR_DEFAULT_PROVIDER` is mapped to
  # `config :arbor_ai, default_provider:` in runtime.exs, so without this
  # `LLMDefaults.default_provider/1` fell through to its last-resort constants
  # (`:openrouter` / "openai/gpt-oss-120b:free") and every agent started from the
  # CLI was pinned to OpenRouter — regardless of what the user configured, and
  # even after the starter template stopped declaring a provider.
  #
  # Same defect as 246c73b5b, which fixed it for `mix arbor.eval.task`.
  @requirements ["app.config"]

  # Arbor.Agent.IdentityAliasProof stays fully qualified: the chat fallback
  # counterwitness test recompiles this file with that exact name rewritten.
  alias Arbor.Agent.LifecycleRequestCore
  alias Arbor.Agent.LLMDefaults
  alias Mix.Tasks.Arbor.Helpers, as: Config

  @shortdoc "Manage agent lifecycle (start, stop, chat, status)"

  # MessageFacade caps delivery at @max_timeout_ms and REJECTS anything larger
  # rather than clamping, so a CLI default above this bound would be an outright
  # `:invalid_timeout`. That bound is sized for a human chat turn waiting on an
  # LLM, not for agent-to-agent delivery.
  @authenticated_delivery_max_ms 300_000

  # A turn that calls tools runs a multi-turn loop — model, tool, model again —
  # so the wall clock is a multiple of one completion, not one. 60s expired
  # mid-loop and reported `:delivery_ambiguous` while the turn was still running
  # server-side (found 2026-08-25: a memory_recall turn needed ~75s). Default to
  # the delivery ceiling so the common tool-using turn is not cut off; pass a
  # smaller `--timeout` to fail faster.
  @default_chat_timeout_s div(@authenticated_delivery_max_ms, 1_000)

  @switches [
    name: :string,
    model: :string,
    provider: :string,
    auto_start: :boolean,
    timeout: :integer,
    key_file: :string,
    all: :boolean,
    yes: :boolean
  ]

  @aliases [
    n: :name,
    m: :model
  ]

  @impl Mix.Task
  def run(args) do
    {opts, args, _} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    case args do
      [] -> do_list(opts)
      ["list"] -> do_list(opts)
      ["templates"] -> do_list_templates()
      ["start"] -> do_start_usage()
      ["start", template | _] -> do_start(template, opts)
      ["resume", ref | _] -> do_resume(ref, opts)
      ["stop", ref | _] -> do_stop(ref)
      ["destroy", ref | _] -> do_destroy(ref, opts)
      ["status", ref | _] -> do_status(ref)
      ["summary", ref | _] -> do_summary(ref)
      ["chat", ref, message | _] -> do_chat(ref, message, opts)
      ["chat", ref] -> do_chat_interactive(ref, opts)
      ["auto-start", ref | _] -> do_auto_start(ref)
      _ -> Mix.shell().error("Unknown command. Run `mix help arbor.agent` for usage.")
    end
  end

  # ── List ──────────────────────────────────────────────────────────────

  defp do_list(opts) do
    ensure_server!()
    {:ok, running} = remote(Arbor.Agent.Registry, :list, [])
    running_ids = MapSet.new(running, & &1.agent_id)

    agents =
      if opts[:all] do
        profiles = remote(Arbor.Agent.Lifecycle, :list_agents, [])

        # Merge: running agents + stopped profiles
        running_entries =
          Enum.map(running, fn entry ->
            profile = Enum.find(profiles, &(&1.agent_id == entry.agent_id))

            %{
              agent_id: entry.agent_id,
              name: (profile && profile.display_name) || "?",
              template: (profile && format_template(profile.template)) || "?",
              status: "running",
              model: Arbor.Agent.model_id_from_metadata(entry.metadata) || "?"
            }
          end)

        stopped_entries =
          profiles
          |> Enum.reject(&MapSet.member?(running_ids, &1.agent_id))
          |> Enum.map(fn p ->
            %{
              agent_id: p.agent_id,
              name: p.display_name || "?",
              template: format_template(p.template),
              status: "stopped",
              model: Arbor.Agent.model_id_from_metadata(p.metadata) || "-"
            }
          end)

        running_entries ++ stopped_entries
      else
        # The registry entry carries no template, so the running-only list
        # printed "?" in TEMPLATE for every agent. Look the profile up the same
        # way `--all` does.
        profiles = remote(Arbor.Agent.Lifecycle, :list_agents, [])

        Enum.map(running, fn entry ->
          profile = Enum.find(profiles, &(&1.agent_id == entry.agent_id))

          %{
            agent_id: entry.agent_id,
            name:
              Map.get(entry.metadata, :display_name) || (profile && profile.display_name) ||
                "?",
            template: (profile && format_template(profile.template)) || "?",
            status: "running",
            model: Arbor.Agent.model_id_from_metadata(entry.metadata) || "?"
          }
        end)
      end

    if agents == [] do
      Mix.shell().info("No agents found.")
      unless opts[:all], do: Mix.shell().info("Use --all to include stopped agents.")
    else
      Mix.shell().info("Agents (#{length(agents)}):\n")

      header =
        String.pad_trailing("AGENT ID", 24) <>
          String.pad_trailing("NAME", 18) <>
          String.pad_trailing("TEMPLATE", 16) <>
          String.pad_trailing("STATUS", 10) <>
          "MODEL"

      Mix.shell().info(header)
      Mix.shell().info(String.duplicate("-", 90))

      for a <- agents do
        id = String.pad_trailing(truncate(a.agent_id, 22), 24)
        name = String.pad_trailing(truncate(a.name, 16), 18)
        template = String.pad_trailing(truncate(a.template, 14), 16)
        status = String.pad_trailing(a.status, 10)
        model = truncate(a.model, 30)
        Mix.shell().info("#{id}#{name}#{template}#{status}#{model}")
      end
    end
  end

  # ── Start ─────────────────────────────────────────────────────────────

  defp do_start(template_name, opts) do
    ensure_server!()

    case start_operator(template_name, opts, &remote/3) do
      :ok -> :ok
      :error -> exit({:shutdown, 1})
    end
  end

  @doc false
  # Everything `start` does after the server check. `remote` performs one call
  # on the server: `remote/3` here, a peer-node call in tests. The request is
  # signed in THIS process from the operator key file; only the request and
  # its signature cross to the server, which verifies it against the
  # operator's registered key. Returns `:ok`, or `:error` after reporting.
  @spec start_operator(String.t(), keyword(), (module(), atom(), list() -> term())) ::
          :ok | :error
  def start_operator(template_name, opts, remote) when is_function(remote, 3) do
    case remote.(Arbor.Agent.TemplateStore, :get, [template_name]) do
      {:ok, template_data} ->
        start_from_template(template_name, template_data, opts, remote)

      {:error, :not_found} ->
        Mix.shell().error("Template '#{template_name}' not found.")
        print_available_templates(remote)
        :error

      other ->
        Mix.shell().error("Failed to load template '#{template_name}': #{inspect(other)}")
        :error
    end
  end

  defp start_from_template(template_name, template_data, opts, remote) do
    display_name =
      opts[:name] || get_in(template_data, ["character", "name"]) || template_name

    # Honor the template's declared model/provider (metadata.model / metadata.provider) when no
    # explicit --model/--provider is given, before the system default. The roster's templates
    # (e.g. test_agent → gpt-5.5/openai_oauth) rely on this; the task previously dropped the
    # template's model and always used LLMDefaults, so a started agent ran the wrong model.
    model_id =
      opts[:model] ||
        get_in(template_data, ["metadata", "model"]) ||
        LLMDefaults.default_model()

    provider =
      parse_provider(
        opts[:provider] ||
          get_in(template_data, ["metadata", "provider"]) ||
          to_string(LLMDefaults.default_provider())
      )

    with :ok <- acknowledge_keyless(provider),
         request = %{
           operation: :start,
           template: template_name,
           display_name: display_name,
           provider: Atom.to_string(provider),
           model: model_id
         },
         {:ok, result} <- submit_lifecycle(request, opts, remote) do
      report_started(display_name, result, opts)
    end
  end

  defp acknowledge_keyless(provider) do
    case maybe_acknowledge_keyless(provider) do
      :ok ->
        :ok

      {:error, :disclosure_not_acknowledged} ->
        Mix.shell().error(
          "OpenCode Zen was not started: the data-disclosure warning was not acknowledged."
        )

        :error
    end
  end

  defp report_started(display_name, {:ok, agent_id, _pid, status}, opts) do
    verb = if status == :created, do: "Started", else: "Resumed"
    Mix.shell().info("#{verb} agent '#{display_name}' (#{agent_id})")

    if opts[:auto_start] do
      auto_start_unavailable(display_name)
    else
      :ok
    end
  end

  # Sign `request` with the operator key file and submit it. The private key
  # is read here and never sent; the server sees the request and signature.
  defp submit_lifecycle(request, opts, remote) do
    key_path = Arbor.Agent.IdentityAliasProof.key_file_path(opts)

    with {:ok, principal} <- operator_principal(key_path),
         {:ok, signed} <- sign_lifecycle_request(key_path, principal, request) do
      case remote.(Arbor.Agent, :submit_signed_lifecycle_request, [principal, request, signed]) do
        {:ok, :pending_approval, proposal_id} ->
          Mix.shell().error(
            "Approval required before this runs (proposal #{proposal_id}). Nothing was started."
          )

          :error

        {:ok, _agent_id, _pid, _status} = started ->
          {:ok, started}

        {:ok, _agent_id, _pid} = resumed ->
          {:ok, resumed}

        {:error, reason} ->
          Mix.shell().error(lifecycle_error(reason, principal))
          :error

        other ->
          Mix.shell().error("Unexpected reply from the server: #{inspect(other)}")
          :error
      end
    end
  end

  defp operator_principal(key_path) do
    case Arbor.Security.key_file_principal(key_path) do
      {:ok, principal} ->
        {:ok, principal}

      {:error, _reason} ->
        Mix.shell().error(
          "Starting an agent requires your operator key (#{key_path}). " <>
            "Run mix arbor.user.init or supply --key-file <path>."
        )

        :error
    end
  end

  defp sign_lifecycle_request(key_path, principal, request) do
    with {:ok, payload} <- Arbor.Agent.lifecycle_request_payload(principal, request),
         {:ok, ^principal, signed} <- sign_key_file_request(key_path, payload) do
      {:ok, signed}
    else
      {:ok, _other, _signed} ->
        Mix.shell().error("Operator key changed while signing (#{key_path}).")
        :error

      {:error, reason} ->
        Mix.shell().error("Could not sign the request with #{key_path}: #{inspect(reason)}")
        :error
    end
  end

  defp lifecycle_error({:unauthorized, :capability_mutation_unauthorized}, principal),
    do: """
    #{principal} may not create or start agents here (:capability_mutation_unauthorized).
    The first administrator is made by `mix arbor.user.init` (genesis).
    """

  defp lifecycle_error({:unauthorized, reason}, principal),
    do: "The server refused the signed request from #{principal}: #{inspect(reason)}"

  defp lifecycle_error(reason, _principal), do: "Failed to start agent: #{inspect(reason)}"

  defp do_list_templates do
    ensure_server!()
    print_available_templates()
  end

  defp do_start_usage do
    ensure_server!()
    Mix.shell().info("Usage: mix arbor.agent start <template> [--name NAME] [--model MODEL]\n")
    print_available_templates()
  end

  defp print_available_templates(remote \\ &remote/3) do
    templates = remote.(Arbor.Agent.TemplateStore, :list, [])

    if templates == [] do
      Mix.shell().info(
        "No templates available. Run `mix arbor.template seed` to create builtins."
      )
    else
      Mix.shell().info("Available templates:\n")

      header =
        String.pad_trailing("NAME", 20) <>
          "DESCRIPTION"

      Mix.shell().info(header)
      Mix.shell().info(String.duplicate("-", 70))

      for t <- templates do
        name = String.pad_trailing(t["name"] || "?", 20)
        desc = truncate(t["description"] || "", 36)
        Mix.shell().info("#{name}#{desc}")
      end

      Mix.shell().info("\nStart with: mix arbor.agent start <name>")
    end
  end

  # ── Resume ────────────────────────────────────────────────────────────

  defp do_resume(ref, opts) do
    ensure_server!()

    case resume_operator(ref, opts, &remote/3) do
      :ok -> :ok
      :error -> exit({:shutdown, 1})
    end
  end

  @doc false
  # Everything `resume` does after the server check; see `start_operator/3`.
  @spec resume_operator(String.t(), keyword(), (module(), atom(), list() -> term())) ::
          :ok | :error
  def resume_operator(ref, opts, remote) when is_function(remote, 3) do
    case find_profile(ref, remote) do
      {:ok, profile} ->
        request = %{operation: :resume, agent_id: profile.agent_id}

        with {:ok, {:ok, agent_id, _pid}} <- submit_lifecycle(request, opts, remote) do
          Mix.shell().info("Resumed agent '#{profile.display_name}' (#{agent_id})")
          :ok
        end

      :not_found ->
        Mix.shell().error(
          "Agent '#{ref}' not found. Use `mix arbor.agent list --all` to see all agents."
        )

        :error
    end
  end

  # ── Stop ──────────────────────────────────────────────────────────────

  defp do_stop(ref) do
    ensure_server!()

    case find_running(ref) do
      {:ok, agent_id, name} ->
        case remote(Arbor.Agent.Manager, :stop_agent, [agent_id]) do
          :ok -> Mix.shell().info("Stopped agent '#{name}' (#{agent_id})")
          {:error, reason} -> Mix.shell().error("Failed to stop: #{inspect(reason)}")
        end

      :not_found ->
        Mix.shell().error("Running agent '#{ref}' not found.")
    end
  end

  # ── Destroy ───────────────────────────────────────────────────────────

  defp do_destroy(ref, opts) do
    ensure_server!()

    case find_profile(ref) do
      {:ok, profile} ->
        if opts[:yes] ||
             confirm_destructive?(
               "Destroy agent '#{profile.display_name}' (#{profile.agent_id})? This deletes all data. [yN] "
             ) do
          # Stop first if running
          remote(Arbor.Agent.Manager, :stop_agent, [profile.agent_id])
          remote(Arbor.Agent.Lifecycle, :destroy, [profile.agent_id])
          Mix.shell().info("Destroyed agent '#{profile.display_name}'.")
        else
          Mix.shell().info("Cancelled.")
        end

      :not_found ->
        Mix.shell().error("Agent '#{ref}' not found.")
    end
  end

  # ── Status ────────────────────────────────────────────────────────────

  # ── Summary (the "2am rule") ──────────────────────────────────────────
  #
  # Calls `Arbor.Agent.summary/1` via RPC. That function is the single
  # cross-domain Convert pulling identity, config, authority, activity,
  # and telemetry into one map. Designed for "what's going on with this
  # agent right now?" inspection at 2am when something's broken.
  defp do_summary(ref) do
    ensure_server!()

    agent_id =
      case find_profile(ref) do
        {:ok, p} -> p.agent_id
        :not_found -> ref
      end

    case remote(Arbor.Agent, :summary, [agent_id]) do
      {:ok, s} ->
        Mix.shell().info("Agent Summary — #{s.display_name}")
        Mix.shell().info(String.duplicate("=", 50))
        Mix.shell().info("  Agent ID:        #{s.agent_id}")
        Mix.shell().info("  Status:          #{s.status}")
        Mix.shell().info("")
        Mix.shell().info("  Template:        #{format_template(s.template)}")
        Mix.shell().info("  Model:           #{s.model || "(unknown)"}")
        Mix.shell().info("")
        Mix.shell().info("  Turns:           #{format_value(s.turn_count)}")
        Mix.shell().info("  Active Goals:    #{s.active_goals_count}")
        Mix.shell().info("")
        Mix.shell().info("  Session Cost:    #{format_cost(s.session_cost)}")
        Mix.shell().info("  Avg Latency:     #{format_latency(s.avg_latency_ms)}")

      {:error, :not_found} ->
        Mix.shell().error("Agent '#{ref}' not found.")
    end
  end

  defp format_value(nil), do: "(none)"
  defp format_value(v), do: to_string(v)

  defp format_cost(nil), do: "(none)"
  defp format_cost(c) when is_number(c), do: "$#{:erlang.float_to_binary(c / 1, decimals: 4)}"
  defp format_cost(c), do: to_string(c)

  defp format_latency(nil), do: "(none)"
  defp format_latency(ms), do: "#{ms}ms"

  defp do_status(ref) do
    ensure_server!()

    profile =
      case find_profile(ref) do
        {:ok, p} -> p
        :not_found -> nil
      end

    {:ok, running} = remote(Arbor.Agent.Registry, :list, [])

    running_entry =
      if profile do
        Enum.find(running, &(&1.agent_id == profile.agent_id))
      else
        Enum.find(running, fn e ->
          e.agent_id == ref or Map.get(e.metadata, :display_name) == ref
        end)
      end

    cond do
      profile == nil and running_entry == nil ->
        Mix.shell().error("Agent '#{ref}' not found.")

      profile != nil ->
        Mix.shell().info("Agent Status")
        Mix.shell().info(String.duplicate("=", 40))
        Mix.shell().info("  Agent ID:     #{profile.agent_id}")
        Mix.shell().info("  Display Name: #{profile.display_name}")
        Mix.shell().info("  Template:     #{format_template(profile.template)}")
        Mix.shell().info("  Auto Start:   #{profile.auto_start}")

        if running_entry do
          Mix.shell().info("  Status:       running")
          Mix.shell().info("  PID:          #{inspect(running_entry.pid)}")
          model = Arbor.Agent.model_id_from_metadata(running_entry.metadata)
          if model, do: Mix.shell().info("  Model:        #{model}")

          provider =
            get_in(running_entry.metadata, [:model_config, :provider]) ||
              get_in(running_entry.metadata, ["model_config", "provider"])

          if provider, do: Mix.shell().info("  Provider:     #{provider}")

          uptime_ms = System.monotonic_time(:millisecond) - (running_entry.registered_at || 0)

          if running_entry.registered_at,
            do: Mix.shell().info("  Uptime:       #{format_duration(uptime_ms)}")
        else
          Mix.shell().info("  Status:       stopped")
          model = Arbor.Agent.model_id_from_metadata(profile.metadata)
          if model, do: Mix.shell().info("  Model:        #{model}")
          Mix.shell().info("\n  Resume with: mix arbor.agent resume #{profile.display_name}")
        end

      running_entry != nil ->
        Mix.shell().info("Agent Status (no profile)")
        Mix.shell().info(String.duplicate("=", 40))
        Mix.shell().info("  Agent ID:     #{running_entry.agent_id}")
        Mix.shell().info("  Status:       running")
        Mix.shell().info("  PID:          #{inspect(running_entry.pid)}")
        Mix.shell().info("  Module:       #{running_entry.module}")
    end
  end

  # ── Chat ──────────────────────────────────────────────────────────────

  defp do_chat(ref, message, opts) do
    key_path = Arbor.Agent.IdentityAliasProof.key_file_path(opts)

    # Validate locally before opening distribution. A missing or invalid key
    # cannot select the unauthenticated Manager compatibility route.
    case Arbor.Security.key_file_principal(key_path) do
      {:ok, _principal} ->
        :ok

      {:error, _reason} ->
        Mix.shell().error(
          "Chat requires a valid private operator key. Run mix arbor.user.init or supply --key-file <path>."
        )

        exit({:shutdown, 1})
    end

    ensure_server!()
    timeout = (opts[:timeout] || @default_chat_timeout_s) * 1_000
    effective_s = div(min(timeout, @authenticated_delivery_max_ms), 1_000)

    case find_running(ref) do
      {:ok, agent_id, _name} ->
        # The locally signed proof below supplies the exact sender identity.
        envelope = Arbor.Contracts.Session.UserMessage.from_cli(message, "CLI")

        case signed_chat_send(key_path, agent_id, envelope, timeout) do
          {:ok, response} ->
            Mix.shell().info(response)

          {:error, :timeout} ->
            # Report the EFFECTIVE wait, not the requested one — the signed
            # delivery path clamps to @authenticated_delivery_max_ms.
            Mix.shell().error("Response timed out after #{effective_s}s.")
            exit({:shutdown, 1})

          {:error, reason} ->
            # A failed turn used to exit 0, so scripts (and the quickstart's
            # "first reply" check) could not tell a reply from a failure.
            Mix.shell().error("Chat failed: #{inspect(reason)}")
            Mix.shell().error("  Server log: #{Config.log_file()}")
            exit({:shutdown, 1})
        end

      :not_found ->
        # Check if it exists but is stopped
        case find_profile(ref) do
          {:ok, _} ->
            Mix.shell().error(
              "Agent '#{ref}' is not running. Resume with: mix arbor.agent resume #{ref}"
            )

          :not_found ->
            Mix.shell().error("Agent '#{ref}' not found.")
        end

        exit({:shutdown, 1})
    end
  end

  defp do_chat_interactive(ref, opts) do
    Mix.shell().error("Usage: mix arbor.agent chat <name|id> \"message\"")
    Mix.shell().info("Example: mix arbor.agent chat #{ref} \"hello\"")
    _ = opts
  end

  # ── Auto-Start ────────────────────────────────────────────────────────

  defp do_auto_start(ref) do
    ensure_server!()

    case find_profile(ref) do
      {:ok, profile} ->
        auto_start_unavailable!(profile.display_name)

      :not_found ->
        Mix.shell().error("Agent '#{ref}' not found.")
    end
  end

  # `Manager.set_auto_start/3` needs the operator's owner-process-bound
  # `:actor_authority`: enabling delegates per-agent start rights to the system
  # lifecycle principal with it, and disabling revokes them. An authority cannot
  # cross the RPC boundary, and no key-file proof path exists for this mutation
  # yet (only single capability grants have one), so this CLI fails closed
  # rather than calling the authority-less arity, which would only be refused.
  defp auto_start_unavailable!(display_name) do
    :error = auto_start_unavailable(display_name)
    exit({:shutdown, 1})
  end

  defp auto_start_unavailable(display_name) do
    Mix.shell().error("""
    Auto-start was not changed for '#{display_name}'.
    Changing auto-start delegates (or revokes) the agent's start rights for the
    system lifecycle principal, which needs your signing authority in the server
    process. This CLI has no signed key-file path for that mutation yet. Use an
    authenticated in-server caller of Arbor.Agent.set_auto_start/3 (with
    actor_authority:) instead.
    """)

    :error
  end

  # ── Shared Plumbing ──────────────────────────────────────────────────

  defp ensure_server! do
    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor server is not running. Start with: mix arbor.start")
      exit({:shutdown, 1})
    end
  end

  # Deliver a terminal turn through the AUTHENTICATED path, proving the operator
  # by SIGNING with the key `mix arbor.user.init` wrote.
  #
  # `Manager.chat/3` predates engagements and mints no `%TurnAuthority{}`, so no
  # disclosure capability is issued and any external-provider egress dies at the
  # gate with `:initial_denied`. `Arbor.Agent.send_message/4` issues a delivery
  # receipt and reaches `Session.send_authenticated_message/3`, which consumes
  # it, mints the authority, and resolves the principal's canonical engagement.
  #
  # A signed request rather than a session token: the CLI holds
  # `~/.arbor/operator.key` and already signs with it in `mix arbor.user.link`.
  # A session token is a stand-in for possession, useful when the holder cannot
  # sign; a one-shot command can, and gains nothing from session state it would
  # have to create, carry, and revoke.
  defp signed_chat_send(key_path, agent_id, envelope, timeout) do
    effective = min(timeout, @authenticated_delivery_max_ms)

    if effective < timeout do
      Mix.shell().info(
        "  (timeout capped at #{div(effective, 1000)}s by the authenticated delivery path)"
      )
    end

    # Sign the exact final envelope using the same versioned binding the host
    # verifies before authentication. A key replacement between reads fails.
    with {:ok, principal} <- Arbor.Security.key_file_principal(key_path),
         envelope = %{envelope | sender_id: principal},
         {:ok, payload} <- Arbor.Agent.message_request_payload(principal, agent_id, envelope),
         {:ok, ^principal, signed} <- sign_key_file_request(key_path, payload) do
      remote(Arbor.Agent, :send_message, [
        principal,
        agent_id,
        envelope,
        [timeout: effective, signed_request: signed]
      ])
    else
      {:error, reason} ->
        {:error, "could not sign as the local operator using #{key_path}: #{inspect(reason)}"}

      _ ->
        {:error, "operator key changed while signing"}
    end
  end

  defp sign_key_file_request(path, payload) do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, io_device} ->
        try do
          Arbor.Security.sign_key_file_request(io_device, payload)
        after
          :file.close(io_device)
        end

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp remote(mod, fun, args) do
    Config.rpc!(Config.full_node_name(), mod, fun, args)
  end

  defp find_profile(ref, remote \\ &remote/3) do
    profiles = remote.(Arbor.Agent.Lifecycle, :list_agents, [])

    match =
      Enum.find(profiles, fn p ->
        p.agent_id == ref or
          p.display_name == ref or
          (p.character && p.character.name == ref)
      end)

    if match, do: {:ok, match}, else: :not_found
  end

  defp find_running(ref) do
    {:ok, running} = remote(Arbor.Agent.Registry, :list, [])

    entry =
      Enum.find(running, fn e ->
        e.agent_id == ref or Map.get(e.metadata, :display_name) == ref
      end)

    if entry do
      name = Map.get(entry.metadata, :display_name, entry.agent_id)
      {:ok, entry.agent_id, name}
    else
      # Try by profile name → agent_id → registry lookup
      case find_profile(ref) do
        {:ok, profile} ->
          match = Enum.find(running, &(&1.agent_id == profile.agent_id))
          if match, do: {:ok, profile.agent_id, profile.display_name}, else: :not_found

        :not_found ->
          :not_found
      end
    end
  end

  defp maybe_acknowledge_keyless(:opencode_zen),
    do: Arbor.LLM.OpenCodeZen.prompt_acknowledgement()

  defp maybe_acknowledge_keyless(_provider), do: :ok

  # The provider table lives in LifecycleRequestCore, because the server
  # resolves the same names from the signed request. Aliases stay here.
  defp parse_provider(str) when is_binary(str) do
    canonical =
      case str do
        "lm_studio" -> "lmstudio"
        "opencode-zen" -> "opencode_zen"
        "opencode-free" -> "opencode_zen"
        other -> other
      end

    case LifecycleRequestCore.provider_atom(canonical) do
      {:ok, provider} -> provider
      {:error, :unknown_provider} -> Mix.raise("Unknown provider: #{str}")
    end
  end

  defp format_template(nil), do: "-"
  defp format_template(t) when is_binary(t), do: t
  defp format_template(t) when is_atom(t), do: Atom.to_string(t)

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max - 3) <> "..."

  defp format_duration(ms) when ms < 0, do: "?"

  defp format_duration(ms) do
    total_seconds = div(ms, 1000)
    days = div(total_seconds, 86_400)
    hours = div(rem(total_seconds, 86_400), 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    seconds = rem(total_seconds, 60)

    parts =
      [{days, "d"}, {hours, "h"}, {minutes, "m"}, {seconds, "s"}]
      |> Enum.reject(fn {val, _} -> val == 0 end)
      |> Enum.map(fn {val, unit} -> "#{val}#{unit}" end)

    case parts do
      [] -> "0s"
      _ -> Enum.join(parts, " ")
    end
  end

  # Like Mix.shell().yes?/1 but defaults to No (safer for destructive ops).
  #
  # `IO.gets/1` returns `:eof` when stdin is not a TTY — a non-interactive ssh
  # session, CI, or any scripted run. Passing that to `String.trim/1` raised a
  # raw FunctionClauseError, so a destructive command crashed with a stacktrace
  # instead of declining. Treat anything that is not a real answer as "no", and
  # point at the flag that makes scripted use possible.
  defp confirm_destructive?(prompt) do
    case IO.gets(prompt) do
      answer when is_binary(answer) ->
        String.downcase(String.trim(answer)) in ["y", "yes"]

      _eof_or_error ->
        Mix.shell().error(
          "Cannot confirm: stdin is not interactive. Re-run with --yes to skip this prompt."
        )

        false
    end
  end
end
