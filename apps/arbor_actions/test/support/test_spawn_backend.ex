defmodule Arbor.Actions.TestSpawnBackend do
  @moduledoc """
  Functional test adapter for trusted, finite fixture projects.

  This adapter is deliberately test-only and is not evidence of a production
  containment backend. Security tests remove its configuration when asserting
  the macOS spawn-capable path fails closed.
  """

  @behaviour Arbor.Shell.SpawnBackend

  @impl true
  def capabilities do
    [
      :atomic_executable_identity,
      :deadline,
      :isolated_worktree_mount,
      :output_limit,
      :owner_lifecycle,
      :spawn_processes,
      :whole_unit_termination
    ]
  end

  @impl true
  def available?(%{
        tool: tool,
        cwd: cwd,
        cwd_identity: cwd_identity,
        owner: owner,
        deadline: deadline
      }) do
    expected_digest = tool.sha256

    with true <- File.dir?(cwd),
         true <- owner == self() and Process.alive?(owner),
         true <- System.monotonic_time(:millisecond) < deadline,
         {:ok, stat} <- File.stat(cwd, time: :posix),
         true <-
           {stat.major_device, stat.inode, stat.mode} ==
             {cwd_identity.device, cwd_identity.inode, cwd_identity.mode},
         {:ok, contents} <- File.read(tool.path),
         ^expected_digest <- sha256(contents) do
      :ok
    else
      _other -> {:error, :test_tool_identity_changed}
    end
  end

  @impl true
  def execute(request) do
    started_at = System.monotonic_time(:millisecond)

    case System.cmd(request.tool.path, request.args,
           cd: request.cwd,
           env: command_env(request.env),
           stderr_to_stdout: true
         ) do
      {output, exit_code} ->
        if byte_size(output) <= request.max_output_bytes do
          {:ok,
           %{
             exit_code: exit_code,
             stdout: output,
             stderr: "",
             duration_ms: System.monotonic_time(:millisecond) - started_at,
             timed_out: false,
             killed: false,
             output_truncated: false,
             output_limit_exceeded: false
           }}
        else
          {:error, :test_output_limit_exceeded}
        end
    end
  end

  defp command_env(env) do
    Enum.map(env, fn
      {key, false} -> {key, nil}
      {key, value} -> {key, value}
    end)
  end

  defp sha256(contents),
    do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
