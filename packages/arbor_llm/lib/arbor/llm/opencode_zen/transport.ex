defmodule Arbor.LLM.OpenCodeZen.Transport do
  @moduledoc false

  # Do not spoof User-Agent as `opencode/latest`. The OpenCode Zen relay
  # is User-Agent gated: it returns 429 FreeUsageLimitError unless the UA
  # is `opencode/latest`. Hermes delisted big-pickle and mimo-v2.5-free
  # for this reason. Spoofing a UA to obtain free compute is exactly the
  # behavior Arbor's trust model exists to prevent an agent from learning.
  # Arbor sends honest attribution and accepts the smaller admitted list.

  @user_agent "Arbor/0.1 (+https://github.com/trust-arbor/arbor)"
  @referer "https://github.com/trust-arbor/arbor"
  @title "Arbor"

  # ReqLLM's OpenAI-compatible provider refuses to dispatch without an
  # `:api_key`. The OpenCode Zen relay 401s ANY bearer — including their
  # own placeholder and paid OpenCode Go keys — so this value is stripped
  # from the Authorization header in `apply_anonymous_auth/1` before the
  # request hits the wire. It must never appear in the outgoing request.
  @req_llm_placeholder "arbor-keyless-not-a-credential"

  @spec user_agent() :: String.t()
  def user_agent, do: @user_agent

  @spec referer() :: String.t()
  def referer, do: @referer

  @spec title() :: String.t()
  def title, do: @title

  @spec req_llm_placeholder() :: String.t()
  def req_llm_placeholder, do: @req_llm_placeholder

  @spec attribution_headers() :: [{String.t(), String.t()}]
  def attribution_headers do
    [
      {"authorization", ""},
      {"user-agent", @user_agent},
      {"http-referer", @referer},
      {"x-title", @title}
    ]
  end

  @spec req_http_options() :: keyword()
  def req_http_options do
    [headers: attribution_headers()]
  end

  @base_url "https://opencode.ai/zen/v1"

  # Free-tier slugs carry a `-free` suffix. This mirrors hermes-agent's
  # `is_opencode_zen_free_model/1`, which is where the convention was learned.
  # `big-pickle` is OpenCode's rotating unsuffixed free slot — kept here so the
  # relay's own naming, not a hardcoded list, decides what a candidate IS.
  # Whether a candidate is ADMITTED is decided by the eval, never by this list.
  @unsuffixed_free_slugs ~w(big-pickle)

  @spec base_url() :: String.t()
  def base_url, do: @base_url

  @spec free_slug?(String.t()) :: boolean()
  def free_slug?(id) when is_binary(id) do
    bare = id |> String.trim() |> String.split("/") |> List.last() |> String.downcase()
    String.ends_with?(bare, "-free") or bare in @unsuffixed_free_slugs
  end

  def free_slug?(_id), do: false

  @doc """
  Discover free-tier candidate ids from the relay's own catalog.

  The probe MUST NOT source candidates from the local admission file — that is
  the artifact it produces, so reading it makes discovery circular and can only
  ever re-probe whatever is already recorded (which is how a fabricated catalog
  survived: nothing could introduce a model it did not already contain).
  """
  @spec discover_free_candidates(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def discover_free_candidates(opts \\ []) do
    timeout = Keyword.get(opts, :receive_timeout, 15_000)

    case Req.get(@base_url <> "/models",
           headers: attribution_headers(),
           receive_timeout: timeout,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, extract_free_ids(body)}
      {:ok, %{status: status}} -> {:error, {:opencode_zen_models_http_error, status}}
      {:error, reason} -> {:error, {:opencode_zen_models_unreachable, reason}}
    end
  end

  defp extract_free_ids(%{"data" => data}) when is_list(data) do
    data
    |> Enum.map(fn
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&free_slug?/1)
    |> Enum.sort()
  end

  defp extract_free_ids(_body), do: []

  @doc """
  Force anonymous auth on a prepared Req request.

  Deletes any Authorization value (Bearer from ReqLLM, leftover env keys,
  the internal placeholder) and writes an empty Authorization header so
  no credential reaches the wire.
  """
  @spec apply_anonymous_auth(term()) :: term()
  def apply_anonymous_auth(%Req.Request{} = request) do
    request
    |> Req.Request.delete_header("authorization")
    # `auth: nil` — NOT `false`. Req.Steps.auth/2 has clauses for nil, a
    # binary, {:basic,_}, {:bearer,_}, {:digest,_}, a fun, {m,f,a} and
    # :netrc. `false` matches none of them and raises FunctionClauseError
    # before the request is ever sent, so every keyless dispatch failed.
    # nil makes the auth step a no-op and the empty Authorization header
    # written below is what reaches the wire.
    |> Req.Request.merge_options(auth: nil)
    |> Req.Request.put_header("authorization", "")
    |> Req.Request.put_header("user-agent", @user_agent)
    |> Req.Request.put_header("http-referer", @referer)
    |> Req.Request.put_header("x-title", @title)
  end

  # Streaming takes a DIFFERENT shape. `provider.attach_stream/4` returns a
  # `%Finch.Request{}`, not a `%Req.Request{}`, carrying `@req_llm_placeholder`
  # as a real Authorization header in its `headers` list.
  #
  # The relay 401s ANY bearer, including that sentinel, so a streaming turn
  # failed with {:stream_http_error, 401} while the identical non-streaming call
  # succeeded. Before this clause the Finch request fell through the catch-all
  # below and shipped the placeholder to the wire — the exact thing the comment
  # on @req_llm_placeholder says must never happen.
  #
  # Finch headers are a plain list of {name, value}; there is no options map and
  # no auth step to neutralise, so rewrite the list directly.
  def apply_anonymous_auth(%Finch.Request{headers: headers} = request)
      when is_list(headers) do
    kept =
      Enum.reject(headers, fn {name, _v} ->
        String.downcase(to_string(name)) in [
          "authorization",
          "user-agent",
          "http-referer",
          "x-title"
        ]
      end)

    %{request | headers: kept ++ attribution_headers()}
  end

  def apply_anonymous_auth(request), do: request

  @doc "True when `opts` mark this dispatch as the keyless provider."
  @spec anonymous?(keyword()) :: boolean()
  def anonymous?(opts) when is_list(opts), do: Keyword.get(opts, :arbor_anonymous_auth) == true
  def anonymous?(_), do: false
end
