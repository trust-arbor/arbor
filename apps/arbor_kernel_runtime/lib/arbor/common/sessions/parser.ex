defmodule Arbor.Common.Sessions.Parser do
  @moduledoc """
  Converts raw JSON maps to Record structs.

  Provider-agnostic entry point for parsing session records.
  Automatically detects the provider format or accepts explicit provider option.

  ## Usage

      # Parse with auto-detection
      {:ok, record} = Parser.parse(json_map)

      # Parse with explicit provider
      {:ok, record} = Parser.parse(json_map, provider: :claude)

  ## Supported Providers

  - `:claude` - Claude Code JSONL format
  - Future: `:codex`, `:gemini`, etc.
  """

  alias Arbor.Common.Sessions.Providers.Claude
  alias Arbor.Common.Sessions.Record

  @type json_map :: map()
  @type provider :: :claude | :auto
  @type parse_opts :: [provider: provider()]

  @doc """
  Parse a single JSON map into a Record struct.

  ## Options

  - `:provider` - Explicit provider (`:claude`, `:auto`). Default: `:auto`

  ## Examples

      iex> Parser.parse(%{"type" => "user", "sessionId" => "abc", "uuid" => "123", "message" => %{"role" => "user", "content" => "Hello"}})
      {:ok, %Record{type: :user, role: :user}}

      iex> Parser.parse(%{"type" => "user"}, provider: :claude)
      {:ok, %Record{type: :user}}
  """
  @spec parse(json_map(), parse_opts()) :: {:ok, Record.t()} | {:error, term()}
  def parse(json, opts \\ []) when is_map(json) do
    provider = Keyword.get(opts, :provider, :auto)
    do_parse(json, provider)
  end

  @doc """
  Parse a single JSON map, raising on error.

  ## Examples

      iex> Parser.parse!(%{"type" => "user", "sessionId" => "abc", "uuid" => "123"})
      %Record{type: :user}
  """
  @spec parse!(json_map(), parse_opts()) :: Record.t()
  def parse!(json, opts \\ []) do
    case parse(json, opts) do
      {:ok, record} -> record
      {:error, reason} -> raise ArgumentError, "Failed to parse record: #{inspect(reason)}"
    end
  end

  @doc """
  Parse a JSON string into a Record struct.

  Decodes the JSON first, then parses the resulting map.

  ## Examples

      iex> Parser.parse_json(~s({"type": "user", "sessionId": "abc", "uuid": "123"}))
      {:ok, %Record{type: :user}}
  """
  @spec parse_json(String.t(), parse_opts()) :: {:ok, Record.t()} | {:error, term()}
  def parse_json(json_string, opts \\ []) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, json} -> parse(json, opts)
      {:error, reason} -> {:error, {:json_decode_error, reason}}
    end
  end

  @doc """
  Detect the provider format from a JSON map.

  ## Examples

      iex> Parser.detect_provider(%{"sessionId" => "abc", "uuid" => "123"})
      :claude

      iex> Parser.detect_provider(%{"unknown" => "format"})
      :unknown
  """
  @spec detect_provider(json_map()) :: provider() | :unknown
  def detect_provider(json) when is_map(json) do
    if Claude.matches?(json), do: :claude, else: :unknown
  end

  # Private functions

  defp do_parse(json, :auto) do
    case detect_provider(json) do
      :unknown -> {:error, :unknown_provider}
      provider -> do_parse(json, provider)
    end
  end

  defp do_parse(json, :claude) do
    Claude.parse_record(json)
  end
end
