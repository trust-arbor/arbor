defmodule Mix.Tasks.Arbor.Jobs.Create do
  @shortdoc "Create a new job on the running Arbor server"
  @moduledoc """
  Creates a new job on the running Arbor server.

      $ mix arbor.jobs.create "Deploy staging environment"
      $ mix arbor.jobs.create "Fix login bug" --priority high
      $ mix arbor.jobs.create "Run tests" --priority normal --tag ci --tag testing

  The first positional argument is the job title (required).

  ## Options

    * `--priority` - Job priority (default: "normal")
    * `--tag` - Tag to apply; can be repeated (e.g., `--tag ci --tag deploy`)
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @impl Mix.Task
  def run([]) do
    Mix.shell().error(
      "Usage: mix arbor.jobs.create \"Job title\" [--priority PRIORITY] [--tag TAG]"
    )

    exit({:shutdown, 1})
  end

  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [priority: :string, tag: :keep],
        aliases: [p: :priority, t: :tag]
      )

    title =
      case positional do
        [title | _] ->
          title

        [] ->
          Mix.shell().error(
            "Usage: mix arbor.jobs.create \"Job title\" [--priority PRIORITY] [--tag TAG]"
          )

          exit({:shutdown, 1})
      end

    priority = opts[:priority] || "normal"
    tags = Keyword.get_values(opts, :tag)

    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor is not running. Start it with: mix arbor.start")
      exit({:shutdown, 1})
    end

    node = Config.full_node_name()

    params = %{title: title, priority: priority}
    params = if tags != [], do: Map.put(params, :tags, tags), else: params

    case :rpc.call(node, Arbor.Actions.Jobs.CreateJob, :run, [params, %{}]) do
      {:badrpc, reason} ->
        Mix.shell().error("RPC failed: #{inspect(reason)}")
        exit({:shutdown, 1})

      {:ok, %{job_id: job_id}} ->
        Mix.shell().info("Created job: #{job_id} — #{title}")

      {:ok, %{id: job_id}} ->
        Mix.shell().info("Created job: #{job_id} — #{title}")

      {:error, reason} ->
        Mix.shell().error("Failed to create job: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
