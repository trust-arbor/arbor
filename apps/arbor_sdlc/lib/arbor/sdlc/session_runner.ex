defmodule Arbor.SDLC.SessionRunner do
  @moduledoc """
  Manages individual CLI sessions for SDLC work items.

  SessionRunner is a GenServer that:
  - Spawns Claude CLI sessions for work items
  - Tracks session IDs for continuation
  - Reports completion/failure to parent processor
  - Uses hooks for completion detection (not output patterns)

  ## Usage

      {:ok, pid} = SessionRunner.start_link(
        item_path: "/path/to/item.md",
        prompt: "Implement feature X",
        parent: self(),
        execution_mode: :auto
      )

  ## Completion Detection

  Sessions are detected as complete via:
  1. SessionEnd hooks firing through gateway -> signal bus
  2. The InProgressProcessor subscribes to session signals

  ## Messages Sent to Parent

  - `{:session_started, item_path, session_id}` - Session launched
  - `{:session_complete, item_path, session_id, output}` - Session finished
  - `{:session_error, item_path, reason}` - Session failed to start
  """

  use GenServer

  require Logger

  alias Arbor.SDLC.Config
  alias Mix.Tasks.Arbor.HandsHelpers, as: Hands

  @type execution_mode :: :auto | :hand

  defstruct [
    :item_path,
    :prompt,
    :parent,
    :session_id,
    :execution_mode,
    :started_at,
    :config,
    :hand_name,
    :working_dir,
    :env_vars
  ]

  # =============================================================================
  # Client API
  # =============================================================================

  @doc """
  Start a new session runner.

  ## Options

  - `:item_path` - Required. Path to the work item file
  - `:prompt` - Required. The prompt to send to Claude
  - `:parent` - Required. PID to notify of completion
  - `:execution_mode` - `:auto` (CLI) or `:hand` (full Hand with worktree)
  - `:config` - Optional. Config struct
  - `:working_dir` - Optional. Working directory for the session
  - `:env_vars` - Optional. Additional environment variables
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Get the current state of a session runner.
  """
  @spec get_state(GenServer.server()) :: map()
  def get_state(runner) do
    GenServer.call(runner, :get_state)
  end

  @doc """
  Stop the session runner and terminate any running session.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(runner) do
    GenServer.stop(runner, :normal)
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl GenServer
  def init(opts) do
    item_path = Keyword.fetch!(opts, :item_path)
    prompt = Keyword.fetch!(opts, :prompt)
    parent = Keyword.fetch!(opts, :parent)

    config = Keyword.get(opts, :config, Config.new())
    execution_mode = Keyword.get(opts, :execution_mode, :auto)
    working_dir = Keyword.get(opts, :working_dir, File.cwd!())
    env_vars = Keyword.get(opts, :env_vars, %{})

    state = %__MODULE__{
      item_path: item_path,
      prompt: prompt,
      parent: parent,
      execution_mode: execution_mode,
      config: config,
      working_dir: working_dir,
      env_vars: env_vars,
      started_at: DateTime.utc_now()
    }

    # Start the session asynchronously
    send(self(), :start_session)

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:start_session, state) do
    case state.execution_mode do
      :auto ->
        start_auto_session(state)

      :hand ->
        start_hand_session(state)
    end
  end

  @impl GenServer
  def handle_call(:get_state, _from, state) do
    info = %{
      item_path: state.item_path,
      session_id: state.session_id,
      execution_mode: state.execution_mode,
      started_at: state.started_at,
      hand_name: state.hand_name
    }

    {:reply, info, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Clean up Hand if we spawned one
    if state.hand_name do
      cleanup_hand(state.hand_name)
    end

    :ok
  end

  # =============================================================================
  # Auto Session (Lightweight CLI)
  # =============================================================================

  defp start_auto_session(state) do
    Logger.info("Starting auto session for item", item_path: state.item_path)

    # Build a session ID based on item path
    session_id = generate_session_id(state.item_path)

    # Prepare environment with SDLC context
    env = build_env(state, session_id)

    # Build the claude command
    # Use -p for print mode with the prompt
    args = [
      "-p",
      state.prompt,
      "--output-format",
      "json",
      "--dangerously-skip-permissions"
    ]

    # Notify parent that session is starting
    send(state.parent, {:session_started, state.item_path, session_id})

    # Run the CLI command asynchronously
    Task.start(fn ->
      run_cli_session(state.parent, state.item_path, session_id, args, env, state.working_dir)
    end)

    {:noreply, %{state | session_id: session_id}}
  end

  defp run_cli_session(parent, item_path, session_id, args, env, working_dir) do
    Logger.info("Executing CLI session",
      item_path: item_path,
      session_id: session_id
    )

    # Convert env map to list of tuples for System.cmd
    env_list = Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end)

    cmd_opts = [
      stderr_to_stdout: true,
      cd: working_dir,
      env: env_list
    ]

    # Use Port for long-running session with streaming output
    case System.cmd("claude", args, cmd_opts) do
      {output, 0} ->
        Logger.info("CLI session completed successfully",
          item_path: item_path,
          session_id: session_id
        )

        send(parent, {:session_complete, item_path, session_id, output})

      {output, exit_code} ->
        Logger.warning("CLI session exited with error",
          item_path: item_path,
          session_id: session_id,
          exit_code: exit_code
        )

        send(parent, {:session_error, item_path, {:exit_code, exit_code, output}})
    end
  rescue
    e ->
      Logger.error("CLI session failed",
        item_path: item_path,
        error: Exception.message(e)
      )

      send(parent, {:session_error, item_path, {:exception, Exception.message(e)}})
  end

  # =============================================================================
  # Hand Session (Full worktree + tmux)
  # =============================================================================

  defp start_hand_session(state) do
    Logger.info("Starting Hand session for item", item_path: state.item_path)

    # Generate a hand name from the item path
    hand_name = generate_hand_name(state.item_path)
    session_id = "hand-#{hand_name}"

    # Check if hand already exists
    case Hands.find_hand(hand_name) do
      :not_found ->
        spawn_new_hand(state, hand_name, session_id)

      {_type, _info} ->
        Logger.warning("Hand already exists, reusing",
          hand_name: hand_name,
          item_path: state.item_path
        )

        send(state.parent, {:session_started, state.item_path, session_id})
        {:noreply, %{state | session_id: session_id, hand_name: hand_name}}
    end
  end

  defp spawn_new_hand(state, hand_name, session_id) do
    # Prepare hand directory
    hand_dir = Hands.ensure_hand_dir(hand_name)

    # Create worktree
    case Hands.create_worktree(hand_name) do
      {:ok, wt_path} ->
        Logger.info("Created worktree for Hand",
          hand_name: hand_name,
          worktree: wt_path
        )

        # Build the hand prompt with worktree context
        prompt = Hands.build_prompt(hand_name, state.prompt, worktree: true)
        prompt_file = Path.join(hand_dir, "prompt.md")
        File.write!(prompt_file, prompt)

        # Build environment
        env = build_env(state, session_id)

        # Spawn the hand via tmux
        case spawn_tmux_hand(hand_name, hand_dir, prompt_file, wt_path, env) do
          :ok ->
            send(state.parent, {:session_started, state.item_path, session_id})
            {:noreply, %{state | session_id: session_id, hand_name: hand_name}}

          {:error, reason} ->
            send(state.parent, {:session_error, state.item_path, {:spawn_failed, reason}})
            {:stop, :normal, state}
        end

      {:error, reason} ->
        Logger.error("Failed to create worktree",
          hand_name: hand_name,
          reason: reason
        )

        send(state.parent, {:session_error, state.item_path, {:worktree_failed, reason}})
        {:stop, :normal, state}
    end
  end

  defp spawn_tmux_hand(hand_name, hand_dir, prompt_file, working_dir, env) do
    config_dir = Hands.config_dir()
    session = Hands.tmux_session_name(hand_name)

    unless File.dir?(config_dir) do
      Logger.error("Hands credential directory not found", config_dir: config_dir)
      {:error, :no_credentials}
    end

    # Write run script
    run_script = Path.join(hand_dir, "run.sh")

    # Build environment exports
    env_exports =
      Enum.map_join(env, "\n", fn {k, v} -> "export #{k}=\"#{v}\"" end)

    script_content = """
    #!/bin/bash
    export CLAUDE_CONFIG_DIR=#{config_dir}
    #{env_exports}
    cd #{working_dir}
    echo "Bootstrapping worktree dependencies..."
    mix deps.get --only dev test 2>&1 || echo "Warning: some deps unavailable"
    mix compile 2>&1 || echo "Warning: compilation had errors"
    echo "Bootstrap complete. Launching Claude..."
    exec claude -p "$(cat #{prompt_file})" --dangerously-skip-permissions
    """

    File.write!(run_script, script_content)
    File.chmod!(run_script, 0o755)

    # Start tmux session
    {output, exit_code} =
      System.cmd(
        "tmux",
        [
          "new-session",
          "-d",
          "-s",
          session,
          "#{run_script}; exec bash"
        ],
        stderr_to_stdout: true
      )

    if exit_code == 0 do
      Logger.info("Hand spawned via tmux",
        hand_name: hand_name,
        session: session
      )

      :ok
    else
      Logger.error("Failed to start tmux session",
        output: output,
        exit_code: exit_code
      )

      {:error, output}
    end
  end

  defp cleanup_hand(hand_name) do
    Logger.info("Cleaning up Hand", hand_name: hand_name)

    case Hands.find_hand(hand_name) do
      {:local, %{session: session}} ->
        System.cmd("tmux", ["kill-session", "-t", session], stderr_to_stdout: true)

      {:sandbox, %{container: container}} ->
        System.cmd("docker", ["rm", "-f", container], stderr_to_stdout: true)

      :not_found ->
        :ok
    end
  end

  # =============================================================================
  # Helpers
  # =============================================================================

  defp generate_session_id(item_path) do
    # Create a unique session ID from item path and timestamp
    basename = Path.basename(item_path, ".md")
    timestamp = System.system_time(:second)
    "sdlc-#{basename}-#{timestamp}"
  end

  defp generate_hand_name(item_path) do
    # Create a hand name from item path
    basename =
      item_path
      |> Path.basename(".md")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.slice(0, 30)

    timestamp = System.system_time(:second) |> rem(100_000)
    "sdlc-#{basename}-#{timestamp}"
  end

  defp build_env(state, session_id) do
    base_env = %{
      "ARBOR_SDLC_ITEM_PATH" => state.item_path,
      "ARBOR_SDLC_SESSION_ID" => session_id,
      "ARBOR_SESSION_TYPE" => "sdlc_auto"
    }

    Map.merge(base_env, state.env_vars)
  end
end
