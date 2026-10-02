defmodule Arbor.Voice.ClosureReceipt do
  @moduledoc false

  # Private, per-Desk evidence. These reference-counted cells outlive all three
  # producers. No process absence, timeout, or public caller can complete them.
  @enforce_keys [:closed, :facts, :stage, :writer, :session]
  defstruct @enforce_keys

  @session_done 1
  @backend_closed 2
  @lease_done 3
  @custody_pending 4

  def new(closed) do
    facts = :atomics.new(4, signed: false)
    :atomics.put(facts, @custody_pending, 1)
    %__MODULE__{closed: closed, facts: facts, stage: :session, writer: self(), session: self()}
  end

  def valid?(nil, _stage, _writer), do: true

  def valid?(
        %__MODULE__{stage: stage, writer: writer, facts: facts, closed: closed},
        stage,
        writer
      ) do
    :atomics.info(facts).size == 4 and :atomics.info(closed).size == 1
  rescue
    _ -> false
  end

  def valid?(_, _, _), do: false

  def for_owner(nil, _session), do: nil

  def for_owner(%__MODULE__{} = receipt, session) do
    if valid?(receipt, :session, session),
      do: %{receipt | stage: :owner, writer: self()},
      else: nil
  end

  def for_lease(nil, _owner), do: nil

  def for_lease(%__MODULE__{} = receipt, owner) do
    if valid?(receipt, :owner, owner),
      do: %{receipt | stage: :lease, writer: self()},
      else: nil
  end

  def begin_provisional(nil), do: :ok

  def begin_provisional(%__MODULE__{stage: :session, writer: writer} = receipt)
      when writer == self() do
    if :atomics.get(receipt.facts, @session_done) == 0 and
         :atomics.compare_exchange(receipt.facts, @custody_pending, 0, 1) == :ok,
       do: :ok,
       else: {:error, :custody_pending}
  end

  def begin_provisional(_), do: {:error, :foreign_writer}

  # Owner uses this once, after accepting the complete initial handoff and
  # before startup can return. Session uses it after exact transfer/revocation.
  def custody_owned(nil), do: :ok

  def custody_owned(%__MODULE__{stage: stage, writer: writer} = receipt)
      when stage in [:session, :owner] and writer == self() do
    :atomics.put(receipt.facts, @custody_pending, 0)
    :ok
  end

  def custody_owned(_), do: {:error, :foreign_writer}

  def session_closing(nil), do: :ok

  def session_closing(%__MODULE__{stage: :session, writer: writer} = receipt)
      when writer == self(),
      do: complete_session(receipt)

  def session_closing(_), do: {:error, :foreign_writer}

  # Called only from ResourceOwner's exact Session monitor DOWN handler.
  def session_down(nil, _session), do: :ok

  def session_down(
        %__MODULE__{stage: :owner, writer: writer, session: session} = receipt,
        session
      )
      when writer == self() do
    if Process.alive?(session), do: {:error, :session_alive}, else: complete_session(receipt)
  end

  def session_down(_, _), do: {:error, :foreign_writer}

  def backend_closed(nil), do: :ok

  def backend_closed(%__MODULE__{stage: :owner, writer: writer} = receipt)
      when writer == self(),
      do: complete(receipt, @backend_closed)

  def backend_closed(_), do: {:error, :foreign_writer}

  def lease_drained(nil), do: :ok

  def lease_drained(%__MODULE__{stage: :lease, writer: writer} = receipt)
      when writer == self(),
      do: complete(receipt, @lease_done)

  def lease_drained(_), do: {:error, :foreign_writer}

  def closed?(nil), do: false
  def closed?(%__MODULE__{closed: closed}), do: :atomics.get(closed, 1) == 1

  defp complete_session(receipt) do
    if :atomics.get(receipt.facts, @custody_pending) == 0,
      do: complete(receipt, @session_done),
      else: {:error, :custody_pending}
  end

  defp complete(receipt, fact) do
    :atomics.put(receipt.facts, fact, 1)

    if Enum.all?(
         [@session_done, @backend_closed, @lease_done],
         &(:atomics.get(receipt.facts, &1) == 1)
       ) do
      :atomics.put(receipt.closed, 1, 1)
    end

    :ok
  end

  defimpl Inspect do
    def inspect(_, _), do: "#Arbor.Voice.ClosureReceipt<redacted>"
  end
end
