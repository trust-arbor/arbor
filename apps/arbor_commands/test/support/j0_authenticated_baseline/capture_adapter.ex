defmodule Arbor.Commands.J0AuthenticatedBaseline.CaptureAdapter do
  @moduledoc false

  @behaviour Arbor.LLM.ProviderAdapter

  alias Arbor.Commands.J0AuthenticatedBaseline, as: Journey
  alias Arbor.LLM.{ContentPart, Request, Response}

  @parent_key {__MODULE__, :parent}

  def set_parent(pid) when is_pid(pid), do: :persistent_term.put(@parent_key, pid)
  def clear_parent, do: :persistent_term.erase(@parent_key)

  @impl true
  def provider, do: "ollama"

  @impl true
  def complete(%Request{} = request, _opts) do
    notify({:j0_provider_request, request})

    text = public_reply(request)

    {:ok,
     %Response{
       text: text,
       finish_reason: :stop,
       content_parts: [ContentPart.text(text)],
       usage: %{input_tokens: 1, output_tokens: 1},
       raw: %{hermetic: true, adapter: inspect(__MODULE__)}
     }}
  end

  @impl true
  def complete_single_attempt(request, opts), do: complete(request, opts)

  @impl true
  def stream(_request, _opts), do: {:error, :not_supported}

  @impl true
  def embed(_texts, _model, _opts), do: {:error, :not_supported}

  @impl true
  def runtime_contract, do: %Arbor.Contracts.AI.RuntimeContract{}

  defp public_reply(request) do
    newest = Journey.newest_user_content(request)

    cond do
      String.contains?(newest, Journey.preference_marker()) ->
        Journey.preference_reply()

      String.contains?(newest, Journey.follow_up()) ->
        Journey.follow_up_reply()

      true ->
        "Hermetic conversationalist reply."
    end
  end

  defp notify(message) do
    case :persistent_term.get(@parent_key, nil) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end
end
