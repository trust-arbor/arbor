defmodule Mix.Tasks.Arbor.VisionSmoke do
  @shortdoc "Smoke-test whether Arbor's LLM adapter carries an image to a vision model"

  @moduledoc """
  Sends a base64 image (with known text) + a "what text is in this image?" prompt to a
  vision model through Arbor's normal LLM path, and prints the reply. If the model reads
  the text back, the adapter carries images today; if not, the media-transport gap is
  confirmed (see .arbor/roadmap/0-inbox/multimodal-eval-media-plumbing.md).

      mix arbor.vision_smoke --image /path/to.b64 --model openai/gpt-chat-latest
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @switches [model: :string, provider: :string, image: :string]

  @impl true
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("server not running")
      exit({:shutdown, 1})
    end

    b64 = opts[:image] |> File.read!() |> String.trim()
    model = opts[:model] || "openai/gpt-chat-latest"
    # Client.resolve_adapter keys its adapter map by STRING provider names.
    provider = opts[:provider] || "openrouter"

    parts = [
      Arbor.LLM.ContentPart.text(
        "What exact text appears in this image? Reply with only the text you see."
      ),
      Arbor.LLM.ContentPart.image_base64(b64, "image/png")
    ]

    message = %Arbor.LLM.Message{role: :user, content: parts}
    gen_opts = [provider: provider, model: model, messages: [message], max_tokens: 60]

    Mix.shell().info("Sending image (#{byte_size(b64)}b64) to #{model} via #{provider}...\n")

    case Config.rpc!(Config.full_node_name(), Arbor.LLM, :generate, [gen_opts]) do
      {:ok, resp} ->
        text = Map.get(resp, :content) || Map.get(resp, :text) || inspect(resp)
        Mix.shell().info("REPLY: #{inspect(text)}")

      other ->
        Mix.shell().info("RESULT: #{inspect(other)}")
    end
  end
end
