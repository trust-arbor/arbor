defmodule Arbor.LLM.StockToolTransport do
  @moduledoc false
  alias Arbor.LLM.{Client, Config, ProviderRegistry, Request}
  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter

  @pipeline [
    Arbor.LLM.Plugs.ResponseLimit,
    Arbor.LLM.Plugs.EvalReplay,
    Arbor.LLM.Plugs.Dispatch,
    Arbor.LLM.Plugs.RateLimitBackoff,
    Arbor.LLM.Plugs.EvalRecord,
    Arbor.LLM.Plugs.Usage
  ]
  @modules [
             __MODULE__,
             Arbor.LLM,
             Client,
             Config,
             Request,
             ProviderRegistry,
             Adapter,
             Arbor.LLM.ToolLoop,
             Arbor.LLM.Deadline,
             Arbor.LLM.ResponseBudget
           ] ++ @pipeline

  def identity(provider) when is_binary(provider) do
    client = Client.default_client()

    with true <- ProviderRegistry.known?(provider),
         %{middleware: [], stream_middleware: [], model_catalog: :llmdb} <- client,
         {:ok, Adapter} <- Client.adapter_for(client, %Request{provider: provider}),
         :ok <- Adapter.validate_live_completion_pipeline(),
         true <- is_nil(Application.get_env(:arbor_llm, :rate_limit_backoff_dispatch_fn)),
         auditor = Config.tool_invocation_auditor(),
         true <- auditor == Module.concat(["Arbor", "Security"]),
         %{invocation_audit: :required, audit_identity: {:ok, audit}} <-
           apply(auditor, :execution_policy_snapshot, []),
         endpoint when is_binary(endpoint) <- ProviderRegistry.default_base_url(provider),
         {:ok, implementation} <- implementation(),
         {:ok, options_digest} <- options_digest() do
      {:ok,
       %{
         "schema" => "arbor.llm.stock_tool_transport.v1",
         "provider" => ProviderRegistry.normalize(provider),
         "endpoint_digest" => digest(endpoint),
         "local_endpoint" => local_endpoint?(endpoint),
         "auditor" => Atom.to_string(auditor),
         "audit_mode" => "required",
         "audit_identity" => audit,
         "adapter_mapping" =>
           Map.new(client.adapters, fn {key, mod} -> {key, Atom.to_string(mod)} end),
         "runtime_options_digest" => options_digest,
         "pipeline" => Enum.map(@pipeline, &Atom.to_string/1),
         "implementation" => implementation
       }}
    else
      _ -> {:error, :stock_tool_transport_unavailable}
    end
  rescue
    _ -> {:error, :stock_tool_transport_unavailable}
  catch
    _, _ -> {:error, :stock_tool_transport_unavailable}
  end

  def identity(_), do: {:error, :stock_tool_transport_unavailable}

  defp local_endpoint?(endpoint) do
    case URI.parse(endpoint) do
      %URI{
        scheme: "http",
        host: "127.0.0.1",
        path: "/v1",
        userinfo: nil,
        query: nil,
        fragment: nil
      } ->
        true

      _ ->
        false
    end
  end

  defp options_digest do
    options =
      Map.new(@modules, fn module ->
        {Atom.to_string(module), Application.get_env(:arbor_llm, module, [])}
      end)

    # Reject executable/opaque runtime options; identity is not permission to run them.
    if :erlang.external_size(options) <= 65_536 and json_value?(options),
      do: {:ok, digest(:erlang.term_to_binary(options, [:deterministic]))},
      else: {:error, :unsupported_runtime_options}
  end

  defp json_value?(map) when is_map(map) and not is_struct(map),
    do:
      Enum.all?(map, fn {key, value} ->
        (is_binary(key) or is_atom(key)) and json_value?(value)
      end)

  defp json_value?([]), do: true

  defp json_value?([{key, value} | rest]) when is_atom(key),
    do: json_value?(value) and json_value?(rest)

  defp json_value?([value | rest]), do: json_value?(value) and json_value?(rest)
  defp json_value?(value), do: is_binary(value) or is_number(value) or value in [nil, true, false]
  defp digest(value), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)

  defp implementation do
    Enum.reduce_while(@modules, {:ok, []}, fn module, {:ok, acc} ->
      if Code.ensure_loaded?(module) do
        entry = %{
          "module" => Atom.to_string(module),
          "loaded_md5" => Base.encode16(module.module_info(:md5), case: :lower)
        }

        {:cont, {:ok, acc ++ [entry]}}
      else
        {:halt, {:error, :implementation_unavailable}}
      end
    end)
  end
end
