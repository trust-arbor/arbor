defmodule ConversationDemo.MockHost do
  @moduledoc "Local deterministic host. Only this boundary emits authoritative outcomes; it performs no real tools."
  use GenServer
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
  def snapshot(host), do: GenServer.call(host, :snapshot)
  def act(host, action, params \\ %{}), do: GenServer.call(host, {:act, action, params})
  def events(host), do: GenServer.call(host, :events)

  def fixture do
    file =
      case System.get_env("CONVERSATION_FIXTURE", "conversation") do
        "conversation" -> "conversation.json"
        "notice" -> "notice.json"
        other -> raise "Unknown fixture #{inspect(other)}"
      end

    Path.expand("../../../fixtures/v1/" <> file, __DIR__) |> File.read!() |> Jason.decode!()
  end

  def init(opts) do
    if owner = Keyword.get(opts, :owner), do: Process.monitor(owner)
    fixture = Keyword.get_lazy(opts, :fixture, &fixture/0)
    {:ok, model} = ConversationKit.replay(fixture["events"], ConversationKit.new(fixture["id"]))
    {:ok, %{model: model, events: fixture["events"], progress: %{}, queue: [], serial: 0}}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, show(state), state}
  def handle_call(:events, _from, state), do: {:reply, state.events, state}

  def handle_call({:act, action, params}, _from, state) do
    case decide(state, action, params) do
      {:ok, next} -> {:reply, {:ok, show(next)}, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_info({:DOWN, _, :process, _, _}, state), do: {:stop, :normal, state}

  defp show(state),
    do: %{
      projection: ConversationKit.project(state.model),
      progress: state.progress,
      remaining: length(state.queue)
    }

  defp decide(state, "replay", _) do
    {:ok, model} =
      ConversationKit.replay(state.events, ConversationKit.new(show(state).projection["id"]))

    {:ok, %{state | model: model, progress: %{}}}
  end

  defp decide(%{queue: []} = state, "advance", _), do: {:ok, state}

  defp decide(%{queue: [{:progress, id, text} | rest]} = state, "advance", _) do
    {:ok, progress} =
      ConversationKit.progress(state.progress, %{"command_id" => id, "text" => text})

    {:ok, %{state | queue: rest, progress: progress}}
  end

  defp decide(%{queue: [{kind, data} | rest]} = state, "advance", _) do
    next = append(%{state | queue: rest}, kind, data)
    {:ok, if(kind == "settled", do: %{next | progress: %{}}, else: next)}
  end

  defp decide(state, "send", %{"text" => text} = params) do
    with {:ok, _intent} <- ConversationKit.intent(state.model, "send", params) do
      id = "demo-#{state.serial + 1}"

      next =
        state
        |> Map.put(:serial, state.serial + 1)
        |> append("admitted", %{"command_id" => id, "name" => "chat.send"})
        |> append("message", %{
          "message" => %{
            "id" => id <> ".user",
            "role" => "user",
            "text" => text,
            "command_id" => id
          }
        })

      queue = [
        {:progress, id, "I am checking the conversation…"},
        {"tool_started",
         %{
           "id" => id <> ".tool",
           "command_id" => id,
           "name" => "search",
           "text" => "Searching the local fixture"
         }},
        {"approval_requested",
         %{
           "id" => id <> ".approval",
           "command_id" => id,
           "text" => "Allow the mock search to continue?",
           "protected" => true
         }}
      ]

      {:ok, %{next | queue: state.queue ++ queue}}
    end
  end

  defp decide(state, "approve", params) do
    with {:ok, _intent} <- ConversationKit.intent(state.model, "approve", params) do
      approval =
        Enum.find(show(state).projection["approvals"], &(&1["id"] == params["approval_id"]))

      id = approval["command_id"]
      decision = params["decision"]
      next = append(state, "approval_resolved", %{"id" => approval["id"], "decision" => decision})

      if decision == "approved" do
        text =
          "The mock search is complete. This response is shared by the web, terminal, and speech projections."

        tool =
          Enum.find(
            show(state).projection["tools"],
            &(&1["command_id"] == id and &1["status"] == "running")
          )

        queue = [
          {"tool_finished",
           %{"id" => tool["id"], "status" => "completed", "text" => "One local result found"}},
          {"message",
           %{
             "message" => %{
               "id" => id <> ".assistant",
               "role" => "assistant",
               "text" => text,
               "command_id" => id
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

        {:ok, %{next | queue: next.queue ++ queue}}
      else
        tool =
          Enum.find(
            show(state).projection["tools"],
            &(&1["command_id"] == id and &1["status"] == "running")
          )

        next =
          if tool,
            do:
              append(next, "tool_finished", %{
                "id" => tool["id"],
                "status" => "cancelled",
                "text" => "Mock search cancelled after denial"
              }),
            else: next

        {:ok,
         append(next, "settled", %{
           "command_id" => id,
           "outcome" => outcome("failed", "approval_denied", "The mock request was denied.")
         })}
      end
    end
  end

  defp decide(state, "uncertain", _) do
    case Enum.find(show(state).projection["commands"], &(&1["status"] == "pending")) do
      nil ->
        {:error, :no_pending_command}

      command ->
        {:ok,
         append(%{state | queue: [], progress: %{}}, "settled", %{
           "command_id" => command["id"],
           "outcome" =>
             outcome(
               "uncertain",
               "effect_unknown",
               "The mock effect could not be established. It was not repeated."
             )
         })}
    end
  end

  defp decide(_state, _action, _params), do: {:error, :unsupported_action}

  defp outcome(status, code, message),
    do: %{
      "status" => status,
      "output" => nil,
      "error" => %{"code" => code, "message" => message, "retryable" => false}
    }

  defp append(state, kind, data) do
    revision = ConversationKit.project(state.model)["revision"] + 1
    event = %{"id" => "event-#{revision}", "revision" => revision, "kind" => kind, "data" => data}

    case ConversationKit.apply(state.model, event) do
      {:ok, model} -> %{state | model: model, events: state.events ++ [event]}
      {:error, reason} -> raise "Mock host invalid event #{kind}: #{inspect(reason)}"
    end
  end
end
