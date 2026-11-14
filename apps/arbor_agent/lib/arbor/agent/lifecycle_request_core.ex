defmodule Arbor.Agent.LifecycleRequestCore do
  @moduledoc """
  Pure construction of an operator-signed agent lifecycle request.

  `mix arbor.agent start` and `resume` sign one of these with the operator's
  key file; the server rebuilds the same bytes from the request it is about
  to act on and requires an exact match
  (`Arbor.Agent.submit_signed_lifecycle_request/4`). The payload names the
  operation, the principal and every argument the operation acts on, each
  length-prefixed behind a version tag, so a proof for one start cannot
  authorize another template, name, model or agent. The `SignedRequest`
  envelope adds the principal, a timestamp and a single-use nonce.

  Requests:

    * `%{operation: :start, template:, display_name:, provider:, model:}` —
      start the agent with this name and template, creating it if none exists
    * `%{operation: :resume, agent_id:}` — start an existing stopped agent

  Pure: no IO, time or randomness.
  """

  @version "arbor.agent.lifecycle-request.v1"
  @max_field_bytes 256

  # Canonical provider names, and the atoms the session configuration
  # expects. An explicit table: provider names arrive from the wire.
  @providers %{
    "openrouter" => :openrouter,
    "anthropic" => :anthropic,
    "openai" => :openai,
    "google" => :google,
    "local" => :local,
    "ollama" => :ollama,
    "lmstudio" => :lmstudio,
    "acp" => :acp,
    "gemini" => :gemini,
    "xai" => :xai,
    "openai_oauth" => :openai_oauth,
    "xai_oauth" => :xai_oauth,
    "opencode_zen" => :opencode_zen
  }

  @type start_request :: %{
          operation: :start,
          template: String.t(),
          display_name: String.t(),
          provider: String.t(),
          model: String.t()
        }
  @type resume_request :: %{operation: :resume, agent_id: String.t()}
  @type request :: start_request() | resume_request()

  @doc "Validate and normalize a request map or keyword list."
  @spec new(map() | keyword()) :: {:ok, request()} | {:error, :invalid_lifecycle_request}
  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: new(Map.new(attrs)), else: invalid()
  end

  def new(%{operation: :start} = attrs) do
    with {:ok, template} <- text(attrs, :template),
         {:ok, display_name} <- text(attrs, :display_name),
         {:ok, provider} <- text(attrs, :provider),
         {:ok, _atom} <- provider_atom(provider),
         {:ok, model} <- text(attrs, :model),
         true <- map_size(attrs) == 5 do
      {:ok,
       %{
         operation: :start,
         template: template,
         display_name: display_name,
         provider: provider,
         model: model
       }}
    else
      _ -> invalid()
    end
  end

  def new(%{operation: :resume} = attrs) do
    with {:ok, "agent_" <> rest = agent_id} when rest != "" <- text(attrs, :agent_id),
         true <- map_size(attrs) == 2 do
      {:ok, %{operation: :resume, agent_id: agent_id}}
    else
      _ -> invalid()
    end
  end

  def new(_attrs), do: invalid()

  @doc """
  Exact bytes the operator signs for `request` as `principal_id`.

  Only `human_` principals sign lifecycle requests.
  """
  @spec payload(String.t(), map() | keyword()) ::
          {:ok, binary()} | {:error, :invalid_lifecycle_request}
  def payload("human_" <> rest = principal_id, attrs)
      when rest != "" and byte_size(principal_id) <= @max_field_bytes do
    with {:ok, request} <- new(attrs) do
      {:ok, Enum.map_join([@version, principal_id | fields(request)], &length_prefix/1)}
    end
  end

  def payload(_principal_id, _attrs), do: invalid()

  @doc "The session provider atom for a canonical provider name."
  @spec provider_atom(String.t()) :: {:ok, atom()} | {:error, :unknown_provider}
  def provider_atom(name) when is_binary(name) do
    case Map.fetch(@providers, name) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :unknown_provider}
    end
  end

  def provider_atom(_name), do: {:error, :unknown_provider}

  @doc "Canonical provider names accepted in a start request."
  @spec provider_names() :: [String.t()]
  def provider_names, do: @providers |> Map.keys() |> Enum.sort()

  defp fields(%{operation: :start} = request) do
    [
      "start",
      "arbor://agent/lifecycle/start",
      request.template,
      request.display_name,
      request.provider,
      request.model
    ]
  end

  defp fields(%{operation: :resume, agent_id: agent_id}) do
    ["resume", "arbor://agent/lifecycle/start/" <> agent_id, agent_id]
  end

  defp text(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value}
      when is_binary(value) and byte_size(value) in 1..@max_field_bytes ->
        if String.valid?(value) and not String.contains?(value, <<0>>),
          do: {:ok, value},
          else: invalid()

      _ ->
        invalid()
    end
  end

  defp length_prefix(value), do: <<byte_size(value)::unsigned-big-32, value::binary>>

  defp invalid, do: {:error, :invalid_lifecycle_request}
end
