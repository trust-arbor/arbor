defmodule LLMStandaloneConsumer.Ports do
  @moduledoc false

  @keys [:base_url, :model, :provider, :runtime, :sensitivity]
  @models ["cold-chat", "cold-object", "cold-embed", "cold-tool"]

  def context, do: Application.fetch_env!(:llm_standalone_consumer, :context)

  def allow(url) do
    {:ok, origin} = origin(url)
    Agent.update(context(), fn state -> %{state | origin: origin} end)
  end

  def counts, do: Agent.get(context(), &Map.take(&1, [:audits, :effects]))

  def reset, do: Agent.update(context(), &%{&1 | audits: 0, effects: 0})

  def admitted?(destination) do
    is_map(destination) and not is_struct(destination) and
      Enum.sort(Map.keys(destination)) == @keys and
      destination.provider == "lm_studio" and destination.model in @models and
      destination.sensitivity in [:public, :internal] and destination.runtime == :arbor and
      admitted_origin?(destination.base_url)
  end

  defp admitted_origin?(url) do
    case origin(url) do
      {:ok, origin} -> Agent.get(context(), &(&1.origin == origin))
      {:error, _} -> false
    end
  end

  defp origin(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{
        scheme: "http",
        host: "127.0.0.1",
        port: port,
        userinfo: nil,
        query: nil,
        fragment: nil,
        path: path
      }
      when port in 1..65_535 and
             path in ["/v1", "/v1/chat/completions", "/v1/embeddings"] ->
        {:ok, {"http", "127.0.0.1", port}}

      _ ->
        {:error, :invalid_origin}
    end
  end

  defp origin(_), do: {:error, :invalid_origin}
end

defmodule LLMStandaloneConsumer.Policy do
  @moduledoc false
  @behaviour Arbor.LLM.Contracts.SensitivityPolicy

  @impl true
  def authorize_llm_sensitivity(destination) do
    if LLMStandaloneConsumer.Ports.admitted?(destination),
      do: :ok,
      else: {:error, :destination_disallowed}
  end
end

defmodule LLMStandaloneConsumer.Auditor do
  @moduledoc false

  def with_invocation_audit(attributes, effect) when is_function(effect, 0) do
    expected = %{
      principal_id: "system",
      surface: :tool,
      tool: "cold_increment",
      session_id: "cold_session",
      task_id: "cold_task",
      provider_call_id: "cold_call_1"
    }

    if attributes == expected do
      Agent.update(LLMStandaloneConsumer.Ports.context(), &%{&1 | audits: &1.audits + 1})
      effect.()
    else
      {:error, :invocation_audit_unavailable}
    end
  end
end

defmodule LLMStandaloneConsumer.Executor do
  @moduledoc false

  def execute("cold_increment", %{"value" => 1}, _workdir, opts) do
    if opts[:provider_call_id] == "cold_call_1" and opts[:session_id] == "cold_session" and
         opts[:task_id] == "cold_task" and opts[:agent_id] == "system" do
      Agent.update(LLMStandaloneConsumer.Ports.context(), &%{&1 | effects: &1.effects + 1})
      {:ok, %{"value" => 2}}
    else
      {:error, :consumer_binding_mismatch}
    end
  end

  def execute(_name, _args, _workdir, _opts), do: {:error, :consumer_tool_refused}
end
