defmodule Arbor.LLM.LoginCliCore do
  @moduledoc """
  Pure parsing and formatting for `mix arbor.login`.

  All functions are side-effect free: argument construction, callback-URL
  extraction, and closed health/error rendering. The Mix task is the
  imperative shell.
  """

  alias Arbor.Contracts.LLM.OAuthHealth

  @type command :: %{
          action: :openai | :xai | :status,
          manual: boolean(),
          browser: boolean(),
          timeout_ms: pos_integer()
        }

  @command_atoms %{"openai" => :openai, "xai" => :xai, "status" => :status}
  @oauth_routes ["openai_oauth", "xai_oauth"]
  @default_timeout_ms 600_000
  @switches [manual: :boolean, no_browser: :boolean, timeout: :integer]

  @doc "Construct a closed login command from Mix argv."
  @spec new([String.t()]) :: {:ok, command()} | {:error, atom()}
  def new(argv) when is_list(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [action], []} ->
        build_command(action, opts)

      {_opts, [], _invalid} ->
        {:error, :command_required}

      {_opts, [_action, _extra | _], _invalid} ->
        {:error, :too_many_commands}

      {_opts, _positional, [_ | _]} ->
        {:error, :unknown_option}

      {_opts, _positional, _invalid} ->
        {:error, :invalid_arguments}
    end
  end

  def new(_argv), do: {:error, :invalid_arguments}

  @doc "Closed OAuth route ids reported by `status`."
  @spec oauth_routes() :: [String.t()]
  def oauth_routes, do: @oauth_routes

  @doc "Default await/poll budget in milliseconds."
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @doc """
  Extract `{code, state}` from a pasted callback URL.

  Extra query parameters and a fragment are ignored. The pending OAuth
  handle is never present in this parse.
  """
  @spec parse_callback_url(term()) :: {:ok, {String.t(), String.t()}} | {:error, atom()}
  def parse_callback_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    query =
      case URI.parse(trimmed) do
        %URI{query: query} when is_binary(query) and query != "" -> query
        _ -> trimmed
      end

    params = URI.decode_query(query)
    code = Map.get(params, "code")
    state = Map.get(params, "state")

    if present?(code) and present?(state) do
      {:ok, {code, state}}
    else
      {:error, :invalid_callback_url}
    end
  end

  def parse_callback_url(_url), do: {:error, :invalid_callback_url}

  @doc "Operator instructions that include the OpenAI authorize URL."
  @spec format_openai_instructions(String.t()) :: String.t()
  def format_openai_instructions(authorize_url) when is_binary(authorize_url) do
    "Open this authorization URL:\n#{authorize_url}"
  end

  @doc "Operator instructions that include the xAI device URL and user code."
  @spec format_xai_instructions(String.t(), String.t()) :: String.t()
  def format_xai_instructions(verification_uri, user_code)
      when is_binary(verification_uri) and is_binary(user_code) do
    "Open #{verification_uri} and enter code: #{user_code}"
  end

  @doc "Format one closed OAuth health snapshot. Never includes token material."
  @spec format_health(OAuthHealth.t() | map()) :: String.t()
  def format_health(%OAuthHealth{} = health) do
    case OAuthHealth.to_map(health) do
      map when is_map(map) -> format_health(map)
      _ -> "oauth_health_unreadable"
    end
  end

  def format_health(health) when is_map(health) do
    route = field(health, :route)
    status = field(health, :status)

    extras =
      Enum.flat_map([:owner, :origin, :source, :generation], fn key ->
        case field(health, key) do
          nil -> []
          value -> ["#{key}=#{value}"]
        end
      end)

    Enum.join(["#{route} status=#{status}" | extras], " ")
  end

  def format_health(_health), do: "oauth_health_unreadable"

  @doc "Format every route's health or closed error."
  @spec format_status([{String.t(), {:ok, term()} | {:error, term()}}]) :: String.t()
  def format_status(results) when is_list(results) do
    Enum.map_join(results, "\n", &format_status_line/1)
  end

  @doc "Closed, secret-free error line for Mix output and non-zero exit."
  @spec format_error(term()) :: String.t()
  def format_error({:access_denied, reason}), do: "access_denied: #{closed(reason)}"
  def format_error({:callback_failed, reason}), do: "callback_failed: #{closed(reason)}"
  def format_error({:loopback_busy, _flow}), do: "loopback_busy"
  def format_error(:timeout), do: "timeout"
  def format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format_error(_reason), do: "login_failed"

  @doc "Convert a command or formatted result for display."
  @spec show(command() | String.t()) :: String.t()
  def show(%{action: action} = command) do
    "#{action} manual=#{command.manual} browser=#{command.browser} timeout_ms=#{command.timeout_ms}"
  end

  def show(text) when is_binary(text), do: text

  defp build_command(action, opts) when is_binary(action) do
    case Map.fetch(@command_atoms, action) do
      {:ok, known} -> build_known_command(known, Map.new(opts))
      :error -> {:error, :unknown_command}
    end
  end

  defp build_known_command(:status, opts) do
    if Map.has_key?(opts, :manual) or Map.has_key?(opts, :no_browser) or
         Map.has_key?(opts, :timeout) do
      {:error, :status_takes_no_login_options}
    else
      {:ok, command(:status, false, false, @default_timeout_ms)}
    end
  end

  defp build_known_command(:xai, opts) do
    if Map.get(opts, :manual) == true do
      {:error, :manual_openai_only}
    else
      with {:ok, timeout_ms} <- timeout_ms(opts) do
        {:ok, command(:xai, false, Map.get(opts, :no_browser) != true, timeout_ms)}
      end
    end
  end

  defp build_known_command(:openai, opts) do
    with {:ok, timeout_ms} <- timeout_ms(opts) do
      {:ok,
       command(
         :openai,
         Map.get(opts, :manual) == true,
         Map.get(opts, :no_browser) != true,
         timeout_ms
       )}
    end
  end

  defp command(action, manual, browser, timeout_ms) do
    %{action: action, manual: manual, browser: browser, timeout_ms: timeout_ms}
  end

  defp timeout_ms(opts) do
    case Map.get(opts, :timeout, @default_timeout_ms) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, :invalid_timeout}
    end
  end

  defp format_status_line({route, {:ok, health}}) when is_binary(route) do
    format_health(health)
  end

  defp format_status_line({route, {:error, reason}}) when is_binary(route) do
    "#{route} #{format_error(reason)}"
  end

  defp format_status_line(_line), do: "oauth_health_unreadable"

  defp field(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp closed(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp closed(_reason), do: "closed"
end
