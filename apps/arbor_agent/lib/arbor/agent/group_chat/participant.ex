defmodule Arbor.Agent.GroupChat.Participant do
  @moduledoc """
  A participant in a group chat (agent or human).

  Participants can be either:
  - **Agents**: Autonomous AI agents with a running APIAgent GenServer (host_pid)
  - **Humans**: Users connected via LiveView (host_pid is nil, messages via PubSub)

  For agents, the host_pid allows direct GenServer communication for message delivery.
  For humans, messages are broadcast via PubSub and received by their LiveView process.
  """

  @type participant_type :: :human | :agent

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          type: participant_type(),
          host_pid: pid() | nil,
          joined_at: DateTime.t()
        }

  @enforce_keys [:id, :name, :type]
  defstruct [
    :id,
    :name,
    :type,
    host_pid: nil,
    joined_at: nil
  ]

  @doc """
  Creates a new participant.

  For agents, use `Lifecycle.get_host(agent_id)` to obtain the host_pid.
  For humans, host_pid should be nil.

  ## Examples

      # Agent participant
      iex> {:ok, host_pid} = Lifecycle.get_host("agent_abc123")
      iex> Participant.new(%{
      ...>   id: "agent_abc123",
      ...>   name: "Claude",
      ...>   type: :agent,
      ...>   host_pid: host_pid
      ...> })
      %Participant{
        id: "agent_abc123",
        name: "Claude",
        type: :agent,
        host_pid: #PID<0.123.0>,
        joined_at: ~U[2026-02-15 12:34:56.789Z]
      }

      # Human participant
      iex> Participant.new(%{
      ...>   id: "user_def456",
      ...>   name: "Hysun",
      ...>   type: :human
      ...> })
      %Participant{
        id: "user_def456",
        name: "Hysun",
        type: :human,
        host_pid: nil,
        joined_at: ~U[2026-02-15 12:34:56.789Z]
      }
  """
  @spec new(map()) :: t()
  def new(attrs) do
    joined_at = DateTime.utc_now()

    attrs
    |> Map.put_new(:joined_at, joined_at)
    |> Map.put_new(:host_pid, nil)
    |> then(&struct!(__MODULE__, &1))
  end

  @doc """
  Returns true if this participant is an agent with a running host process.
  """
  @spec agent_online?(t()) :: boolean()
  def agent_online?(%__MODULE__{type: :agent, host_pid: pid}) when is_pid(pid) do
    Process.alive?(pid)
  end

  def agent_online?(_), do: false

  @doc """
  Returns true if this participant is human.
  """
  @spec human?(t()) :: boolean()
  def human?(%__MODULE__{type: :human}), do: true
  def human?(_), do: false

  @doc """
  Returns true if this participant is an agent.
  """
  @spec agent?(t()) :: boolean()
  def agent?(%__MODULE__{type: :agent}), do: true
  def agent?(_), do: false
end
