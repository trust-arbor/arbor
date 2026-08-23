defmodule Arbor.Security.AuditJournalOwner do
  @moduledoc """
  Supervised single-writer owner for the v1 Security authority-mutation audit journal.

  Serializes every append over `AuditJournalCore` and, in durable mode,
  `AuditJournalFile`. Reconstructs from the durable log before serving.
  Production callers outside this library use `Arbor.Security` status and
  pending facades only.

  Not a generic store. Compaction, Historian delivery, and grant/revoke wiring
  are later slices.
  """

  use GenServer

  alias Arbor.Security.AuditJournalCore
  alias Arbor.Security.AuditJournalFile
  alias Arbor.Security.Config

  @allowed_opts if(Mix.env() == :test,
                  do: [:mode, :root, :reason, :name],
                  else: [:mode, :root, :reason]
                )
  @disabled_reasons [:disabled, :activation_only]

  @type append_ok :: {:ok, :committed} | {:ok, :idempotent}
  @type append_error ::
          {:error,
           :journal_disabled
           | :journal_poisoned
           | :journal_unavailable
           | :malformed
           | :out_of_order
           | :illegal_transition
           | :post_terminal
           | :operation_conflict
           | :cross_operation
           | :record_too_large
           | :soft_capacity_exhausted
           | :capacity_exhausted
           | {:not_committed, term()}
           | {:commit_uncertain, term()}}

  @spec start_link(keyword()) :: GenServer.on_start() | {:error, :invalid_opts}
  def start_link(opts \\ [])

  def start_link(opts) when is_list(opts) do
    with :ok <- reject_unknown_opts(opts),
         {:ok, boot} <- admit_boot_opts(opts) do
      GenServer.start_link(__MODULE__, boot, name: boot.name)
    end
  end

  def start_link(_opts), do: {:error, :invalid_opts}

  @spec append(term()) :: append_ok() | append_error()
  def append(raw), do: do_append(__MODULE__, raw)

  @spec status() :: {:ok, map()} | {:error, :journal_unavailable}
  def status, do: do_query(__MODULE__, :status)

  @spec pending_operations() :: {:ok, [map()]} | {:error, :journal_unavailable}
  def pending_operations, do: do_query(__MODULE__, :pending_operations)

  if Mix.env() == :test do
    @doc false
    @spec append(GenServer.server(), term()) :: append_ok() | append_error()
    def append(server, raw), do: do_append(server, raw)

    @doc false
    @spec status(GenServer.server()) :: {:ok, map()} | {:error, :journal_unavailable}
    def status(server), do: do_query(server, :status)

    @doc false
    @spec pending_operations(GenServer.server()) ::
            {:ok, [map()]} | {:error, :journal_unavailable}
    def pending_operations(server), do: do_query(server, :pending_operations)

    @doc false
    @spec __test_inject__(GenServer.server(), :clear) :: :ok | {:error, :journal_unavailable}
    def __test_inject__(server, :clear) do
      safe_call(server, {:__test_inject__, :clear}, :query)
    end

    @doc false
    @spec __test_inject__(GenServer.server(), atom(), term()) ::
            :ok | {:error, :journal_unavailable}
    def __test_inject__(server, kind, value) do
      safe_call(server, {:__test_inject__, kind, value}, :query)
    end
  end

  @impl true
  def init(%{mode: :disabled, reason: reason}) do
    {:ok, core} = AuditJournalCore.new()

    {:ok,
     owner_state(
       core: core,
       mode: :disabled,
       durability: :dormant,
       availability: :dormant,
       reason: reason,
       last_error: :disabled,
       serving: false
     )}
  end

  def init(%{mode: :ephemeral}) do
    {:ok, core} = AuditJournalCore.new()

    {:ok,
     owner_state(
       core: core,
       mode: :ephemeral,
       durability: :ephemeral,
       availability: :serving,
       reason: :none,
       last_error: :none,
       serving: true
     )}
  end

  def init(%{mode: :durable, root: root}) do
    case AuditJournalFile.open(root: root) do
      {:ok, handle} ->
        torn? = handle.torn_tail != nil

        {:ok,
         owner_state(
           core: handle.core,
           handle: handle,
           committed_frames: handle.frames,
           torn_tail?: torn?,
           mode: :durable,
           durability: :durable,
           availability: if(torn?, do: :degraded, else: :serving),
           reason: if(torn?, do: :torn_tail, else: :none),
           last_error: if(torn?, do: :torn_tail, else: :none),
           serving: not torn?
         )}

      {:error, reason} ->
        {:stop, {:journal_open_failed, reason}}
    end
  end

  def init(_boot), do: {:stop, :invalid_opts}

  @impl true
  def handle_call({:append, _raw}, _from, %{mode: :disabled} = state) do
    {:reply, {:error, :journal_disabled}, state}
  end

  def handle_call({:append, _raw}, _from, %{poisoned?: true} = state) do
    {:reply, {:error, :journal_poisoned}, state}
  end

  def handle_call({:append, _raw}, _from, %{torn_tail?: true} = state) do
    {:reply, {:error, {:not_committed, :torn_tail}}, mark_torn(state)}
  end

  def handle_call({:append, raw}, _from, %{mode: :durable} = state) do
    apply_durable_append(state, raw)
  end

  def handle_call({:append, raw}, _from, %{mode: :ephemeral} = state) do
    apply_ephemeral_append(state, raw)
  end

  def handle_call(:status, _from, state) do
    {:reply, build_status(state), state}
  end

  def handle_call(:pending_operations, _from, state) do
    {:reply, build_pending_operations(state), state}
  end

  if Mix.env() == :test do
    @impl true
    def handle_call({:__test_inject__, :clear}, _from, state) do
      {:reply, AuditJournalFile.__test_inject__(:clear), state}
    end

    def handle_call({:__test_inject__, kind, value}, _from, state) do
      {:reply, AuditJournalFile.__test_inject__(kind, value), state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{handle: handle}) when not is_nil(handle) do
    AuditJournalFile.close(handle)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def format_status(status) when is_map(status) do
    owner_state = Map.get(status, :state, %{})

    redacted = %{
      mode: Map.get(owner_state, :mode),
      availability: Map.get(owner_state, :availability),
      poisoned: Map.get(owner_state, :poisoned?, false),
      torn_tail: Map.get(owner_state, :torn_tail?, false)
    }

    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, redacted)
    |> redact_field(:reason)
    |> redact_field(:log)
  end

  defp apply_durable_append(state, raw) do
    case AuditJournalFile.append(state.handle, raw) do
      {:ok, handle} ->
        {:reply, {:ok, :committed}, commit_handle(state, handle)}

      {:ok, handle, :idempotent} ->
        {:reply, {:ok, :idempotent}, commit_handle(state, handle)}

      {:error, {:commit_uncertain, _reason} = err} ->
        {:reply, {:error, err}, poison(state, :commit_uncertain)}

      {:error, {:not_committed, :torn_tail} = err} ->
        {:reply, {:error, err}, mark_torn(state)}

      {:error, {:not_committed, _reason} = err} ->
        {:reply, {:error, err}, poison(state, :not_committed)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp apply_ephemeral_append(state, raw) do
    case AuditJournalCore.append(state.core, raw) do
      {:ok, core} ->
        {:reply, {:ok, :committed}, %{state | core: core, last_error: :none}}

      {:ok, core, :idempotent} ->
        {:reply, {:ok, :idempotent}, %{state | core: core, last_error: :none}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp commit_handle(state, handle) do
    %{
      state
      | handle: handle,
        core: handle.core,
        committed_frames: handle.frames,
        last_error: :none,
        torn_tail?: false,
        poisoned?: false,
        availability: :serving,
        reason: :none,
        serving: true
    }
  end

  defp poison(state, last_error) do
    if state.handle, do: AuditJournalFile.close(state.handle)

    %{
      state
      | handle: nil,
        poisoned?: true,
        serving: false,
        availability: :degraded,
        reason: :poisoned,
        last_error: last_error,
        torn_tail?: false
    }
  end

  defp mark_torn(state) do
    %{
      state
      | torn_tail?: true,
        serving: false,
        availability: :degraded,
        reason: :torn_tail,
        last_error: :torn_tail
    }
  end

  defp build_status(state) do
    case core_pending_summary(state) do
      {:ok, summary} ->
        shown = AuditJournalCore.show(state.core)
        availability = state.availability

        {:ok,
         %{
           "version" => 1,
           "mode" => Atom.to_string(state.mode),
           "durability" => Atom.to_string(state.durability),
           "availability" => Atom.to_string(availability),
           "reason" => Atom.to_string(state.reason),
           "serving" => availability == :serving,
           "poisoned" => state.poisoned?,
           "torn_tail" => state.torn_tail?,
           "last_error" => Atom.to_string(state.last_error),
           "entry_count" => shown["entry_count"],
           "byte_count" => shown["byte_count"],
           "pending_count" => summary["pending_count"],
           "oldest_pending_age_seconds" => summary["oldest_pending_age_seconds"],
           "committed_frames" => state.committed_frames,
           "capacity" => AuditJournalCore.capacity(state.core)
         }}

      {:error, :journal_unavailable} = err ->
        err
    end
  end

  defp build_pending_operations(state) do
    case core_pending_summary(state) do
      {:ok, summary} -> {:ok, summary["operations"]}
      {:error, :journal_unavailable} = err -> err
    end
  end

  defp core_pending_summary(state) do
    case AuditJournalCore.pending_summary(state.core, sampled_wall_clock()) do
      {:ok, summary} -> {:ok, summary}
      {:error, :malformed} -> {:error, :journal_unavailable}
    end
  end

  defp sampled_wall_clock do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

  defp owner_state(fields) do
    Enum.into(fields, %{
      handle: nil,
      committed_frames: 0,
      torn_tail?: false,
      poisoned?: false
    })
  end

  defp do_append(server, raw) do
    safe_call(server, {:append, raw}, :append)
  end

  defp do_query(server, request) do
    safe_call(server, request, :query)
  end

  defp safe_call(server, request, kind) do
    GenServer.call(server, request, Config.audit_journal_call_timeout_ms())
  catch
    :exit, {:timeout, _} when kind == :append ->
      {:error, {:commit_uncertain, :timeout}}

    :exit, {:timeout, _} ->
      {:error, :journal_unavailable}

    :exit, {:noproc, _} ->
      {:error, :journal_unavailable}

    :exit, :noproc ->
      {:error, :journal_unavailable}

    :exit, _reason ->
      {:error, :journal_unavailable}
  end

  defp reject_unknown_opts(opts) do
    unknown = Keyword.keys(opts) -- @allowed_opts

    if unknown == [] do
      :ok
    else
      {:error, :invalid_opts}
    end
  end

  defp admit_boot_opts(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    if is_atom(name) do
      admit_mode(opts, name)
    else
      {:error, :invalid_opts}
    end
  end

  defp admit_mode(opts, name) do
    case Keyword.get(opts, :mode) do
      :disabled ->
        admit_disabled(opts, name)

      :ephemeral ->
        admit_ephemeral(opts, name)

      :durable ->
        admit_durable(opts, name)

      _other ->
        {:error, :invalid_opts}
    end
  end

  defp admit_disabled(opts, name) do
    reason = Keyword.get(opts, :reason, :disabled)

    if reason in @disabled_reasons and not Keyword.has_key?(opts, :root) do
      {:ok, %{mode: :disabled, reason: reason, name: name}}
    else
      {:error, :invalid_opts}
    end
  end

  defp admit_ephemeral(opts, name) do
    if Keyword.has_key?(opts, :root) or Keyword.has_key?(opts, :reason) do
      {:error, :invalid_opts}
    else
      {:ok, %{mode: :ephemeral, name: name}}
    end
  end

  defp admit_durable(opts, name) do
    root = Keyword.get(opts, :root)

    if is_binary(root) and byte_size(root) > 0 and not Keyword.has_key?(opts, :reason) do
      {:ok, %{mode: :durable, root: root, name: name}}
    else
      {:error, :invalid_opts}
    end
  end

  defp redact_field(status, key) do
    if Map.has_key?(status, key), do: Map.put(status, key, :redacted), else: status
  end
end
