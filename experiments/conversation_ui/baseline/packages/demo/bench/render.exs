defmodule ConversationDemo.BenchmarkBreeze do
  use Breeze.View
  def mount(opts, term), do: {:ok, assign(term, ui: Keyword.fetch!(opts, :ui))}
  def render(assigns), do: ConversationDemo.BreezeView.render(assigns)
end

defmodule ConversationDemo.RenderBenchmark do
  alias ConversationDemo.{ChatLive, TermUIView}

  def run do
    File.mkdir_p!("evidence")
    results = Enum.map([100, 1_000, 10_000], &measure/1)

    report = %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      elixir: System.version(),
      otp: :erlang.system_info(:otp_release) |> to_string(),
      dataset:
        "N transcript messages, N/2 completed commands, 2N valid events; replay setup outside renderer timings",
      viewport: %{width: 90, height: 36},
      samples: 3,
      scope:
        "Elixir process wall time. LiveView HEEx-to-HTML serialization, Breeze terminal layout+ANSI, TermUI tree+cell buffer. Excludes browser JS, DOM/layout/paint, network, PTY writing, and host work.",
      results: results
    }

    File.write!("evidence/render-benchmark.json", Jason.encode!(report, pretty: true) <> "\n")
  end

  defp measure(count) do
    IO.puts("Preparing #{count} transcript messages")

    {setup_us, {:ok, state}} =
      :timer.tc(fn -> ConversationKit.replay(events(count), ConversationKit.new("bench")) end)

    projection = ConversationKit.project(state)

    ui = %{
      snapshot: %{projection: projection, progress: %{}, remaining: 0},
      draft: "",
      error: nil,
      connected: true,
      host: nil,
      width: 90,
      height: 36,
      scroll: 0
    }

    projection_time = sample(fn -> ConversationKit.project(state) end)

    liveview_time =
      sample(fn ->
        ChatLive.render(%{ui: ui, __changed__: nil})
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()
      end)

    session =
      Breeze.Test.start!(ConversationDemo.BenchmarkBreeze, size: {90, 36}, start_opts: [ui: ui])

    breeze_time =
      try do
        sample(fn -> Breeze.Test.render!(session) end)
      catch
        :exit, {:timeout, _call} ->
          %{
            status: "timeout",
            deadline_ms: 5_000,
            note:
              "Breeze.Test public API's fixed call deadline; total render duration was not established"
          }
      after
        Breeze.Test.stop(session)
      end

    {:ok, buffer} =
      TermUI.Renderer.BufferManager.start_link(
        name: ConversationDemo.BenchBuffer,
        rows: 36,
        cols: 90
      )

    termui_time =
      try do
        sample(fn ->
          TermUI.Renderer.BufferManager.clear_current(buffer)
          TermUI.Runtime.NodeRenderer.render_to_buffer(TermUIView.view(ui), buffer)
        end)
      after
        GenServer.stop(buffer)
      end

    result = %{
      messages: count,
      events: count * 2,
      setup_replay_us: setup_us,
      project: projection_time,
      liveview_html: liveview_time,
      breeze_ansi: breeze_time,
      termui_cells: termui_time
    }

    IO.puts(Jason.encode!(result))
    result
  end

  defp sample(fun) do
    {cold, output} = :timer.tc(fun)

    samples =
      for _ <- 1..3 do
        :erlang.garbage_collect()
        {microseconds, _} = :timer.tc(fun)
        microseconds
      end

    %{
      first_us: cold,
      warm_samples_us: samples,
      median_us: samples |> Enum.sort() |> Enum.at(1),
      output_bytes: if(is_binary(output), do: byte_size(output), else: nil)
    }
  end

  defp events(count) do
    Enum.flat_map(1..div(count, 2), fn number ->
      id = "bench-#{number}"
      user = "Compare the interface choices #{number}: café 東京 🌿."
      text = "Shared conversation #{number}; native layout, independent draft, durable result."

      [
        {"admitted", %{"command_id" => id, "name" => "chat.send"}},
        {"message",
         %{
           "message" => %{
             "id" => id <> ".user",
             "command_id" => id,
             "role" => "user",
             "text" => user
           }
         }},
        {"message",
         %{
           "message" => %{
             "id" => id <> ".assistant",
             "command_id" => id,
             "role" => "assistant",
             "text" => text
           }
         }},
        {"settled",
         %{
           "command_id" => id,
           "outcome" => %{
             "status" => "completed",
             "output" => %{"message_id" => id <> ".assistant", "text" => text},
             "error" => nil
           }
         }}
      ]
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{kind, data}, revision} ->
      %{"id" => "event-#{revision}", "revision" => revision, "kind" => kind, "data" => data}
    end)
  end
end

ConversationDemo.RenderBenchmark.run()
