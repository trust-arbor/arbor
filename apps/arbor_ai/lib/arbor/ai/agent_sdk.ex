defmodule Arbor.AI.AgentSDK do
  @moduledoc """
  Claude Agent SDK for Elixir.

  An Elixir implementation of the Claude Agent SDK, providing programmatic
  access to Claude's agentic capabilities including:

  - **Extended Thinking**: Access Claude's reasoning process with cryptographic signatures
  - **Tool Use**: Define and use custom tools with Claude
  - **Conversations**: Multi-turn conversations with maintained state
  - **Streaming**: Real-time streaming of responses

  ## Quick Start

      # Simple one-shot query
      {:ok, response} = Arbor.AI.AgentSDK.query("What is 2 + 2?")
      response.text      #=> "2 + 2 equals 4."
      response.thinking  #=> [%{text: "...", signature: "..."}]

      # With options
      {:ok, response} = Arbor.AI.AgentSDK.query(
        "Analyze this code for bugs",
        model: :opus,
        cwd: "/path/to/project"
      )

  ## Stateful Conversations

      # Start a client for multi-turn conversations
      {:ok, client} = Arbor.AI.AgentSDK.start_client(
        model: :sonnet,
        system_prompt: "You are a helpful coding assistant."
      )

      # First message
      {:ok, r1} = Arbor.AI.AgentSDK.Client.query(client, "What's a GenServer?")

      # Follow-up (maintains context)
      {:ok, r2} = Arbor.AI.AgentSDK.Client.continue(client, "Show me an example")

      # Close when done
      :ok = Arbor.AI.AgentSDK.Client.close(client)

  ## Streaming

      Arbor.AI.AgentSDK.stream("Explain recursion", fn event ->
        case event do
          {:text, chunk} -> IO.write(chunk)
          {:thinking, block} -> IO.puts("[Thinking...]")
          {:complete, _} -> IO.puts("\\nDone!")
        end
      end)

  ## Architecture

  This SDK wraps the Claude Code CLI, communicating via a subprocess with
  JSON streaming protocol. It's inspired by the official Python and TypeScript
  SDKs but designed for Elixir/OTP patterns:

  - Transport layer using Elixir Ports
  - GenServer-based client for state management
  - Async-friendly streaming with callbacks
  """

  alias Arbor.AI.AgentSDK.Client

  @type query_opts :: [
          {:model, atom() | String.t()}
          | {:cwd, String.t()}
          | {:system_prompt, String.t()}
          | {:max_turns, pos_integer()}
          | {:timeout, pos_integer()}
        ]

  @type response :: %{
          text: String.t(),
          thinking: [%{text: String.t(), signature: String.t() | nil}] | nil,
          tool_uses: [map()],
          usage: map() | nil,
          session_id: String.t() | nil
        }

  @doc """
  Send a one-shot query to Claude and get a response.

  This creates a temporary client, sends the query, waits for the response,
  and closes the client. For multiple queries, use `start_client/1` instead.

  ## Options

  - `:model` - Model to use (`:opus`, `:sonnet`, `:haiku`)
  - `:cwd` - Working directory for file operations
  - `:system_prompt` - System prompt to set context
  - `:max_turns` - Maximum conversation turns
  - `:timeout` - Response timeout in ms (default: 120_000)

  ## Examples

      {:ok, response} = Arbor.AI.AgentSDK.query("What is 2 + 2?")

      {:ok, response} = Arbor.AI.AgentSDK.query(
        "Analyze this code",
        model: :opus,
        cwd: "/path/to/project"
      )
  """
  @spec query(String.t(), query_opts()) :: {:ok, response()} | {:error, term()}
  def query(prompt, opts \\ []) do
    case start_client(opts) do
      {:ok, client} ->
        try do
          Client.query(client, prompt, opts)
        after
          Client.close(client)
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Stream a query response, calling the callback for each event.

  Events:
  - `{:text, chunk}` - Text chunk received
  - `{:thinking, %{text: ..., signature: ...}}` - Thinking block completed
  - `{:tool_use, %{id: ..., name: ..., input: ...}}` - Tool use requested
  - `{:complete, response}` - Response complete

  ## Examples

      Arbor.AI.AgentSDK.stream("Explain GenServers", fn event ->
        case event do
          {:text, chunk} -> IO.write(chunk)
          {:thinking, block} -> IO.puts("[Thinking: \#{String.slice(block.text, 0..50)}...]")
          {:complete, _} -> IO.puts("\\nDone!")
          _ -> :ok
        end
      end)
  """
  @spec stream(String.t(), (term() -> any()), query_opts()) ::
          {:ok, response()} | {:error, term()}
  def stream(prompt, callback, opts \\ []) when is_function(callback, 1) do
    case start_client(opts) do
      {:ok, client} ->
        try do
          Client.stream(client, prompt, callback, opts)
        after
          Client.close(client)
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Start a client for multi-turn conversations.

  The client maintains conversation state and allows multiple queries
  in a single session.

  ## Examples

      {:ok, client} = Arbor.AI.AgentSDK.start_client(model: :opus)
      {:ok, r1} = Arbor.AI.AgentSDK.Client.query(client, "Hello")
      {:ok, r2} = Arbor.AI.AgentSDK.Client.continue(client, "Tell me more")
      :ok = Arbor.AI.AgentSDK.Client.close(client)
  """
  @spec start_client(query_opts()) :: {:ok, Client.t()} | {:error, term()}
  def start_client(opts \\ []) do
    Client.start_link(opts)
  end

  @doc """
  Check if the Claude CLI is available.
  """
  @spec cli_available?() :: boolean()
  def cli_available? do
    case System.find_executable("claude") do
      nil -> false
      path -> File.exists?(path)
    end
  end

  @doc """
  Get the version of the Claude CLI.
  """
  @spec cli_version() :: {:ok, String.t()} | {:error, term()}
  def cli_version do
    case System.cmd("claude", ["--version"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {error, _} -> {:error, error}
    end
  rescue
    e -> {:error, e}
  end
end
