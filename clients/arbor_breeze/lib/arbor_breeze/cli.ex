defmodule ArborBreeze.CLI do
  @moduledoc "Terminal conversation entrypoint and explicit signed operator commands."
  alias Arbor.Client
  alias ArborBreeze.{Config, Controller, TerminalText, View}

  @aliases [a: :agent, u: :url, k: :key]

  @switches [
    agent: :string,
    url: :string,
    key: :string,
    name: :string,
    model: :string,
    help: :boolean
  ]
  @commands %{
    "agents" => :agents,
    "resolve" => :resolve,
    "aliases" => :aliases,
    "alias" => :alias,
    "unalias" => :unalias,
    "new" => :new,
    "start" => :start,
    "stop" => :stop
  }

  def main(argv) do
    case resolve(argv) do
      :help ->
        IO.puts(usage())

      {:ok, options} ->
        case run(options) do
          :ok ->
            :ok

          {:error, reason} ->
            IO.puts(:stderr, "arbor-tui: " <> error_message(reason))
            System.halt(1)
        end

      {:error, :invalid_options} ->
        IO.puts(:stderr, usage())
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "arbor-tui: " <> error_message(reason))
        System.halt(1)
    end
  end

  @doc "Parse arguments without consulting files or environment preferences."
  def parse(argv) do
    case parse_arguments(argv) do
      {:ok, options} -> {:ok, Keyword.put_new(options, :url, "http://127.0.0.1:4000")}
      other -> other
    end
  end

  @doc "Resolve non-credential preferences and validate the destination before authentication."
  def resolve(argv, sources \\ nil) do
    case parse_arguments(argv) do
      {:ok, options} ->
        with {:ok, options} <- Config.resolve(options, sources), do: prepare(options)

      other ->
        other
    end
  end

  defp parse_arguments(argv) when is_list(argv) and length(argv) <= 16 do
    if Enum.all?(argv, &argument?/1) and unique_switches?(argv) and
         Enum.reduce(argv, 0, &(byte_size(&1) + &2)) <= 8_192 do
      {options, positional, invalid} =
        OptionParser.parse(argv, strict: @switches, aliases: @aliases)

      cond do
        invalid != [] or length(Keyword.keys(options)) != length(Enum.uniq(Keyword.keys(options))) ->
          {:error, :invalid_options}

        options[:help] == true and positional == [] ->
          :help

        options[:help] ->
          {:error, :invalid_options}

        true ->
          validate(options, positional)
      end
    else
      {:error, :invalid_options}
    end
  end

  defp parse_arguments(_), do: {:error, :invalid_options}

  defp unique_switches?(argv) do
    switches =
      Enum.flat_map(argv, fn arg ->
        flag = arg |> String.split("=", parts: 2) |> hd()

        case flag do
          "-a" ->
            ["--agent"]

          "-u" ->
            ["--url"]

          "-k" ->
            ["--key"]

          "--no-help" ->
            ["--help"]

          value when value in ["--agent", "--url", "--key", "--name", "--model", "--help"] ->
            [value]

          _ ->
            []
        end
      end)

    length(switches) == length(Enum.uniq(switches))
  end

  defp validate(options, []) do
    cond do
      Keyword.has_key?(options, :name) or Keyword.has_key?(options, :model) ->
        {:error, :invalid_options}

      Keyword.has_key?(options, :agent) and not is_binary(options[:agent]) ->
        {:error, :agent_required}

      Keyword.has_key?(options, :agent) and not target?(options[:agent], options[:key]) ->
        {:error, :agent_required}

      true ->
        {:ok,
         options
         |> Keyword.put(:operation, :chat)}
    end
  end

  defp validate(options, [command | args]) do
    operation = @commands[command]

    cond do
      is_nil(operation) or Keyword.has_key?(options, :agent) ->
        {:error, :invalid_options}

      not is_binary(options[:key]) or options[:key] == "" ->
        {:error, :signed_key_required}

      operation != :new and
          (Keyword.has_key?(options, :name) or Keyword.has_key?(options, :model)) ->
        {:error, :invalid_options}

      not command_args?(operation, args) ->
        {:error, :invalid_options}

      true ->
        {:ok,
         options
         |> Keyword.put(:operation, operation)
         |> Keyword.put(:arguments, args)}
    end
  end

  defp command_args?(op, args) when op in [:agents, :aliases], do: args == []

  defp command_args?(:alias, [name, target]),
    do: bounded_text?(name, 128) and bounded_text?(target, 256)

  defp command_args?(op, [target]) when op in [:resolve, :unalias, :new, :start, :stop],
    do: bounded_text?(target, 256)

  defp command_args?(_, _), do: false
  defp target?(target, key) when is_binary(key) and key != "", do: bounded_text?(target, 256)

  defp target?(target, nil),
    do: bounded_text?(target, 256) and Regex.match?(~r/\Aagent_[A-Za-z0-9_-]+\z/, target)

  defp target?(_, _), do: false

  defp argument?(text) when is_binary(text) and byte_size(text) <= 2_048,
    do: String.valid?(text) and not Regex.match?(~r/[\x00-\x1f\x7f-\x9f]/u, text)

  defp argument?(_), do: false

  defp bounded_text?(text, limit),
    do: argument?(text) and byte_size(text) in 1..limit and String.trim(text) != ""

  # Trusted injection is for embedding/testing, never a command-line option.
  # The native callback receives only the owned controller, not key material.
  def run(options, client \\ Client, native \\ &native_run/1) do
    with {:ok, options} <- prepare(options) do
      case options[:operation] do
        :chat -> run_chat(options, client, native)
        _ -> run_operator(options, client)
      end
    end
  end

  defp prepare(options) do
    if valid_run_options?(options) do
      policy = if options[:key], do: :signed, else: :session

      with {:ok, origin} <- Client.gateway_origin(options[:url], policy),
           do: {:ok, Keyword.put(options, :url, origin)}
    else
      {:error, :invalid_options}
    end
  end

  defp valid_run_options?(options) when is_list(options) do
    if Keyword.keyword?(options) and length(options) <= 7 do
      operation = options[:operation]
      allowed = [:operation, :arguments, :url, :key, :name, :model, :agent]

      Enum.all?(Keyword.keys(options), &(&1 in allowed)) and
        length(Enum.uniq(Keyword.keys(options))) == length(options) and
        argument?(options[:url]) and
        case operation do
          :chat ->
            (not Keyword.has_key?(options, :agent) or target?(options[:agent], options[:key])) and
              (is_nil(options[:key]) or (argument?(options[:key]) and options[:key] != "")) and
              not Keyword.has_key?(options, :arguments) and
              not Keyword.has_key?(options, :name) and not Keyword.has_key?(options, :model)

          op when op in [:agents, :resolve, :aliases, :alias, :unalias, :new, :start, :stop] ->
            argument?(options[:key]) and options[:key] != "" and
              not Keyword.has_key?(options, :agent) and command_args?(op, options[:arguments]) and
              (op == :new or
                 (not Keyword.has_key?(options, :name) and not Keyword.has_key?(options, :model))) and
              Enum.all?(Keyword.take(options, [:name, :model]), fn {_, value} ->
                bounded_text?(value, 256)
              end)

          _ ->
            false
        end
    else
      false
    end
  end

  defp valid_run_options?(_), do: false

  defp run_chat(options, client, native) do
    if options[:agent] do
      with {:ok, target, authentication, cleanup} <- authenticate(options, client) do
        gateway_options = [target: target, gateway_url: options[:url]] ++ authentication

        run_controller(
          [
            gateway_options: gateway_options,
            workspace_options: Keyword.put(gateway_options, :client, client),
            on_close: cleanup
          ],
          native
        )
      end
    else
      authentication =
        if options[:key], do: load_identity(client, options[:key]), else: {:ok, nil}

      with {:ok, identity} <- authentication do
        workspace = [gateway_url: options[:url], client: client]
        workspace = if identity, do: Keyword.put(workspace, :identity, identity), else: workspace
        run_controller([workspace_options: workspace], native)
      end
    end
  end

  defp run_controller(options, native) do
    case Controller.start(options) do
      {:ok, controller} ->
        try do
          result = native.(controller)

          case Controller.close(controller) do
            :ok -> result
            _ -> {:error, :cleanup_unconfirmed}
          end
        catch
          kind, reason ->
            Controller.close(controller)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      _ ->
        {:error, :conversation_unavailable}
    end
  end

  defp native_run(controller) do
    Breeze.Server.run(
      view: View,
      start_opts: [controller: controller],
      logger: :replace,
      paste_max_bytes: 32_768,
      reload: false,
      inspector: false
    )
  end

  defp authenticate(options, client) do
    case options[:key] do
      path when is_binary(path) ->
        with {:ok, identity} <- load_identity(client, path),
             {:ok, target} <- client.resolve_agent(identity, options[:url], options[:agent]),
             do: {:ok, target, [identity: identity], fn -> :ok end}

      nil ->
        with {:ok, authentication, cleanup} <-
               device_login(client, options[:url], options[:agent]),
             do: {:ok, options[:agent], authentication, cleanup}
    end
  end

  defp load_identity(client, path) do
    case client.load_key(path) do
      {:ok, identity} -> {:ok, identity}
      _ -> {:error, :invalid_identity}
    end
  end

  defp run_operator(options, client) do
    with {:ok, identity} <- load_identity(client, options[:key]),
         {:ok, result} <- operator_request(client, identity, options) do
      IO.puts(operator_output(options[:operation], result))
      :ok
    end
  end

  defp operator_request(client, identity, options) do
    url = options[:url]

    case {options[:operation], options[:arguments]} do
      {:agents, []} ->
        client.list_agents(identity, url)

      {:resolve, [target]} ->
        client.resolve_agent(identity, url, target)

      {:aliases, []} ->
        client.list_aliases(identity, url)

      {:alias, [name, target]} ->
        client.set_alias(identity, url, name, target)

      {:unalias, [name]} ->
        client.remove_alias(identity, url, name)

      {:new, [template]} ->
        params =
          options |> Keyword.take([:name, :model]) |> Map.new() |> Map.put(:template, template)

        client.create_agent(identity, url, params)

      {:start, [target]} ->
        client.start_agent(identity, url, target)

      {:stop, [target]} ->
        client.stop_agent(identity, url, target)
    end
  end

  defp operator_output(:agents, %{agents: rows, truncated: truncated}) do
    rows
    |> Enum.map(fn row ->
      "#{row.agent_id} · #{row.display_name} · #{if row.running, do: "running", else: "stopped"} · #{row.template} · #{row.model}"
    end)
    |> list_output(truncated, "No agents are listed for this signing principal.")
  end

  defp operator_output(:aliases, %{aliases: rows, truncated: truncated}),
    do:
      rows
      |> Enum.map(fn row -> row.name <> " → " <> row.agent_id end)
      |> list_output(truncated, "No aliases for this signing principal.")

  defp operator_output(:resolve, id), do: TerminalText.literal(id)

  defp operator_output(:alias, result),
    do: TerminalText.literal("Alias #{result.name} → #{result.agent_id}")

  defp operator_output(:unalias, result),
    do: TerminalText.literal("Alias removed: #{result.name}")

  defp operator_output(:new, result),
    do:
      TerminalText.literal(
        "Created and started #{result.display_name}: #{result.agent_id}\nNo conversation was attached."
      )

  defp operator_output(op, result) when op in [:start, :stop],
    do:
      TerminalText.literal(
        "#{if op == :start, do: "Started", else: "Stopped"} #{result.agent_id}\nNo conversation was attached."
      )

  defp list_output([], _, empty), do: empty

  defp list_output(rows, truncated, _) do
    TerminalText.literal(Enum.join(rows, "\n")) <>
      if(truncated,
        do: "\nListing truncated; use an exact target or refine with resolve.",
        else: ""
      )
  end

  def error_message(:management_unconfirmed),
    do:
      "The operator command may have completed, but its reply was not confirmed. Check authoritative state before issuing another command. No retry was sent."

  def error_message(:approval_required),
    do:
      "Operator approval is required. Review it in the authenticated Console before issuing a new command."

  def error_message(:ambiguous),
    do: "The target is ambiguous. Use a full agent ID or an exact alias."

  def error_message(:signed_key_required),
    do:
      "Operator commands require --key. Human conversation sign-in remains chat only; use the Console or operator CLI."

  def error_message(:unauthorized), do: "This signing principal lacks the required capability."
  def error_message(:not_found), do: "No authorized target matches that token."
  def error_message(:invalid_identity), do: "The private signing key could not be loaded."

  def error_message(:configuration_unavailable),
    do:
      "Terminal preferences could not be read. Check tui.conf or supply explicit startup settings."

  def error_message(:unsafe_gateway_url),
    do: "Use HTTPS for a remote Gateway or a literal loopback address for human sign-in."

  def error_message(:cleanup_unconfirmed),
    do: "Terminal cleanup could not be confirmed. Check Gateway access before signing in again."

  def error_message(_), do: "The request could not complete. Check Gateway access and try again."

  defp device_login(client, url, target) do
    with {:ok, pending} <- client.start_login(url, target) do
      IO.puts("Sign in at " <> pending.verification_uri)
      IO.puts("Code: " <> pending.user_code)
      deadline = System.monotonic_time(:millisecond) + pending.expires_in * 1_000

      case poll(client, url, pending, deadline) do
        {:ok, session} ->
          {:ok, [session: session], fn -> :ok end}

        _ ->
          client.cancel_login(url, pending.handle)
          {:error, :login_failed}
      end
    end
  end

  defp poll(client, url, pending, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :login_expired}
    else
      Process.sleep(pending.interval * 1_000)

      case client.poll_login(url, pending.handle) do
        {:ok, :pending} -> poll(client, url, pending, deadline)
        {:ok, session} -> {:ok, session}
        error -> error
      end
    end
  end

  def usage do
    """
    arbor-tui [--agent AGENT_ID] [--url GATEWAY_URL]
    arbor-tui [--agent TOKEN] --key PRIVATE_KEY_FILE [--url GATEWAY_URL]
    arbor-tui agents|aliases --key PRIVATE_KEY_FILE [--url GATEWAY_URL]
    arbor-tui resolve|start|stop TOKEN --key PRIVATE_KEY_FILE [--url GATEWAY_URL]
    arbor-tui alias NAME TARGET --key PRIVATE_KEY_FILE [--url GATEWAY_URL]
    arbor-tui unalias NAME --key PRIVATE_KEY_FILE [--url GATEWAY_URL]
    arbor-tui new TEMPLATE --key PRIVATE_KEY_FILE [--name NAME] [--model MODEL] [--url GATEWAY_URL]
    Human device sign-in is chat only. Signed operator commands independently require their host capability.
    Short switches -a, -u and -k match --agent, --url and --key. URL preference: CLI, tui.conf, ARBOR_GATEWAY_URL, then literal-loopback default. Config agent applies only to chat below --agent.
    tui.conf is read under explicit ARBOR_HOME or ~/.arbor. Only url and agent preferences are used; signing always requires --key. ARBOR_KEY, config key, default key files and tui.state are never adopted automatically.
    Lifecycle commands never attach a conversation. F2 or /agents opens target selection; /attach TOKEN explicitly switches after pending work is reconciled.
    Without --agent the remembered target is only a hint; human mode requires a fresh target-specific browser sign-in.
    arbor-tui uses Breeze; arbor-tui-legacy explicitly selects the previous TermUI client.
    """
  end
end
