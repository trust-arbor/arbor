defmodule Mix.Tasks.Arbor.Login do
  @shortdoc "Log in to OpenAI or xAI OAuth, or show OAuth status"
  @moduledoc """
  Start an Arbor-owned OAuth login or report local OAuth health.

  ## Usage

      mix arbor.login openai
      mix arbor.login openai --no-browser
      mix arbor.login openai --manual
      mix arbor.login xai
      mix arbor.login status

  Alias: `mix arbor.oauth.login`.

  ## Commands

    * `openai` — start the localhost loopback flow, print the authorize URL,
      optionally open a browser, then await that flow's own completion
    * `xai` — start the device flow, print the device URL and user code, then
      complete (poll) the device login
    * `status` — print every OAuth route's `oauth_health`

  ## Options

    * `--no-browser` — do not launch `xdg-open` / `open`; the URL is still printed
    * `--manual` — OpenAI only: print the authorize URL, prompt for the pasted
      callback URL, parse `code`/`state`, and call `complete_openai_login/3`
    * `--timeout` — await/poll budget in milliseconds (default 600000)

  A missing or failing browser opener is non-fatal: the URL has already been
  printed, one line is logged, and the task keeps waiting.

  Denial, timeout, and loopback-busy fail the Mix task with a closed reason
  and a non-zero exit.

  This task calls only the public `Arbor.LLM` facade. `Arbor.LLM.OAuth.Login`
  never launches a browser.
  """

  use Mix.Task

  alias Arbor.LLM
  alias Arbor.LLM.LoginCliCore
  alias Arbor.LLM.OAuth.Login.AuthorizationPrompt
  alias Arbor.LLM.OAuth.Login.DevicePrompt
  alias Arbor.LLM.OAuth.Login.LoopbackPrompt

  require Logger

  alias Mix.Tasks.Arbor.Helpers, as: ArborConfig

  # Short calls (start, complete, health) and the two blocking waits (the
  # loopback await and the xAI device poll, both bounded by the OAuth handle
  # TTL). RPC timeouts, not HTTP ones.
  @rpc_timeout_ms 30_000
  @rpc_wait_timeout_ms 900_000

  @impl true
  def run(args) do
    ArborConfig.install_mix_shutdown_hooks()

    case execute(args, []) do
      :ok -> :ok
      {:error, _reason} -> exit({:shutdown, 1})
    end
  end

  @doc false
  @spec execute([String.t()], keyword()) :: :ok | {:error, term()}
  def execute(args, opts) when is_list(args) and is_list(opts) do
    deps = deps(opts)

    case LoginCliCore.new(args) do
      {:ok, command} -> dispatch(command, deps)
      {:error, reason} -> finish({:error, reason}, deps)
    end
  end

  defp dispatch(%{action: :status} = _command, deps) do
    lines = Enum.map_join(LoginCliCore.oauth_routes(), "\n", &status_line(&1, deps))

    deps.emit.(lines)
    :ok
  end

  defp dispatch(%{action: :openai, manual: true} = command, deps) do
    run_openai_manual(command, deps)
  end

  defp dispatch(%{action: :openai} = command, deps) do
    run_openai_loopback(command, deps)
  end

  defp dispatch(%{action: :xai} = command, deps) do
    run_xai(command, deps)
  end

  defp run_openai_loopback(command, deps) do
    case deps.start_openai_loopback.([]) do
      {:ok, prompt} ->
        url = LoopbackPrompt.authorize_url(prompt)
        deps.emit.(LoginCliCore.format_openai_instructions(url))
        maybe_open(url, command.browser, deps)

        prompt
        |> deps.await_openai_loopback.(timeout_ms: command.timeout_ms)
        |> emit_health_or_error(deps)

      {:error, reason} ->
        finish({:error, reason}, deps)
    end
  end

  defp run_openai_manual(command, deps) do
    case deps.start_openai.([]) do
      {:ok, prompt} ->
        url = AuthorizationPrompt.authorize_url(prompt)
        deps.emit.(LoginCliCore.format_openai_instructions(url))
        maybe_open(url, command.browser, deps)
        complete_manual(prompt, deps)

      {:error, reason} ->
        finish({:error, reason}, deps)
    end
  end

  defp complete_manual(prompt, deps) do
    pasted = deps.prompt.("Paste the redirected callback URL: ")

    with {:ok, {code, state}} <- LoginCliCore.parse_callback_url(pasted),
         :ok <- deps.complete_openai.(prompt.handle, code, state),
         {:ok, health} <- deps.oauth_health.(:openai_oauth) do
      emit_health_or_error({:ok, health}, deps)
    else
      {:error, reason} -> finish({:error, reason}, deps)
    end
  end

  defp run_xai(_command, deps) do
    case deps.start_xai.() do
      {:ok, prompt} ->
        uri = xai_uri(prompt)
        deps.emit.(LoginCliCore.format_xai_instructions(uri, DevicePrompt.user_code(prompt)))

        prompt.handle
        |> deps.complete_xai.()
        |> xai_health(deps)

      {:error, reason} ->
        finish({:error, reason}, deps)
    end
  end

  defp xai_uri(prompt) do
    DevicePrompt.verification_uri_complete(prompt) || DevicePrompt.verification_uri(prompt)
  end

  defp xai_health(:ok, deps) do
    emit_health_or_error(deps.oauth_health.(:xai_oauth), deps)
  end

  defp xai_health({:error, reason}, deps), do: finish({:error, reason}, deps)

  defp status_line(route, deps) do
    case deps.oauth_health.(route) do
      {:ok, health} -> LoginCliCore.format_health(health)
      {:error, reason} -> "#{route} #{LoginCliCore.format_error(reason)}"
    end
  end

  defp emit_health_or_error({:ok, health}, deps) do
    deps.emit.(LoginCliCore.format_health(health))
    :ok
  end

  defp emit_health_or_error({:error, reason}, deps), do: finish({:error, reason}, deps)

  defp finish({:error, reason}, deps) do
    deps.emit.(LoginCliCore.format_error(reason))
    {:error, reason}
  end

  defp maybe_open(_url, false, _deps), do: :ok

  defp maybe_open(url, true, deps) do
    open_browser(deps.opener, url, deps)
  rescue
    exception ->
      deps.log.("Browser opener failed; continue waiting. #{Exception.message(exception)}")
      :ok
  catch
    kind, reason ->
      deps.log.("Browser opener failed; continue waiting. #{kind}: #{inspect_closed(reason)}")
      :ok
  end

  defp open_browser(opener, url, deps) do
    case opener.(url) do
      :ok ->
        :ok

      {:ok, _result} ->
        :ok

      {:error, reason} ->
        deps.log.("Browser opener unavailable; continue waiting. #{closed(reason)}")

      _other ->
        :ok
    end
  end

  # The OAuth store, pending handles, and the loopback listener live in the
  # running Arbor node. When one is reachable every facade call is an RPC to
  # it; otherwise the Mix VM starts the app itself (no node, so no port clash
  # with the dashboard). Tests inject the facade functions directly.
  defp deps(opts) do
    facade = facade(opts)

    %{
      emit: Keyword.get(opts, :output, &default_emit/1),
      log: Keyword.get(opts, :log, &default_log/1),
      opener: Keyword.get(opts, :opener, &default_opener/1),
      prompt: Keyword.get(opts, :prompt, &default_prompt/1),
      start_openai_loopback:
        Keyword.get(opts, :start_openai_loopback, facade.(:start_openai_loopback_login, 1)),
      await_openai_loopback:
        Keyword.get(opts, :await_openai_loopback, facade.(:await_openai_loopback_login, 2)),
      start_openai: Keyword.get(opts, :start_openai, facade.(:start_openai_login, 1)),
      complete_openai: Keyword.get(opts, :complete_openai, facade.(:complete_openai_login, 3)),
      start_xai: Keyword.get(opts, :start_xai, facade.(:start_xai_device_login, 0)),
      complete_xai: Keyword.get(opts, :complete_xai, facade.(:complete_xai_device_login, 1)),
      oauth_health: Keyword.get(opts, :oauth_health, facade.(:oauth_health, 1))
    }
  end

  @facade_keys [
    :start_openai_loopback,
    :await_openai_loopback,
    :start_openai,
    :complete_openai,
    :start_xai,
    :complete_xai,
    :oauth_health
  ]

  defp facade(opts) do
    cond do
      Enum.all?(@facade_keys, &Keyword.has_key?(opts, &1)) ->
        fn fun, arity -> local_facade(fun, arity) end

      (node = reachable_node(opts)) != nil ->
        Logger.debug("[arbor.login] calling the running node #{node}")
        fn fun, arity -> node_facade(node, fun, arity) end

      true ->
        Mix.Task.run("app.start")
        fn fun, arity -> local_facade(fun, arity) end
    end
  end

  defp reachable_node(opts) do
    ensure = Keyword.get(opts, :ensure_distribution, &ArborConfig.ensure_distribution/0)
    running? = Keyword.get(opts, :server_running?, &ArborConfig.server_running?/0)
    target = Keyword.get(opts, :target_node, &ArborConfig.full_node_name/0)

    with :ok <- ensure.(),
         true <- running?.(),
         node when is_atom(node) and not is_nil(node) <- target.() do
      node
    else
      _other -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp local_facade(fun, arity), do: Function.capture(LLM, fun, arity)

  defp node_facade(node, fun, arity) do
    timeout =
      if fun in [:await_openai_loopback_login, :complete_xai_device_login],
        do: @rpc_wait_timeout_ms,
        else: @rpc_timeout_ms

    call = fn args ->
      case ArborConfig.rpc_result(node, LLM, fun, args, timeout) do
        {:badrpc, reason} -> {:error, {:node_rpc, closed(reason)}}
        other -> other
      end
    end

    case arity do
      0 -> fn -> call.([]) end
      1 -> fn a -> call.([a]) end
      2 -> fn a, b -> call.([a, b]) end
      3 -> fn a, b, c -> call.([a, b, c]) end
    end
  end

  defp default_emit(message), do: Mix.shell().info(message)

  defp default_log(message), do: Logger.warning(message)

  defp default_prompt(message), do: Mix.shell().prompt(message)

  defp default_opener(url) when is_binary(url) do
    cond do
      is_binary(System.find_executable("xdg-open")) ->
        opener_cmd("xdg-open", url)

      is_binary(System.find_executable("open")) ->
        opener_cmd("open", url)

      true ->
        {:error, :opener_missing}
    end
  end

  defp opener_cmd("xdg-open", url) do
    case System.cmd("xdg-open", [url], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, {:opener_exit, status}}
    end
  end

  defp opener_cmd("open", url) do
    case System.cmd("open", [url], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, {:opener_exit, status}}
    end
  end

  defp closed(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp closed(_reason), do: "closed"

  defp inspect_closed(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp inspect_closed(_reason), do: "closed"
end
