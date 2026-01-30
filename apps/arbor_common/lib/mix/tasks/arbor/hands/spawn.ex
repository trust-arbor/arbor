defmodule Mix.Tasks.Arbor.Hands.Spawn do
  @shortdoc "Spawn a new Hand (independent Claude Code session)"
  @moduledoc """
  Spawns a new Hand to work on a task independently.

      $ mix arbor.hands.spawn "Write tests for Arbor.Security" --name security-tests
      $ mix arbor.hands.spawn "Fix credo warnings" --name credo-fix --cwd apps/arbor_common
      $ mix arbor.hands.spawn "Risky refactor" --name refactor --sandbox

  The Hand runs `claude -p` with the task prompt, works autonomously, and writes
  a summary to `.arbor/hands/<name>/summary.md` when finished.

  Uses a separate credential directory (`CLAUDE_CONFIG_DIR`) so Hands use
  a different account/quota from the Mind session.

  ## Options

    * `--name` - Name for the hand (required)
    * `--sandbox` - Use Docker sandbox instead of local tmux
    * `--cwd` - Working directory relative to project root (default: project root)
    * `--interactive` - Start in interactive mode (accepts guidance via `send`)
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.HandsHelpers, as: Hands

  # Docker container internal home directory (not a host path)
  @docker_home "/home/claude"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [name: :string, sandbox: :boolean, cwd: :string, interactive: :boolean]
      )

    task = Enum.join(positional, " ")

    if task == "" do
      Mix.shell().error("Usage: mix arbor.hands.spawn \"task description\" --name <name>")
      exit({:shutdown, 1})
    end

    name = opts[:name]

    unless name do
      Mix.shell().error("--name is required")
      exit({:shutdown, 1})
    end

    # Validate name (alphanumeric, hyphens, underscores only)
    unless Regex.match?(~r/^[a-zA-Z0-9_-]+$/, name) do
      Mix.shell().error("Hand name must be alphanumeric (hyphens and underscores allowed)")
      exit({:shutdown, 1})
    end

    # Check if hand already exists
    case Hands.find_hand(name) do
      :not_found ->
        :ok

      {type, _} ->
        Mix.shell().error("Hand '#{name}' already exists (#{type})")
        exit({:shutdown, 1})
    end

    # Resolve working directory
    project_root = File.cwd!()

    cwd =
      if opts[:cwd] do
        resolved = Path.join(project_root, opts[:cwd])

        unless File.dir?(resolved) do
          Mix.shell().error("Directory not found: #{resolved}")
          exit({:shutdown, 1})
        end

        resolved
      else
        project_root
      end

    # Prepare hand directory and prompt
    hand_dir = Hands.ensure_hand_dir(name)
    prompt = Hands.build_prompt(name, task)
    prompt_file = Path.join(hand_dir, "prompt.md")
    File.write!(prompt_file, prompt)

    if opts[:sandbox] do
      spawn_sandbox(name, hand_dir, cwd, opts)
    else
      spawn_local(name, hand_dir, prompt_file, cwd, opts)
    end
  end

  defp spawn_local(name, hand_dir, prompt_file, cwd, opts) do
    config_dir = Hands.config_dir()
    session = Hands.tmux_session_name(name)

    unless File.dir?(config_dir) do
      Mix.shell().error("Hands credential directory not found: #{config_dir}")
      Mix.shell().error("Set up credentials first:")
      Mix.shell().error("  CLAUDE_CONFIG_DIR=#{config_dir} claude")
      exit({:shutdown, 1})
    end

    # Write run script
    run_script = Path.join(hand_dir, "run.sh")

    script_content =
      if opts[:interactive] do
        """
        #!/bin/bash
        export CLAUDE_CONFIG_DIR=#{config_dir}
        cd #{cwd}
        exec claude --dangerously-skip-permissions
        """
      else
        """
        #!/bin/bash
        export CLAUDE_CONFIG_DIR=#{config_dir}
        cd #{cwd}
        exec claude -p "$(cat #{prompt_file})" --dangerously-skip-permissions
        """
      end

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

    if exit_code != 0 do
      Mix.shell().error("Failed to start tmux session: #{output}")
      exit({:shutdown, 1})
    end

    # For interactive mode, send the prompt after Claude starts up
    if opts[:interactive] do
      Mix.shell().info("Waiting for Claude to initialize...")
      Process.sleep(5_000)
      send_prompt_via_tmux(session, prompt_file)
    end

    Mix.shell().info("Hand '#{name}' spawned (local)")
    Mix.shell().info("  Session: #{session}")
    Mix.shell().info("  Working dir: #{cwd}")
    Mix.shell().info("  Mode: #{if opts[:interactive], do: "interactive", else: "autonomous"}")
    Mix.shell().info("")
    Mix.shell().info("Commands:")
    Mix.shell().info("  mix arbor.hands.capture #{name}")

    if opts[:interactive] do
      Mix.shell().info("  mix arbor.hands.send #{name} \"message\"")
    end

    Mix.shell().info("  mix arbor.hands.stop #{name}")
  end

  defp spawn_sandbox(name, hand_dir, cwd, opts) do
    container = Hands.docker_container_name(name)
    image = Hands.sandbox_image()

    ensure_docker_image(image)
    write_sandbox_script(hand_dir, name, opts)
    start_sandbox_container(container, image, name, cwd)
    start_sandbox_claude(container, name)

    # For interactive mode, send prompt after startup
    if opts[:interactive] do
      Mix.shell().info("Waiting for Claude to initialize...")
      Process.sleep(5_000)
      send_prompt_via_docker(container, "/workspace/.arbor/hands/#{name}/prompt.md")
    end

    Mix.shell().info("Hand '#{name}' spawned (sandbox)")
    Mix.shell().info("  Container: #{container}")
    Mix.shell().info("  Working dir: #{cwd} -> /workspace")
    Mix.shell().info("  Mode: #{if opts[:interactive], do: "interactive", else: "autonomous"}")
    Mix.shell().info("")
    Mix.shell().info("Commands:")
    Mix.shell().info("  mix arbor.hands.capture #{name}")

    if opts[:interactive] do
      Mix.shell().info("  mix arbor.hands.send #{name} \"message\"")
    end

    Mix.shell().info("  mix arbor.hands.stop #{name}")
  end

  defp ensure_docker_image(image) do
    case System.cmd("docker", ["image", "inspect", image], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        Mix.shell().error("Docker image '#{image}' not found.")
        Mix.shell().error("Build it: ~/.arbor/scripts/docker-claude/run-sandbox.sh build")
        exit({:shutdown, 1})
    end
  end

  defp write_sandbox_script(hand_dir, name, opts) do
    run_script = Path.join(hand_dir, "run-sandbox.sh")
    prompt_path = "/workspace/.arbor/hands/#{name}/prompt.md"

    script_content =
      if opts[:interactive] do
        """
        #!/bin/bash
        export SHELL=/usr/local/bin/arbor-sh
        cd /workspace
        exec claude --dangerously-skip-permissions
        """
      else
        """
        #!/bin/bash
        export SHELL=/usr/local/bin/arbor-sh
        cd /workspace
        exec claude -p "$(cat #{prompt_path})" --dangerously-skip-permissions
        """
      end

    File.write!(run_script, script_content)
    File.chmod!(run_script, 0o755)
  end

  defp start_sandbox_container(container, image, name, cwd) do
    creds_volume = Hands.sandbox_credentials_volume()
    gateway = System.get_env("ARBOR_GATEWAY") || "http://host.docker.internal:4000"

    {output, exit_code} =
      System.cmd(
        "docker",
        [
          "run",
          "-d",
          "--init",
          "--name",
          container,
          "-v",
          "#{creds_volume}:#{@docker_home}/.claude",
          "-v",
          "#{cwd}:/workspace",
          "-e",
          "HOME=#{@docker_home}",
          "-e",
          "TERM=xterm-256color",
          "-e",
          "ARBOR_GATEWAY=#{gateway}",
          "-e",
          "ARBOR_SESSION_ID=hand-#{name}",
          "-e",
          "ARBOR_HOST_WORKSPACE=#{cwd}",
          "-e",
          "SHELL=/usr/local/bin/arbor-sh",
          "-e",
          "CLAUDE_CODE_SKIP_KEYCHAIN=1",
          "-e",
          "NODE_OPTIONS=--no-warnings",
          image,
          "/bin/bash.real",
          "-c",
          "exec tail -f /dev/null"
        ],
        stderr_to_stdout: true
      )

    if exit_code != 0 do
      Mix.shell().error("Failed to start container: #{output}")
      exit({:shutdown, 1})
    end

    Process.sleep(1_000)
  end

  defp start_sandbox_claude(container, name) do
    sandbox_script = "/workspace/.arbor/hands/#{name}/run-sandbox.sh"

    {output, exit_code} =
      System.cmd(
        "docker",
        [
          "exec",
          container,
          "/bin/bash.real",
          "-c",
          "SHELL=/bin/bash.real tmux new-session -d -s claude '#{sandbox_script}; exec /bin/bash.real'"
        ],
        stderr_to_stdout: true
      )

    if exit_code != 0 do
      System.cmd("docker", ["rm", "-f", container], stderr_to_stdout: true)
      Mix.shell().error("Failed to start Claude in container: #{output}")
      exit({:shutdown, 1})
    end
  end

  defp send_prompt_via_tmux(session, prompt_file) do
    # Use tmux load-buffer + paste-buffer to handle long prompts
    System.cmd("tmux", ["load-buffer", "-b", "hand-prompt", prompt_file], stderr_to_stdout: true)

    System.cmd("tmux", ["paste-buffer", "-b", "hand-prompt", "-t", session],
      stderr_to_stdout: true
    )

    System.cmd("tmux", ["send-keys", "-t", session, "Enter"], stderr_to_stdout: true)
  end

  defp send_prompt_via_docker(container, prompt_path) do
    # Read prompt inside container and send via tmux
    System.cmd(
      "docker",
      [
        "exec",
        container,
        "/bin/bash.real",
        "-c",
        "tmux load-buffer -b hand-prompt #{prompt_path} && " <>
          "tmux paste-buffer -b hand-prompt -t claude && " <>
          "tmux send-keys -t claude Enter"
      ],
      stderr_to_stdout: true
    )
  end
end
