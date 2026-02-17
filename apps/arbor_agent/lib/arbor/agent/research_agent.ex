defmodule Arbor.Agent.ResearchAgent do
  @moduledoc """
  Convenience module for creating and managing persistent Research agents.

  Wraps `Arbor.Agent.Manager` with `Researcher` template defaults.
  Research agents have read-only file access, memory, pipeline execution,
  docs lookup, eval checks, and advisory council access.

  ## Usage

      # Create and start a new research agent
      {:ok, agent_id, pid} = ResearchAgent.start("my-researcher")

      # Query the agent
      {:ok, response} = ResearchAgent.query(agent_id, "Analyze the security module architecture")

      # Resume after restart
      {:ok, agent_id, pid} = ResearchAgent.resume(agent_id)

      # Stop
      :ok = ResearchAgent.stop(agent_id)

      # List all research agents
      profiles = ResearchAgent.list()
  """

  alias Arbor.Agent.{Manager, APIAgent, Lifecycle}

  @template Arbor.Agent.Templates.Researcher

  @default_model_config %{
    backend: :api,
    id: "arcee-ai/trinity-large-preview:free",
    provider: :openrouter
  }

  @doc """
  Create and start a new Research agent.

  ## Options

  - `:model_config` — LLM model configuration (default: trinity-large-preview)
  - `:capabilities` — additional capabilities beyond template defaults
  - `:initial_goals` — override template initial goals

  ## Returns

  `{:ok, agent_id, pid}` or `{:error, reason}`
  """
  @spec start(String.t(), keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def start(display_name, opts \\ []) do
    model_config = Keyword.get(opts, :model_config, @default_model_config)

    Manager.start_agent(
      model_config,
      Keyword.merge(opts,
        display_name: display_name,
        template: @template
      )
    )
  end

  @doc """
  Start or resume a Research agent by display name.

  If an agent with this name already exists, resumes it.
  Otherwise creates a new one.
  """
  @spec start_or_resume(String.t(), keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def start_or_resume(display_name, opts \\ []) do
    model_config = Keyword.get(opts, :model_config, @default_model_config)

    Manager.start_or_resume(
      APIAgent,
      display_name,
      Keyword.merge(opts,
        template: @template,
        model_config: model_config
      )
    )
  end

  @doc """
  Resume an existing Research agent by agent_id.
  """
  @spec resume(String.t(), keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def resume(agent_id, opts \\ []) do
    Manager.resume_agent(agent_id, opts)
  end

  @doc """
  Query a running Research agent.

  Returns the response text on success.
  """
  @spec query(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def query(agent_id, prompt, opts \\ []) do
    case Manager.find_agent(agent_id) do
      {:ok, pid, _metadata} ->
        APIAgent.query(pid, prompt, opts)

      :not_found ->
        {:error, :agent_not_running}
    end
  end

  @doc """
  Stop a running Research agent.
  """
  @spec stop(String.t()) :: :ok | {:error, term()}
  def stop(agent_id) do
    Manager.stop_agent(agent_id)
  end

  @doc """
  List all Research agent profiles (running or persisted).
  """
  @spec list() :: [Arbor.Agent.Profile.t()]
  def list do
    Lifecycle.list_agents()
    |> Enum.filter(fn profile ->
      profile.template == @template or
        (is_map(profile.metadata) and
           Map.get(profile.metadata, :template) == @template)
    end)
  end
end
