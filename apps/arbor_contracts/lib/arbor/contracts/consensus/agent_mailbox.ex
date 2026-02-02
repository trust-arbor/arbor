defmodule Arbor.Contracts.Consensus.AgentMailbox do
  @moduledoc """
  Bounded priority mailbox for evaluator agents.

  Provides a FIFO queue with priority support:
  - `:high` priority items are dequeued before `:normal` priority
  - Within each priority class, items are dequeued in FIFO order
  - Rejects new items when capacity is reached

  ## Capacity Model

  The mailbox has two capacity parameters:
  - `max_size` — total maximum items in the mailbox
  - `reserved_high_priority` — slots reserved for high-priority items

  When the mailbox has `max_size - reserved_high_priority` or more items,
  normal priority items are rejected. High priority items can use the
  reserved slots until `max_size` is reached.

  ## Example

      {:ok, mailbox} = AgentMailbox.new(max_size: 100, reserved_high_priority: 10)

      # Enqueue items
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, envelope, :normal)
      {:ok, mailbox} = AgentMailbox.enqueue(mailbox, gov_envelope, :high)

      # Dequeue (high priority first)
      {:ok, envelope, mailbox} = AgentMailbox.dequeue(mailbox)
  """

  use TypedStruct

  @type priority :: :high | :normal
  @type envelope :: map()

  typedstruct do
    @typedoc "A bounded priority mailbox"

    field :high_queue, :queue.queue(envelope()), default: :queue.new()
    field :normal_queue, :queue.queue(envelope()), default: :queue.new()
    field :max_size, pos_integer(), default: 100
    field :reserved_high_priority, non_neg_integer(), default: 10
    field :high_count, non_neg_integer(), default: 0
    field :normal_count, non_neg_integer(), default: 0
  end

  @doc """
  Create a new mailbox with specified capacity.

  ## Options

  - `:max_size` — maximum total items (default: 100)
  - `:reserved_high_priority` — slots reserved for high priority (default: 10)
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) do
    max_size = Keyword.get(opts, :max_size, 100)
    reserved = Keyword.get(opts, :reserved_high_priority, 10)

    cond do
      max_size < 1 ->
        {:error, :invalid_max_size}

      reserved < 0 ->
        {:error, :invalid_reserved}

      reserved > max_size ->
        {:error, :reserved_exceeds_max}

      true ->
        {:ok,
         %__MODULE__{
           max_size: max_size,
           reserved_high_priority: reserved
         }}
    end
  end

  @doc """
  Enqueue an envelope with the given priority.

  Returns `{:error, :mailbox_full}` if capacity is exceeded.
  """
  @spec enqueue(t(), envelope(), priority()) :: {:ok, t()} | {:error, :mailbox_full}
  def enqueue(%__MODULE__{} = mailbox, envelope, priority \\ :normal) do
    total = mailbox.high_count + mailbox.normal_count

    case priority do
      :high ->
        if total >= mailbox.max_size do
          {:error, :mailbox_full}
        else
          new_queue = :queue.in(envelope, mailbox.high_queue)
          {:ok, %{mailbox | high_queue: new_queue, high_count: mailbox.high_count + 1}}
        end

      :normal ->
        # Normal items can't use reserved slots
        effective_max = mailbox.max_size - mailbox.reserved_high_priority

        if total >= effective_max do
          {:error, :mailbox_full}
        else
          new_queue = :queue.in(envelope, mailbox.normal_queue)
          {:ok, %{mailbox | normal_queue: new_queue, normal_count: mailbox.normal_count + 1}}
        end
    end
  end

  @doc """
  Dequeue the next envelope (high priority first).

  Returns `{:empty, mailbox}` if the mailbox is empty.
  """
  @spec dequeue(t()) :: {:ok, envelope(), t()} | {:empty, t()}
  def dequeue(%__MODULE__{high_count: 0, normal_count: 0} = mailbox) do
    {:empty, mailbox}
  end

  def dequeue(%__MODULE__{high_count: high_count} = mailbox) when high_count > 0 do
    {{:value, envelope}, new_queue} = :queue.out(mailbox.high_queue)
    {:ok, envelope, %{mailbox | high_queue: new_queue, high_count: high_count - 1}}
  end

  def dequeue(%__MODULE__{normal_count: normal_count} = mailbox) when normal_count > 0 do
    {{:value, envelope}, new_queue} = :queue.out(mailbox.normal_queue)
    {:ok, envelope, %{mailbox | normal_queue: new_queue, normal_count: normal_count - 1}}
  end

  @doc """
  Peek at the next envelope without removing it.
  """
  @spec peek(t()) :: {:ok, envelope()} | :empty
  def peek(%__MODULE__{high_count: 0, normal_count: 0}), do: :empty

  def peek(%__MODULE__{high_count: high_count, high_queue: queue}) when high_count > 0 do
    {:value, envelope} = :queue.peek(queue)
    {:ok, envelope}
  end

  def peek(%__MODULE__{normal_queue: queue}) do
    {:value, envelope} = :queue.peek(queue)
    {:ok, envelope}
  end

  @doc """
  Get the current size of the mailbox.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{high_count: high, normal_count: normal}), do: high + normal

  @doc """
  Check if the mailbox is empty.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{high_count: 0, normal_count: 0}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc """
  Check if the mailbox is full for a given priority.
  """
  @spec full?(t(), priority()) :: boolean()
  def full?(%__MODULE__{} = mailbox, :high) do
    mailbox.high_count + mailbox.normal_count >= mailbox.max_size
  end

  def full?(%__MODULE__{} = mailbox, :normal) do
    total = mailbox.high_count + mailbox.normal_count
    effective_max = mailbox.max_size - mailbox.reserved_high_priority
    total >= effective_max
  end

  @doc """
  Get capacity information for observability.
  """
  @spec capacity_info(t()) :: map()
  def capacity_info(%__MODULE__{} = mailbox) do
    total = mailbox.high_count + mailbox.normal_count
    effective_normal_max = mailbox.max_size - mailbox.reserved_high_priority

    %{
      size: total,
      max_size: mailbox.max_size,
      high_count: mailbox.high_count,
      normal_count: mailbox.normal_count,
      reserved_high_priority: mailbox.reserved_high_priority,
      normal_slots_remaining: max(0, effective_normal_max - total),
      high_slots_remaining: mailbox.max_size - total,
      utilization: total / mailbox.max_size
    }
  end
end
