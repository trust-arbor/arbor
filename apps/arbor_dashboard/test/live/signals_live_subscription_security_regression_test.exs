defmodule Arbor.Dashboard.Live.SignalsLiveSubscriptionSecurityRegressionTest do
  use Arbor.Dashboard.ConnCase, async: false

  alias Arbor.Signals

  @moduletag :fast
  @moduletag :integration

  setup do
    previous = Application.get_env(:arbor_kernel, :signals, [])

    Application.put_env(
      :arbor_kernel,
      :signals,
      Keyword.put(previous, :restricted_topics, [:security, :identity])
    )

    on_exit(fn -> Application.put_env(:arbor_kernel, :signals, previous) end)

    # Test config leaves Signals' application supervisor empty. Start the real
    # bus and store under this test's supervisor; no fake handle_info delivery.
    for module <- [Arbor.Signals.Store, Arbor.Signals.Bus] do
      if Process.whereis(module) == nil, do: start_supervised!(module)
    end

    assert Signals.healthy?()
    :ok
  end

  for {category, type} <- [
        action: :started,
        checkpoint: :saved,
        trust: :confirmation_recorded,
        comms: :message_sent,
        skill: :untrusted_activated
      ] do
    test "live subscription delivers #{category}.#{type} after mount", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/signals")
      signal = emit!(unquote(category), unquote(type))

      eventually(fn ->
        assert has_element?(
                 view,
                 "#signals-#{signal.id}",
                 "#{unquote(category)}.#{unquote(type)}"
               )
      end)
    end
  end

  test "categories without a dedicated icon retain the safe fallback", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/signals")
    signal = emit!(:checkpoint, :saved)

    eventually(fn -> assert has_element?(view, "#signals-#{signal.id}", "📦") end)
  end

  test "message failure has an explicit attention consumer while the feed is paused and filtered",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/signals")
    sent = emit!(:comms, :message_sent)
    eventually(fn -> assert has_element?(view, "#signals-#{sent.id}") end)
    refute has_element?(view, "#signals-attention #attention-#{sent.id}")

    render_click(view, "toggle-pause")
    render_click(view, "filter-select-none")
    failed = emit!(:comms, :message_failed, %{channel: :test, reason: "delivery fixture failed"})

    eventually(fn ->
      assert has_element?(
               view,
               "#signals-attention #attention-#{failed.id}",
               "comms.message_failed"
             )
    end)

    refute has_element?(view, "#signals-#{failed.id}")
    render_click(view, "select-signal", %{"id" => failed.id})
    assert has_element?(view, "#signal-detail", "delivery fixture failed")
  end

  test "security regression: restricted categories stay excluded from mount, filters and details",
       %{conn: conn} do
    settings = Application.get_env(:arbor_kernel, :signals)

    Application.put_env(
      :arbor_kernel,
      :signals,
      Keyword.put(settings, :restricted_topics, [:security, :identity, :skill])
    )

    hidden = Enum.map([:security, :identity, :skill], &emit!(&1, :restricted_fixture))
    {:ok, view, _html} = live(conn, "/signals")

    for signal <- hidden do
      refute has_element?(view, "#signals-#{signal.id}")
      render_click(view, "toggle-category", %{"category" => Atom.to_string(signal.category)})
      refute has_element?(view, "#signals-#{signal.id}")
      render_click(view, "select-signal", %{"id" => signal.id})
      refute has_element?(view, "#signal-detail")
    end

    render_click(view, "toggle-category", %{"category" => "unknown_category_not_an_atom"})
    render_click(view, "filter-select-all")
    render_click(view, "toggle-filter-dropdown")

    for category <- [:security, :identity, :skill] do
      refute has_element?(view, "[phx-value-category='#{category}']")
      assert {:error, :unauthorized} = Signals.subscribe("#{category}.*", fn _ -> :ok end)
    end

    visible = emit!(:agent, :started)
    eventually(fn -> assert has_element?(view, "#signals-#{visible.id}") end)

    for signal <- hidden, do: refute(has_element?(view, "#signals-#{signal.id}"))
  end

  defp emit!(category, type, data \\ %{}) do
    correlation = "signals_live_#{System.unique_integer([:positive, :monotonic])}"

    assert :ok =
             Signals.emit(category, type, data,
               correlation_id: correlation,
               scope: :local,
               async: false
             )

    assert {:ok, [signal]} = Signals.query(correlation_id: correlation)
    signal
  end

  defp eventually(assertion, attempts \\ 100)
  defp eventually(assertion, 0), do: assertion.()

  defp eventually(assertion, attempts) do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      eventually(assertion, attempts - 1)
  end
end
