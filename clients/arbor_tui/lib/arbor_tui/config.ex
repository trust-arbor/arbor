defmodule ArborTui.Config do
  @moduledoc """
  Settings resolution for the TUI client.

  Three sources, in descending precedence: **CLI flag > config file > env var >
  built-in default**. The config file is `~/.arbor/tui.conf`, a dependency-free
  `key = value` format:

      # comments and blank lines are ignored
      url   = ws://localhost:4000
      key   = ~/.arbor/client.arbor.key
      agent = agent_30b455…

  Whitespace around keys/values is trimmed, a leading `~` in a value is expanded
  to the user's home directory, unknown keys are tolerated, and a missing file
  yields an empty config (so all defaults apply).

  Recognized keys: `url`, `key`, `agent`.
  """

  @default_path ".arbor/tui.conf"
  @state_path ".arbor/tui.state"

  @default_url "ws://localhost:4000"
  @default_key "~/.arbor/client.arbor.key"

  @typedoc "Parsed config file (recognized keys only; values are strings)."
  @type t :: %{
          optional(:url) => String.t(),
          optional(:key) => String.t(),
          optional(:agent) => String.t()
        }

  @recognized ~w(url key agent)
  @state_recognized ~w(last_agent)

  @doc """
  The default config-file path, `~/.arbor/tui.conf`.
  """
  @spec default_path() :: Path.t()
  def default_path, do: Path.join(System.user_home!(), @default_path)

  @doc """
  The auto-written state-file path, `~/.arbor/tui.state`.

  Kept SEPARATE from the user-edited config file: this is written by the client
  (e.g. the last-attached agent), not by the user.
  """
  @spec state_path() :: Path.t()
  def state_path, do: Path.join(System.user_home!(), @state_path)

  @doc """
  Load and parse the config file at `path` (defaults to `default_path/0`).

  A missing or unreadable file yields `%{}` (all defaults apply). Unknown keys
  are dropped. Values have a leading `~` expanded to the home directory.
  """
  @spec load(Path.t() | nil) :: t()
  def load(path \\ nil) do
    path = path || default_path()

    case File.read(path) do
      {:ok, contents} -> parse(contents, @recognized)
      {:error, _} -> %{}
    end
  end

  @doc """
  Load the auto-written state file (`~/.arbor/tui.state`).

  Same `key = value` format; recognizes `last_agent`. Missing file → `%{}`.
  """
  @spec load_state(Path.t() | nil) :: %{optional(:last_agent) => String.t()}
  def load_state(path \\ nil) do
    path = path || state_path()

    case File.read(path) do
      {:ok, contents} -> parse(contents, @state_recognized)
      {:error, _} -> %{}
    end
  end

  @doc """
  Persist the last-attached agent id to the state file (best-effort).

  Returns `:ok` regardless of write success — losing the resume hint must never
  surface as a user-facing error. The parent `~/.arbor` directory is created if
  missing.
  """
  @spec save_last_agent(String.t(), Path.t() | nil) :: :ok
  def save_last_agent(agent_id, path \\ nil) when is_binary(agent_id) do
    path = path || state_path()
    _ = File.mkdir_p(Path.dirname(path))
    _ = File.write(path, "last_agent = #{agent_id}\n")
    :ok
  end

  @doc """
  Parse config-file `contents` into a map of recognized keys.

  `recognized` is the whitelist of accepted keys (defaults to the config keys
  `url`/`key`/`agent`); unknown keys are dropped.
  """
  @spec parse(String.t(), [String.t()]) :: map()
  def parse(contents, recognized \\ @recognized) when is_binary(contents) do
    contents
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case parse_line(line) do
        {:ok, key, value} ->
          if key in recognized, do: Map.put(acc, String.to_atom(key), value), else: acc

        _ ->
          acc
      end
    end)
  end

  # A line is either blank, a comment, or `key = value`. The `=` splits on the
  # first occurrence so values may contain `=`.
  defp parse_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> :skip
      String.starts_with?(trimmed, "#") -> :skip
      true -> parse_kv(trimmed)
    end
  end

  defp parse_kv(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] -> {:ok, String.trim(key), value |> String.trim() |> expand_tilde()}
      _ -> :skip
    end
  end

  # Expand a leading `~` (or `~/`) to the user's home directory. A bare `~` or
  # `~/foo` only — we do not resolve `~user` (rare, and stdlib has no helper).
  defp expand_tilde("~"), do: System.user_home!()
  defp expand_tilde("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp expand_tilde(value), do: value

  @doc """
  Resolve the gateway URL: `--url` > config `url` > `$ARBOR_GATEWAY_URL` >
  `"#{@default_url}"`.
  """
  @spec resolve_url(keyword(), t()) :: String.t()
  def resolve_url(opts, config) do
    opts[:url] || config[:url] || System.get_env("ARBOR_GATEWAY_URL") || @default_url
  end

  @doc """
  Resolve the identity key path: `--key` > config `key` > `$ARBOR_KEY` >
  `"#{@default_key}"` (the default is tilde-expanded).
  """
  @spec resolve_key(keyword(), t()) :: Path.t()
  def resolve_key(opts, config) do
    opts[:key] || config[:key] || System.get_env("ARBOR_KEY") ||
      Path.join(System.user_home!(), ".arbor/client.arbor.key")
  end

  @doc """
  Resolve the target agent id:
  `--agent` > config `agent` > `last_agent` (from state) > `nil`.

  Explicit config still wins; `last_agent` is the auto fallback so a bare
  `arbor-tui` resumes the previous agent. `nil` means start UNATTACHED.
  """
  @spec resolve_agent(keyword(), t(), %{optional(:last_agent) => String.t()}) ::
          String.t() | nil
  def resolve_agent(opts, config, state \\ %{}) do
    opts[:agent] || config[:agent] || state[:last_agent]
  end
end
