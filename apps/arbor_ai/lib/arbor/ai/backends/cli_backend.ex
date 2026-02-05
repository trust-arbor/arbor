defmodule Arbor.AI.Backends.CliBackend do
  @moduledoc """
  Behavior and shared implementation for CLI-based LLM backends.

  Each CLI backend (Claude, Codex, Gemini, etc.) uses this module to provide
  a consistent interface for:

  - Text generation (prompt -> response)
  - Model selection (within the same CLI tool)
  - Session management (new vs resume)
  - Output parsing and normalization

  ## Using This Module

  Backends should `use` this module to get the common `generate_text/2` implementation:

      defmodule MyBackend do
        use Arbor.AI.Backends.CliBackend, provider: :my_backend

        @impl true
        def build_command(prompt, opts), do: ...

        @impl true
        def parse_output(output), do: ...

        @impl true
        def default_model, do: :default

        @impl true
        def available_models, do: [:default]
      end

  The `use` macro provides:
  - `@behaviour Arbor.AI.Backends.CliBackend`
  - `@provider` module attribute
  - Default `generate_text/2` implementation (can be overridden)
  - Default `supports_json_output?/0` returning true
  - Default `session_dir/0` returning nil

  ## Required Callbacks

  Backends must implement:
  - `build_command/2` - Build the CLI command with args
  - `parse_output/1` - Parse CLI output to Response struct
  - `default_model/0` - Default model for this backend
  - `available_models/0` - List of available models

  ## Optional Callbacks

  - `supports_json_output?/0` - Whether CLI supports JSON output (default: true)
  - `session_dir/0` - Directory where sessions are stored (default: nil)
  - `generate_text/2` - Override the default implementation if needed
  """

  alias Arbor.AI.QuotaTracker
  alias Arbor.AI.Response
  alias Arbor.Common.ShellEscape

  require Logger

  @type opts :: keyword()
  @type model :: String.t() | atom()

  @doc "Generate text using this CLI backend"
  @callback generate_text(prompt :: String.t(), opts :: opts()) ::
              {:ok, Response.t()} | {:error, term()}

  @doc "Build the CLI command and arguments"
  @callback build_command(prompt :: String.t(), opts :: opts()) ::
              {command :: String.t(), args :: [String.t()]}

  @doc "Parse CLI output into a Response struct"
  @callback parse_output(output :: String.t()) ::
              {:ok, Response.t()} | {:error, term()}

  @doc "Default model for this backend"
  @callback default_model() :: model()

  @doc "List of available models"
  @callback available_models() :: [model()]

  @doc "Whether this backend supports JSON output"
  @callback supports_json_output?() :: boolean()

  @doc "Directory where sessions are stored (for session ID discovery)"
  @callback session_dir() :: String.t() | nil

  @doc "Whether this backend supports session resumption"
  @callback supports_sessions?() :: boolean()

  @doc "Extract session ID from a response (for session tracking)"
  @callback extract_session_id(response :: Response.t()) :: String.t() | nil

  @optional_callbacks [
    supports_json_output?: 0,
    session_dir: 0,
    generate_text: 2,
    supports_sessions?: 0,
    extract_session_id: 1
  ]

  # ============================================================================
  # __using__ Macro - Provides common implementation
  # ============================================================================

  @doc """
  When used, provides the common CLI backend implementation.

  ## Options

  - `:provider` - Required. The provider atom (e.g., `:anthropic`, `:gemini`)

  ## Example

      defmodule Arbor.AI.Backends.MyCli do
        use Arbor.AI.Backends.CliBackend, provider: :my_provider

        @impl true
        def build_command(prompt, opts), do: {"mycli", [prompt]}

        @impl true
        def parse_output(output), do: {:ok, build_response(%{text: output}, @provider)}

        @impl true
        def default_model, do: :default

        @impl true
        def available_models, do: [:default]
      end
  """
  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote do
      @behaviour Arbor.AI.Backends.CliBackend

      alias Arbor.AI.Backends.CliBackend
      alias Arbor.AI.QuotaTracker
      alias Arbor.AI.Response

      require Logger

      @provider unquote(provider)

      @impl true
      def generate_text(prompt, opts \\ []) do
        CliBackend.do_generate_text(__MODULE__, @provider, prompt, opts)
      end

      @impl true
      def supports_json_output?, do: true

      @impl true
      def session_dir, do: nil

      @impl true
      def supports_sessions?, do: false

      @impl true
      def extract_session_id(%Response{session_id: sid}), do: sid
      def extract_session_id(_), do: nil

      defoverridable generate_text: 2,
                     supports_json_output?: 0,
                     session_dir: 0,
                     supports_sessions?: 0,
                     extract_session_id: 1
    end
  end

  @doc """
  Common implementation of generate_text for all CLI backends.

  Called by the `__using__` macro's default `generate_text/2` implementation.
  Backends can override `generate_text/2` if they need custom behavior.
  """
  @spec do_generate_text(module(), atom(), String.t(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def do_generate_text(module, provider, prompt, opts) do
    {cmd, args} = module.build_command(prompt, opts)

    model = Keyword.get(opts, :model, module.default_model())

    Logger.info("#{provider_name(provider)} generating text",
      model: model,
      prompt_length: String.length(prompt)
    )

    start_time = System.monotonic_time(:millisecond)

    case execute_command(cmd, args, opts) do
      {:ok, output} ->
        duration = System.monotonic_time(:millisecond) - start_time

        case module.parse_output(output) do
          {:ok, response} ->
            response = %{response | timing: %{duration_ms: duration}}

            Logger.info("#{provider_name(provider)} response received",
              duration_ms: duration,
              response_length: String.length(response.text || "")
            )

            {:ok, response}

          {:error, reason} ->
            Logger.warning("#{provider_name(provider)} parse error", error: inspect(reason))
            {:error, reason}
        end

      {:error, {:exit_code, _code, output}} = error ->
        # Check for quota exhaustion in error output
        QuotaTracker.check_and_mark(provider, output)
        Logger.warning("#{provider_name(provider)} execution error", error: inspect(error))
        error

      {:error, reason} ->
        Logger.warning("#{provider_name(provider)} execution error", error: inspect(reason))
        {:error, reason}
    end
  end

  # Convert provider atom to readable name for logging
  defp provider_name(provider) do
    provider
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # ============================================================================
  # Shared Implementation Helpers
  # ============================================================================

  @doc """
  Executes a CLI command and returns the output.

  Common implementation used by all CLI backends.
  Uses `Arbor.Shell.execute/2` with Port-based execution, which provides
  proper BEAM process ownership and timeout handling without Task wrappers.
  """
  @spec execute_command(String.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def execute_command(cmd, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 300_000)
    working_dir = Keyword.get(opts, :working_dir)

    # Build shell command with escaped args and stdin redirect
    quoted_args = Enum.map(args, &ShellEscape.escape_arg!/1)
    shell_cmd = "#{cmd} #{Enum.join(quoted_args, " ")} < /dev/null"

    shell_opts = [
      sandbox: :none,
      timeout: timeout,
      env: safe_env()
    ]

    shell_opts = if working_dir, do: [{:cwd, working_dir} | shell_opts], else: shell_opts

    case Arbor.Shell.execute(shell_cmd, shell_opts) do
      {:ok, %{exit_code: 0, stdout: output}} ->
        {:ok, output}

      {:ok, %{timed_out: true}} ->
        {:error, :timeout}

      {:ok, %{exit_code: code, stdout: output}} ->
        {:error, {:exit_code, code, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Build a safe environment for CLI subprocesses.
  # Port.open's :env option extends the parent environment.
  # Setting a value to `false` removes that variable.
  # We clear session-related variables so subprocesses don't
  # reconnect to the parent's active Claude Code session.
  @session_vars_to_clear ~w(
    CLAUDE_CODE_ENTRYPOINT CLAUDE_SESSION_ID CLAUDE_CONFIG_DIR
    ARBOR_SDLC_SESSION_ID ARBOR_SDLC_ITEM_PATH ARBOR_SESSION_TYPE
  )

  defp safe_env do
    cleared = Map.new(@session_vars_to_clear, &{&1, false})
    Map.put(cleared, "TERM", "dumb")
  end

  @doc """
  Strips ANSI escape codes from CLI output.
  """
  @spec strip_ansi(String.t()) :: String.t()
  def strip_ansi(text) do
    # Remove ANSI escape sequences
    text
    |> String.replace(~r/\x1b\[[0-9;]*m/, "")
    |> String.replace(~r/\x1b\[[0-9;]*[A-Za-z]/, "")
    |> String.replace(~r/\r/, "")
  end

  @doc """
  Determines if this should be a new session or resume.

  Session mode is determined by the `:new_session` option:
  - `new_session: true` - Force a new session
  - `new_session: false` - Prefer resuming an existing session
  - Not specified (nil) - Auto-detect based on existing sessions

  When auto-detecting, checks if a session exists in the working directory.
  Most CLI agents default to resuming the last session in a directory context.
  """
  @spec session_mode(String.t() | nil, keyword()) :: :new | :resume
  def session_mode(session_dir, opts) do
    case Keyword.get(opts, :new_session) do
      true ->
        # Explicitly requested new session
        :new

      false ->
        # Explicitly requested resume
        :resume

      nil ->
        # Auto-detect: resume if session exists, otherwise new
        if session_dir && has_existing_session?(session_dir, opts) do
          :resume
        else
          # Default to resume for CLI agents (they typically maintain context)
          # Only use :new on explicit request
          :resume
        end
    end
  end

  @doc """
  Checks if there's an existing session in the given directory.
  """
  @spec has_existing_session?(String.t(), keyword()) :: boolean()
  def has_existing_session?(session_dir, opts) do
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    session_path = Path.join([session_dir, working_dir_hash(working_dir)])

    File.exists?(session_path) and File.dir?(session_path)
  rescue
    _ -> false
  end

  # Generate a hash of the working directory for session lookup
  defp working_dir_hash(dir) do
    :crypto.hash(:md5, dir) |> Base.encode16(case: :lower) |> String.slice(0, 8)
  end

  @doc """
  Parses JSON output from CLI, handling common edge cases.
  """
  @spec parse_json_output(String.t()) :: {:ok, map() | list()} | {:error, term()}
  def parse_json_output(output) do
    # Try to find JSON in the output (CLIs sometimes print extra text)
    trimmed = String.trim(output)

    # Try parsing as-is first
    case Jason.decode(trimmed) do
      {:ok, json} ->
        {:ok, json}

      {:error, _} ->
        # Try to extract JSON object or array
        case Regex.run(~r/(\{[\s\S]*\}|\[[\s\S]*\])/, trimmed) do
          [_, json_str] ->
            Jason.decode(json_str)

          _ ->
            {:error, :no_json_found}
        end
    end
  end

  @doc """
  Builds a Response struct from parsed data.
  """
  @spec build_response(map(), atom()) :: Response.t()
  def build_response(data, provider) do
    Response.new(
      text: data[:text] || data["text"] || "",
      provider: provider,
      model: data[:model] || data["model"],
      session_id: data[:session_id] || data["session_id"],
      usage: data[:usage] || data["usage"],
      timing: data[:timing] || data["timing"],
      raw_response: data[:raw] || data["raw"]
    )
  end

  # ============================================================================
  # NDJSON Parsing Helpers
  # ============================================================================

  @doc """
  Decode newline-delimited JSON output into a list of parsed event maps.

  Skips lines that aren't valid JSON.
  """
  @spec decode_ndjson(String.t()) :: [map()]
  def decode_ndjson(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case Jason.decode(String.trim(line)) do
        {:ok, json} -> json
        {:error, _} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Find the first event matching `type` and extract a value by `key`.

  ## Examples

      find_event_value(events, "thread.started", "thread_id")
      find_event_value(events, "step_start", "sessionID")
  """
  @spec find_event_value([map()], String.t(), String.t()) :: term() | nil
  def find_event_value(events, type, key) do
    Enum.find_value(events, fn
      %{"type" => ^type} = event -> event[key]
      _ -> nil
    end)
  end

  @doc """
  Collect and concatenate text from matching events.

  Takes a filter function to select events, and a path function
  to extract text from each matched event.

  ## Examples

      # Codex: agent_message items
      collect_event_text(events,
        fn %{"type" => "item.completed", "item" => %{"type" => "agent_message"}} -> true; _ -> false end,
        fn %{"item" => %{"text" => t}} -> t end,
        "\\n"
      )

      # Opencode: text events
      collect_event_text(events,
        fn %{"type" => "text"} -> true; _ -> false end,
        fn %{"part" => %{"text" => t}} -> t end
      )
  """
  @spec collect_event_text([map()], (map() -> boolean()), (map() -> String.t()), String.t()) ::
          String.t()
  def collect_event_text(events, filter_fn, extract_fn, joiner \\ "") do
    events
    |> Enum.filter(filter_fn)
    |> Enum.map_join(joiner, extract_fn)
  end

  @doc """
  Find the first event matching `type` and apply an extractor function.

  Useful for extracting usage/cost data from finish events.

  ## Examples

      extract_from_event(events, "turn.completed", fn event ->
        %{input_tokens: event["usage"]["input_tokens"]}
      end)
  """
  @spec extract_from_event([map()], String.t(), (map() -> term())) :: term() | nil
  def extract_from_event(events, type, extract_fn) do
    Enum.find_value(events, fn
      %{"type" => ^type} = event ->
        extract_fn.(event)

      _ ->
        nil
    end)
  end
end
