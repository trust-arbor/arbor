defmodule Arbor.LLM.Adapter.LmStudio do
  @moduledoc """
  Owned `Arbor.LLM.ProviderAdapter` for LM Studio, hitting its OpenAI-compat
  `/v1/chat/completions` endpoint **directly** — so we control the request body and can send the
  full model-card sampling (`top_k`, `min_p`, `repeat_penalty`) that req_llm's OpenAI provider
  rejects (see `.arbor/decisions/2026-07-04-llm-layer-reqllm-plus-owned-adapters.md`).

  Chosen over the native `/api/v1/chat` because that endpoint doesn't support custom tools or
  assistant-messages-in-request, which the agent tool loop needs. This mirrors
  `Arbor.LLM.Adapter.OAuthResponses` (chat-completions shape instead of the Responses API).

  Registered opt-in as provider `"lm_studio_owned"` first; once proven it can become the default
  for `"lm_studio"`. Sampling: `temperature`/`top_p`/`max_tokens` are first-class Request fields;
  `top_k`/`min_p`/`repeat_penalty` ride `request.provider_options` (string keys) into the body.
  """

  @behaviour Arbor.LLM.ProviderAdapter

  alias Arbor.LLM.{Boundary, ContentPart, Deadline, Endpoint, Request, RequestTimeoutError}
  alias Arbor.LLM.{Response, ResponseBudget}

  @provider "lm_studio_owned"
  @max_response_bytes 16_777_216
  # llama.cpp/LM Studio sampling knobs that live top-level in the chat-completions body.
  @extra_sampling_keys ~w(top_k min_p repeat_penalty repetition_penalty presence_penalty frequency_penalty)
  @tool_argument_limits [
    max_bytes: 1_048_576,
    max_nodes: 10_000,
    max_depth: 32,
    max_map_keys: 2_000,
    max_list_items: 10_000
  ]

  @impl true
  def provider, do: @provider

  @impl true
  def complete(request, opts \\ [])

  def complete(%Request{} = request, opts) do
    with {:ok, opts, _timeout} <-
           Deadline.normalize_transport_options(opts, request.receive_timeout),
         {:ok, receipt} <- Deadline.receipt(opts) do
      Deadline.run(
        fn ->
          with {:ok, maximum} <- response_limit(opts),
               {:ok, url} <- chat_url() do
            do_complete(request, opts, url, maximum)
            |> Boundary.completion(opts)
          else
            {:error, {:invalid_response_limit, _maximum}} = error -> error
            {:error, reason} -> {:error, {:invalid_lm_studio_endpoint, reason}}
          end
        end,
        receipt,
        RequestTimeoutError.exception(timeout_ms: receipt.timeout_ms)
      )
    end
  end

  def complete(_request, _opts), do: {:error, :invalid_lm_studio_completion_request}

  defp do_complete(request, opts, url, maximum) do
    body = build_body(request)

    req =
      Req.new(
        url: url,
        method: :post,
        headers: [{"authorization", "Bearer lm-studio"}],
        json: body,
        receive_timeout: Keyword.fetch!(opts, :receive_timeout)
      )
      |> ResponseBudget.apply_req_receipt(maximum)

    case Req.request(req) do
      {:ok, %Req.Response{private: %{arbor_response_overflow: ^maximum}}} ->
        {:error, {:response_bytes_exceeded, maximum}}

      {:ok, %Req.Response{private: %{arbor_response_error: reason}}} ->
        {:error, {:invalid_response_body, reason}}

      {:ok, %{status: 200, body: resp}} when is_map(resp) ->
        {:ok, parse_response(resp)}

      {:ok, %{status: 200, body: resp}} when is_binary(resp) ->
        with {:ok, decoded} <- decode_response(resp, maximum) do
          {:ok, parse_response(decoded)}
        end

      {:ok, %{status: status, body: resp}} ->
        {:error, {:lm_studio_http, status, detail(resp)}}

      {:error, reason} ->
        {:error, {:lm_studio_request_failed, reason}}
    end
  end

  defp decode_response(body, maximum) do
    ResponseBudget.decode_json(body,
      max_bytes: maximum,
      max_nodes: 100_000,
      max_depth: 32,
      max_map_keys: 10_000,
      max_list_items: 100_000
    )
  end

  defp response_limit(opts) do
    case Keyword.get(opts, :max_response_bytes, @max_response_bytes) do
      maximum when is_integer(maximum) and maximum > 0 ->
        {:ok, min(maximum, @max_response_bytes)}

      maximum ->
        {:error, {:invalid_response_limit, maximum}}
    end
  end

  # ── request body ──

  defp build_body(%Request{} = request) do
    base = %{
      "model" => model_id(request.model),
      "messages" => Enum.map(request.messages, &message/1),
      "stream" => false
    }

    base
    |> put_present("temperature", request.temperature)
    |> put_present("top_p", request.top_p)
    |> put_present("max_tokens", request.max_tokens)
    |> put_tools(request.tools)
    |> merge_extra_sampling(request.provider_options)
  end

  defp put_tools(body, tools) when is_list(tools) and tools != [] do
    Map.merge(body, %{"tools" => tools, "tool_choice" => "auto"})
  end

  defp put_tools(body, _), do: body

  # top_k/min_p/repeat_penalty etc. go top-level in the chat-completions body (LM Studio honors them).
  defp merge_extra_sampling(body, %{} = po) do
    extras =
      for {k, v} <- po, to_string(k) in @extra_sampling_keys, not is_nil(v), into: %{} do
        {to_string(k), v}
      end

    Map.merge(body, extras)
  end

  defp merge_extra_sampling(body, _), do: body

  # ── messages: Arbor Message → chat-completions message ──

  defp message(%{role: :tool} = m) do
    %{
      "role" => "tool",
      "tool_call_id" => m.metadata["tool_call_id"] || m.metadata[:tool_call_id],
      "content" => text_of(m.content)
    }
  end

  defp message(%{role: :assistant, content: content}) when is_list(content) do
    tool_calls =
      content
      |> Enum.filter(&(is_map(&1) and Map.get(&1, :kind) == :tool_call))
      |> Enum.map(fn tc ->
        %{
          "id" => tc.id,
          "type" => "function",
          "function" => %{"name" => tc.name, "arguments" => encode_args(tc.arguments)}
        }
      end)

    text = assistant_text(content)

    %{"role" => "assistant"}
    |> put_present("content", if(text == "", do: nil, else: text))
    |> then(fn m -> if tool_calls == [], do: m, else: Map.put(m, "tool_calls", tool_calls) end)
  end

  defp message(%{role: role, content: content}) do
    %{"role" => to_string(role), "content" => content_field(content)}
  end

  # Multimodal user content → OpenAI content-parts (text + image_url); plain string stays a string.
  defp content_field(content) when is_binary(content), do: content

  defp content_field(parts) when is_list(parts) do
    parts |> Enum.map(&content_part/1) |> Enum.reject(&is_nil/1)
  end

  defp content_field(_), do: ""

  defp content_part(%{kind: :text, text: t}) when is_binary(t),
    do: %{"type" => "text", "text" => t}

  defp content_part(t) when is_binary(t), do: %{"type" => "text", "text" => t}

  defp content_part(%{kind: :image, data: data, media_type: mt}) when is_binary(data),
    do: %{
      "type" => "image_url",
      "image_url" => %{"url" => "data:#{mt || "image/png"};base64,#{data}"}
    }

  defp content_part(%{kind: :image, url: url}) when is_binary(url),
    do: %{"type" => "image_url", "image_url" => %{"url" => url}}

  defp content_part(_), do: nil

  # ── response: choices[0].message → %Response{} ──

  defp parse_response(%{"choices" => [%{"message" => msg} = choice | _]}) do
    text = msg["content"] || ""

    tool_call_parts =
      (msg["tool_calls"] || [])
      |> Enum.map(fn tc ->
        fun = tc["function"] || %{}
        ContentPart.tool_call(tc["id"], fun["name"], decode_args(fun["arguments"]))
      end)

    finish =
      case choice["finish_reason"] do
        "tool_calls" -> :tool_calls
        "length" -> :length
        _ -> :stop
      end

    text_parts = if is_binary(text) and text != "", do: [ContentPart.text(text)], else: []

    %Response{
      text: text || "",
      content_parts: tool_call_parts ++ text_parts,
      finish_reason: if(tool_call_parts == [], do: finish, else: :tool_calls),
      usage: usage(choice)
    }
  end

  defp parse_response(_), do: %Response{text: "", finish_reason: :error}

  defp usage(_choice), do: %{}

  # ── helpers ──

  defp chat_url do
    base = Application.get_env(:arbor_llm, :lm_studio_base_url, "http://localhost:1234/v1")

    case Endpoint.validate(base, :lm_studio) do
      {:ok, canonical} -> {:ok, canonical <> "/chat/completions"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp model_id(model) when is_binary(model), do: model |> String.split("/") |> List.last()
  defp model_id(model), do: to_string(model)

  defp encode_args(args) when is_binary(args), do: args
  defp encode_args(args) when is_map(args), do: Jason.encode!(args)
  defp encode_args(_), do: "{}"

  defp decode_args(args) when is_binary(args) do
    case ResponseBudget.decode_json(args, @tool_argument_limits) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  defp decode_args(m) when is_map(m), do: m
  defp decode_args(_), do: %{}

  defp text_of(content) when is_binary(content), do: content
  defp text_of(parts) when is_list(parts), do: parts |> Enum.map_join(" ", &part_text/1)
  defp text_of(_), do: ""

  defp assistant_text(parts) when is_list(parts) do
    parts
    |> Enum.filter(&(is_map(&1) and Map.get(&1, :kind) == :text))
    |> Enum.map_join(" ", & &1.text)
  end

  defp assistant_text(content) when is_binary(content), do: content
  defp assistant_text(_), do: ""

  defp part_text(%{kind: :text, text: t}) when is_binary(t), do: t
  defp part_text(%{text: t}) when is_binary(t), do: t
  defp part_text(t) when is_binary(t), do: t
  defp part_text(_), do: ""

  defp put_present(map, _k, nil), do: map
  defp put_present(map, k, v), do: Map.put(map, k, v)

  defp detail(%{"error" => e}), do: e
  defp detail(body), do: inspect(body) |> String.slice(0, 200)
end
