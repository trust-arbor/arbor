defmodule ConversationDemo.Interaction do
  @moduledoc "Renderer boundary: local drafts/connectivity, host calls, and semantic projection."
  alias ConversationDemo.MockHost

  def new(opts \\ []) do
    host =
      Keyword.get_lazy(opts, :host, fn ->
        {:ok, pid} = MockHost.start_link(owner: self())
        pid
      end)

    %{
      host: host,
      snapshot: MockHost.snapshot(host),
      draft: "",
      connected: true,
      error: nil,
      width: 80,
      height: 24
    }
  end

  def act(ui, "draft", %{"text" => text}), do: %{ui | draft: text}
  def act(ui, "disconnect", _), do: %{ui | connected: false}

  def act(ui, "replay", _) do
    case MockHost.act(ui.host, "replay") do
      {:ok, snapshot} -> %{ui | snapshot: snapshot, connected: true, error: nil}
      {:error, error} -> %{ui | error: inspect(error)}
    end
  end

  def act(ui, action, params) do
    params =
      case action do
        "send" -> %{"text" => Map.get(params, "text", ui.draft)}
        "approve" -> Map.take(params, ["approval_id", "decision"])
        _ -> params
      end

    case MockHost.act(ui.host, action, params) do
      {:ok, snapshot} ->
        %{
          ui
          | snapshot: if(ui.connected, do: snapshot, else: ui.snapshot),
            draft: if(action == "send", do: "", else: ui.draft),
            error: nil
        }

      {:error, error} ->
        %{ui | error: inspect(error)}
    end
  end

  def key(ui, "Enter"), do: act(ui, "send", %{})
  def key(ui, "F2"), do: act(ui, "advance", %{})
  def key(ui, "F3"), do: act(ui, "replay", %{})
  def key(ui, "F4"), do: act(ui, "disconnect", %{})
  def key(ui, "F5"), do: approval(ui, "approved")
  def key(ui, "F6"), do: approval(ui, "denied")
  def key(ui, "F7"), do: act(ui, "uncertain", %{})

  def key(ui, "Backspace"),
    do: %{ui | draft: ui.draft |> String.graphemes() |> Enum.drop(-1) |> Enum.join()}

  def key(ui, key) when is_binary(key),
    do: if(String.length(key) == 1, do: %{ui | draft: ui.draft <> key}, else: ui)

  def key(ui, _), do: ui

  defp approval(ui, decision) do
    case Enum.find(ui.snapshot.projection["approvals"], &(&1["status"] == "pending")) do
      nil -> %{ui | error: "No pending approval"}
      approval -> act(ui, "approve", %{"approval_id" => approval["id"], "decision" => decision})
    end
  end
end
