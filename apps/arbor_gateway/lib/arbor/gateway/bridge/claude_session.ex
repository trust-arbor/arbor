defmodule Arbor.Gateway.Bridge.ClaudeSession do
  @moduledoc """
  Manages Claude Code sessions as Arbor agents.

  When a Claude Code instance first makes a tool call, it gets registered
  as an agent with default capabilities based on trust tier.

  ## Default Capabilities (Untrusted Tier)

  New Claude sessions start with limited permissions:
  - Read files in the project directory
  - Execute safe shell commands (git, mix, etc.)
  - Search files (grep, glob)

  ## Trust Escalation

  Trust increases through:
  - Successful task completions
  - Tests passing
  - Human approval of changes

  ## Usage

      # Ensure session is registered (called by bridge endpoint)
      {:ok, agent_id} = ClaudeSession.ensure_registered(session_id, cwd)

      # Check if tool is authorized
      {:ok, :authorized} = ClaudeSession.authorize_tool(session_id, "Read", tool_input)
  """

  require Logger

  # Default capabilities for Claude Code sessions at untrusted tier
  # Uses prefix matching - "arbor://fs/read/" matches "arbor://fs/read/path/to/file"
  @default_capabilities [
    # File system read - project directory
    %{resource_uri: "arbor://fs/read/", constraints: %{}},
    # File system write - project directory (rate limited)
    %{resource_uri: "arbor://fs/write/", constraints: %{rate_limit: 100}},
    # Shell execution - safe commands only (prefix matching)
    %{resource_uri: "arbor://shell/exec/git", constraints: %{}},
    %{resource_uri: "arbor://shell/exec/mix", constraints: %{}},
    %{resource_uri: "arbor://shell/exec/elixir", constraints: %{}},
    %{resource_uri: "arbor://shell/exec/iex", constraints: %{}},
    %{resource_uri: "arbor://shell/exec/ls", constraints: %{}},
    %{resource_uri: "arbor://shell/exec/cat", constraints: %{}},
    %{resource_uri: "arbor://shell/exec/head", constraints: %{}},
    %{resource_uri: "arbor://shell/exec/tail", constraints: %{}},
    %{resource_uri: "arbor://shell/exec/grep", constraints: %{}},
    %{resource_uri: "arbor://shell/exec/find", constraints: %{}},
    %{resource_uri: "arbor://shell/exec/wc", constraints: %{}},
    %{resource_uri: "arbor://shell/exec/curl", constraints: %{rate_limit: 20}},
    %{resource_uri: "arbor://shell/exec/echo", constraints: %{}},
    %{resource_uri: "arbor://shell/exec/mkdir", constraints: %{}},
    %{resource_uri: "arbor://shell/exec/cp", constraints: %{}},
    %{resource_uri: "arbor://shell/exec/mv", constraints: %{}},
    # Agent spawning - limited
    %{resource_uri: "arbor://agent/spawn", constraints: %{rate_limit: 10}},
    # Network access - limited
    %{resource_uri: "arbor://net/http/", constraints: %{rate_limit: 30}},
    %{resource_uri: "arbor://net/search", constraints: %{rate_limit: 20}},
    # Generic tool access - fallback
    %{resource_uri: "arbor://tool/", constraints: %{}}
  ]

  # Dangerous commands that require elevated trust
  @dangerous_commands ~w(rm sudo su chmod chown kill pkill dd mkfs fdisk)

  @doc """
  Ensure a Claude session is registered as an Arbor agent.

  If the session is already registered, returns the existing agent_id.
  Otherwise, creates a trust profile and grants default capabilities.

  ## Parameters

  - `session_id` - Claude Code session UUID
  - `cwd` - Current working directory

  ## Returns

  - `{:ok, agent_id}` - Agent ID (format: "agent_claude_<session_id>")
  """
  @spec ensure_registered(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_registered(session_id, cwd) do
    agent_id = to_agent_id(session_id)

    case Arbor.Trust.get_trust_profile(agent_id) do
      {:ok, _profile} ->
        # Already registered
        Logger.debug("Claude session already registered", agent_id: agent_id)
        {:ok, agent_id}

      {:error, :not_found} ->
        # New session, register it
        register_new_session(agent_id, session_id, cwd)
    end
  end

  @doc """
  Authorize a Claude Code tool call.

  ## Parameters

  - `session_id` - Claude Code session UUID
  - `tool_name` - Tool name (Read, Write, Bash, etc.)
  - `tool_input` - Tool parameters
  - `cwd` - Current working directory

  ## Returns

  - `{:ok, :authorized}` - Tool is allowed
  - `{:ok, :authorized, updated_input}` - Tool is allowed with modified parameters
  - `{:error, :unauthorized, reason}` - Tool is blocked
  """
  @spec authorize_tool(String.t(), String.t(), map(), String.t()) ::
          {:ok, :authorized}
          | {:ok, :authorized, map()}
          | {:error, :unauthorized, String.t()}
  def authorize_tool(session_id, tool_name, tool_input, cwd) do
    agent_id = to_agent_id(session_id)

    # Ensure registered
    case ensure_registered(session_id, cwd) do
      {:ok, ^agent_id} ->
        do_authorize(agent_id, tool_name, tool_input, cwd)

      {:error, reason} ->
        Logger.warning("Failed to register Claude session",
          session_id: session_id,
          reason: inspect(reason)
        )

        {:error, :unauthorized, "Session registration failed"}
    end
  end

  @doc """
  Get the agent ID for a Claude session.
  """
  @spec to_agent_id(String.t()) :: String.t()
  def to_agent_id(session_id), do: "agent_claude_#{session_id}"

  @doc """
  Check if a command is considered dangerous.
  """
  @spec dangerous_command?(String.t()) :: boolean()
  def dangerous_command?(command) when is_binary(command) do
    base_cmd = command |> String.split() |> List.first() || ""
    base_cmd in @dangerous_commands
  end

  # Private functions

  defp register_new_session(agent_id, session_id, cwd) do
    Logger.info("Registering new Claude session",
      agent_id: agent_id,
      session_id: session_id,
      cwd: cwd
    )

    # Create trust profile
    case Arbor.Trust.create_trust_profile(agent_id) do
      {:ok, _profile} ->
        # Grant default capabilities
        grant_default_capabilities(agent_id, cwd)
        {:ok, agent_id}

      {:error, :already_exists} ->
        # Race condition, profile was created between check and create
        {:ok, agent_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp grant_default_capabilities(agent_id, cwd) do
    Logger.debug("Granting default capabilities", agent_id: agent_id)

    Enum.each(@default_capabilities, fn template ->
      # Expand the resource URI with the cwd for file paths
      resource_uri = expand_resource_uri(template.resource_uri, cwd)

      case Arbor.Security.grant(
             principal: agent_id,
             resource: resource_uri,
             constraints: template.constraints
           ) do
        {:ok, _cap} ->
          Logger.debug("Granted capability",
            agent_id: agent_id,
            resource: resource_uri
          )

        {:error, reason} ->
          Logger.warning("Failed to grant capability",
            agent_id: agent_id,
            resource: resource_uri,
            reason: inspect(reason)
          )
      end
    end)
  end

  defp expand_resource_uri(uri, _cwd) do
    # For now, keep URIs as-is
    # Could expand "arbor://fs/read/" to "arbor://fs/read/#{cwd}/"
    uri
  end

  defp do_authorize(agent_id, "Bash", %{"command" => command} = tool_input, cwd) do
    # Special handling for Bash - check if command is dangerous
    if dangerous_command?(command) do
      {:error, :unauthorized,
       "Dangerous command '#{command |> String.split() |> List.first()}' requires elevated trust"}
    else
      base_cmd = command |> String.split() |> List.first() || "unknown"
      resource_uri = "arbor://shell/exec/#{base_cmd}?cwd=#{URI.encode(cwd)}"
      authorize_resource(agent_id, resource_uri, :execute, tool_input)
    end
  end

  defp do_authorize(agent_id, "Read", %{"file_path" => path} = tool_input, _cwd) do
    resource_uri = "arbor://fs/read/#{normalize_path(path)}"
    authorize_resource(agent_id, resource_uri, :read, tool_input)
  end

  defp do_authorize(agent_id, "Write", %{"file_path" => path} = tool_input, _cwd) do
    resource_uri = "arbor://fs/write/#{normalize_path(path)}"
    authorize_resource(agent_id, resource_uri, :write, tool_input)
  end

  defp do_authorize(agent_id, "Edit", %{"file_path" => path} = tool_input, _cwd) do
    resource_uri = "arbor://fs/write/#{normalize_path(path)}"
    authorize_resource(agent_id, resource_uri, :write, tool_input)
  end

  defp do_authorize(agent_id, "Grep", tool_input, _cwd) do
    path = Map.get(tool_input, "path", ".")
    resource_uri = "arbor://fs/read/#{normalize_path(path)}"
    authorize_resource(agent_id, resource_uri, :read, tool_input)
  end

  defp do_authorize(agent_id, "Glob", tool_input, _cwd) do
    path = Map.get(tool_input, "path", ".")
    resource_uri = "arbor://fs/read/#{normalize_path(path)}"
    authorize_resource(agent_id, resource_uri, :read, tool_input)
  end

  defp do_authorize(agent_id, "Task", tool_input, _cwd) do
    authorize_resource(agent_id, "arbor://agent/spawn", :spawn, tool_input)
  end

  defp do_authorize(agent_id, "WebFetch", %{"url" => url} = tool_input, _cwd) do
    resource_uri = "arbor://net/http/#{URI.encode(url)}"
    authorize_resource(agent_id, resource_uri, :read, tool_input)
  end

  defp do_authorize(agent_id, "WebSearch", tool_input, _cwd) do
    authorize_resource(agent_id, "arbor://net/search", :read, tool_input)
  end

  defp do_authorize(agent_id, tool_name, tool_input, _cwd) do
    # Generic tool - use fallback capability
    resource_uri = "arbor://tool/#{String.downcase(tool_name)}"
    authorize_resource(agent_id, resource_uri, :use, tool_input)
  end

  defp authorize_resource(agent_id, resource_uri, action, _tool_input) do
    case Arbor.Security.authorize(agent_id, resource_uri, action) do
      {:ok, :authorized} ->
        {:ok, :authorized}

      {:ok, :pending_approval, proposal_id} ->
        {:error, :unauthorized, "Requires approval (proposal: #{proposal_id})"}

      {:error, _reason} ->
        {:error, :unauthorized, "No capability for #{resource_uri}"}
    end
  end

  defp normalize_path(path) when is_binary(path) do
    path
    |> Path.expand()
    |> String.replace(~r{^/Users/[^/]+/}, "~/")
  end

  defp normalize_path(_), do: ""
end
