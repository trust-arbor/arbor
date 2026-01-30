defmodule Mix.Tasks.Arbor.Server do
  @moduledoc """
  Shared configuration and helpers for Arbor server lifecycle tasks.

  All `mix arbor.server.*` tasks use these constants and helpers to manage
  the Arbor development server as a background daemon.
  """

  @node_name :arbor_dev
  @full_node_name :"arbor_dev@localhost"
  @cookie :arbor_dev
  @pid_file "/tmp/arbor-dev.pid"
  @log_file "/tmp/arbor-dev.log"

  def node_name, do: @node_name
  def full_node_name, do: @full_node_name
  def cookie, do: @cookie
  def pid_file, do: @pid_file
  def log_file, do: @log_file

  @doc "Returns the hostname used for node names."
  def node_hostname, do: "localhost"

  @doc "Checks if the server node is responding to pings."
  def server_running? do
    :net_adm.ping(full_node_name()) == :pong
  end

  @doc "Reads the OS PID from the PID file, or returns nil."
  def read_pid do
    case File.read(@pid_file) do
      {:ok, content} ->
        content |> String.trim() |> String.to_integer()

      _ ->
        nil
    end
  end

  @doc """
  Ensures the current Mix process has distribution started so it can
  communicate with the server node via `:net_adm` and `:rpc`.

  Uses a unique name to avoid conflicts with the server node.
  """
  def ensure_distribution do
    unless Node.alive?() do
      suffix = :rand.uniform(99_999)
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"arbor_mix_#{suffix}@localhost"
      {:ok, _} = Node.start(name, :shortnames)
      Node.set_cookie(@cookie)
    end

    :ok
  end
end
