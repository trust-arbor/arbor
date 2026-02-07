defmodule Arbor.AI.AgentSDK.Permissions do
  @moduledoc """
  Permission mode handling for the Agent SDK.

  Controls how Claude handles permission requests for file edits and
  potentially dangerous operations. Matches the permission modes from
  the official Python and TypeScript SDKs.

  ## Permission Modes

  - `:default` — Uses Claude CLI's default behavior
  - `:accept_edits` — Auto-accept file edit requests
  - `:plan` — Plan mode, no writes allowed
  - `:bypass` — Skip all permission checks (dangerous, for trusted agents only)

  ## Usage

      Arbor.AI.AgentSDK.query("Edit the file",
        permission_mode: :accept_edits
      )

  ## Tool Restrictions

  You can also restrict which tools Claude can use:

      Arbor.AI.AgentSDK.query("...",
        allowed_tools: ["Read", "Write", "Bash"],
        # OR
        disallowed_tools: ["Bash"]
      )
  """

  @type permission_mode :: :default | :accept_edits | :plan | :bypass

  @valid_modes [:default, :accept_edits, :plan, :bypass]

  @doc """
  Build CLI flags for the given permission mode.
  """
  @spec cli_flags(permission_mode()) :: [String.t()]
  def cli_flags(:default), do: []
  def cli_flags(:accept_edits), do: ["--allowedTools", "Edit,Write,NotebookEdit"]
  def cli_flags(:plan), do: ["--allowedTools", "Read,Glob,Grep,WebFetch,WebSearch"]
  def cli_flags(:bypass), do: ["--dangerously-skip-permissions"]

  @doc """
  Build CLI flags for tool restrictions.
  """
  @spec tool_restriction_flags(keyword()) :: [String.t()]
  def tool_restriction_flags(opts) do
    cond do
      allowed = Keyword.get(opts, :allowed_tools) ->
        tools = Enum.map_join(allowed, ",", &to_string/1)
        ["--allowedTools", tools]

      disallowed = Keyword.get(opts, :disallowed_tools) ->
        tools = Enum.map_join(disallowed, ",", &to_string/1)
        ["--disallowedTools", tools]

      true ->
        []
    end
  end

  @doc """
  Validate a permission mode.
  """
  @spec validate_mode(term()) :: {:ok, permission_mode()} | {:error, String.t()}
  def validate_mode(mode) when mode in @valid_modes, do: {:ok, mode}

  def validate_mode(mode) do
    {:error, "Invalid permission mode: #{inspect(mode)}. Valid modes: #{inspect(@valid_modes)}"}
  end

  @doc """
  Get the default permission mode from application config.
  """
  @spec default_mode() :: permission_mode()
  def default_mode do
    Application.get_env(:arbor_ai, :sdk_default_permission_mode, :default)
  end

  @doc """
  Resolve the effective permission mode from options and defaults.
  """
  @spec resolve_mode(keyword()) :: permission_mode()
  def resolve_mode(opts) do
    Keyword.get(opts, :permission_mode, default_mode())
  end

  @plan_allowed_tools ~w(Read Glob Grep WebFetch WebSearch)

  @doc """
  Check if a tool is allowed under the current permission and restriction settings.

  For in-process tools executed via ToolServer, CLI flags don't apply.
  This function provides equivalent local enforcement.

  Returns `:ok` if allowed, `{:error, reason}` if denied.
  """
  @spec check_tool_allowed?(String.t(), keyword()) :: :ok | {:error, String.t()}
  def check_tool_allowed?(tool_name, opts) do
    mode = resolve_mode(opts)
    check_mode_restriction(tool_name, mode, opts)
  end

  defp check_mode_restriction(tool_name, :plan, opts) do
    plan_tools = Keyword.get(opts, :plan_allowed_tools, @plan_allowed_tools)

    if tool_name in plan_tools do
      check_tool_lists(tool_name, opts)
    else
      {:error, "Tool #{tool_name} not allowed in plan mode"}
    end
  end

  defp check_mode_restriction(tool_name, _mode, opts) do
    check_tool_lists(tool_name, opts)
  end

  defp check_tool_lists(tool_name, opts) do
    cond do
      allowed = Keyword.get(opts, :allowed_tools) ->
        allowed_strings = Enum.map(allowed, &to_string/1)

        if tool_name in allowed_strings do
          :ok
        else
          {:error, "Tool #{tool_name} not in allowed tools list"}
        end

      disallowed = Keyword.get(opts, :disallowed_tools) ->
        disallowed_strings = Enum.map(disallowed, &to_string/1)

        if tool_name in disallowed_strings do
          {:error, "Tool #{tool_name} is in disallowed tools list"}
        else
          :ok
        end

      true ->
        :ok
    end
  end
end
