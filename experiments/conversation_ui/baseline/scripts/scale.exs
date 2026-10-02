# Execute in the isolated baseline demo using ../.. /bin/mix run --no-compile.
# One observation per lane; these measurements are not an agent-productivity score.
defmodule ConversationComparison.ScaleBreezeView do
  use Breeze.View
  def mount(opts, term), do: {:ok, assign(term, ui: Keyword.fetch!(opts, :ui))}
  def render(assigns), do: ConversationDemo.ArborBreezeView.render(assigns)
end

defmodule ConversationComparison.Scale do
  alias ConversationDemo.{ArborChatLive, HistoryWindow}
  require Phoenix.LiveViewTest

  def ui(count, full) do
    messages =
      for n <- 1..count do
        %{
          "id" => "message-#{n}",
          "role" => if(rem(n, 2) == 0, do: "assistant", else: "user"),
          "text" => "Record #{n}: café 東京 🌿",
          "timestamp" => "2026-10-01T00:00:00Z",
          "ordinal" => n
        }
      end

    blocks = Enum.map(messages, &Map.put(&1, "type", "message"))
    projection = %{"messages" => messages, "deliveries" => [], "blocks" => blocks, "speech" => []}

    snapshot = %{
      projection: projection,
      connected: true,
      error: nil,
      private_cleared: false,
      pending_id: nil,
      send_allowed: true,
      retry_allowed: false,
      position: %{history: count, commands: 0},
      sync_status: %{
        history: %{has_more: false, head: count},
        commands: %{has_more: false, head: 0}
      }
    }

    %{
      snapshot: snapshot,
      draft: "",
      composer_ack: nil,
      question: nil,
      window: %{HistoryWindow.new() | full: full}
    }
  end

  def run do
    results =
      for count <- [100, 1_000, 10_000],
          full <- [false, true],
          renderer <- [:live_view, :breeze] do
        ui = ui(count, full)
        shown = HistoryWindow.show(ui.window, ui.snapshot)
        {duration, outcome} = :timer.tc(fn -> render(renderer, ui) end)

        Map.merge(
          %{
            renderer: renderer,
            mode: if(full, do: "full", else: "window"),
            retained_messages: count,
            rendered_message_blocks: length(shown.blocks),
            wall_microseconds: duration
          },
          outcome
        )
      end

    %{
      schema: "conversation-ui-scale/v1",
      samples_per_lane: 1,
      terminal_size: [110, 55],
      default_window_messages: 20,
      delivery_blocks: 0,
      results: results
    }
  end

  defp render(:live_view, ui) do
    html = Phoenix.LiveViewTest.render_component(&ArborChatLive.render/1, ui: ui)
    %{status: "passed", output_bytes: byte_size(html)}
  rescue
    _ -> %{status: "render_failed"}
  catch
    :exit, _ -> %{status: "render_failed"}
  end

  defp render(:breeze, ui) do
    terminal =
      Breeze.Test.start!(ConversationComparison.ScaleBreezeView,
        size: {110, 55},
        start_opts: [ui: ui]
      )

    try do
      rendered = Breeze.Test.render_text!(terminal)
      %{status: "passed", output_bytes: byte_size(rendered)}
    rescue
      _ -> %{status: "render_failed"}
    catch
      :exit, {:timeout, _} -> %{status: "public_test_api_timeout_5000ms"}
      :exit, _ -> %{status: "render_failed"}
    after
      # A public render timeout leaves the child busy. This test-owned process
      # has no host binding, media, or durable effects and must not outlive a lane.
      if Process.alive?(terminal.pid), do: Process.exit(terminal.pid, :kill)
    end
  end
end

IO.puts(Jason.encode!(ConversationComparison.Scale.run()))
