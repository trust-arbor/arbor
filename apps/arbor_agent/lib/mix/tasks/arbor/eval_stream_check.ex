defmodule Mix.Tasks.Arbor.Eval.StreamCheck do
  @shortdoc "Compare a model's non-streaming vs streaming response (stream-reassembly check)"

  @moduledoc """
  Diagnostic: calls a model via BOTH the non-streaming path (Arbor.AI.generate_text)
  and the streaming path (Arbor.AI.stream_text, collected) with the same prompt, and
  prints the assembled text length + preview for each. If non-streaming returns text
  but streaming returns empty, the stream reassembly/parse is dropping content (not
  the model). RPCs into the running server.

      mix arbor.eval.stream_check --model qwen-agentworld-35b-a3b
      mix arbor.eval.stream_check --model X --provider lmstudio --prompt "Say hello."
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @switches [model: :string, provider: :string, prompt: :string]

  @impl true
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    model = opts[:model] || "qwen-agentworld-35b-a3b"
    provider = String.to_atom(opts[:provider] || "lmstudio")

    prompt =
      opts[:prompt] ||
        "In exactly one short sentence, state a best practice for API key management."

    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor server not running. Start with: mix arbor.start")
      exit({:shutdown, 1})
    end

    ai_opts = [model: model, provider: provider, temperature: 0.0, max_tokens: 3000]

    Mix.shell().info("Model: #{model}  Provider: #{provider}\nPrompt: #{prompt}\n")

    non_stream = Config.rpc!(Config.full_node_name(), Arbor.AI, :generate_text, [prompt, ai_opts])
    report("NON-STREAMING (generate_text)", non_stream)

    stream =
      Config.rpc!(Config.full_node_name(), Arbor.AI, :stream_text, [
        prompt,
        Keyword.put(ai_opts, :collect, true)
      ])

    report("STREAMING (stream_text, collected)", stream)

    Mix.shell().info("""

    → If NON-STREAMING has text but STREAMING is empty, the stream reassembly is
      dropping content (bug), not the model.
    """)
  end

  defp report(label, result) do
    Mix.shell().info("── #{label} ──")

    case result do
      {:ok, resp} ->
        text = extract_text(resp)
        parts = Map.get(resp, :content_parts) || []

        Mix.shell().info("""
          text length: #{String.length(text || "")}
          finish_reason: #{inspect(Map.get(resp, :finish_reason))}
          content_parts: #{length(parts)} #{inspect(Enum.map(parts, &Map.get(&1, :kind)))}
          text preview: #{String.slice(text || "", 0, 300) |> inspect()}
          reasoning length: #{String.length(Map.get(resp, :reasoning_content) || "")}
          reasoning preview: #{String.slice(Map.get(resp, :reasoning_content) || "", 0, 400) |> inspect()}
        """)

      other ->
        Mix.shell().info("  result: #{inspect(other, limit: 400)}")
    end
  end

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{content: t}) when is_binary(t), do: t
  defp extract_text(_), do: ""
end
