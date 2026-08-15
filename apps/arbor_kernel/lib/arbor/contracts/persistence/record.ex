defmodule Arbor.Contracts.Persistence.Record do
  @moduledoc """
  A structured record for queryable storage backends.

  Records wrap key-value data with metadata, timestamps, a unique logical ID,
  and backend-owned fencing tokens (`generation` + `revision`).

  Use Records when you need structured, queryable persistence. For simple
  key-value storage, values can be any term — Records are not required.

  ## Identity rule (all structured backends)

  1. **Logical id** — `Record.id` (e.g. `rec_…`) is the record's logical
     identity. It is **not** the physical storage identity and must not be
     rewritten as `namespace <> ":" <> key`.
  2. **Physical storage identity** — the store key (and, for Postgres, the
     `(namespace, key)` pair). Lookups, deletes, and CAS bind to that pair.
  3. **Key agreement** — on structured put/CAS, `Record.key` must equal the
     store key argument; mismatches are rejected.
  4. **Backend-owned fencing** — `generation` and `revision` are advanced only
     by backends. Callers cannot roll them backward. Updates preserve the
     stored logical id and generation while advancing revision; delete then
     reinsert starts a new generation (ABA-safe for Records).

  ## Generation and revision

  - `generation` is an incarnation token. It starts at `0` for not-yet-persisted
    records. First successful insert becomes generation `1`. After delete, a
    backend-owned tombstone retains the generation so a later reinsert becomes
    `generation + 1`.
  - `revision` is monotonic **within** a generation. First insert/reinsert sets
    revision `1`; each successful put/CAS update increments it.

  Structured Record CAS compares **both** generation and revision. Ordinary
  unversioned value CAS uses term equality only and does **not** prevent
  delete/reinsert ABA (documented on the Store contract).
  """

  use TypedStruct

  typedstruct do
    @typedoc "A persistence record with metadata, timestamps, and fencing tokens"

    field(:id, String.t(), enforce: true)
    field(:key, String.t(), enforce: true)
    field(:data, map(), default: %{})
    field(:metadata, map(), default: %{})
    field(:generation, non_neg_integer(), default: 0)
    field(:revision, non_neg_integer(), default: 0)
    field(:inserted_at, DateTime.t())
    field(:updated_at, DateTime.t())
  end

  @doc """
  Create a new record with auto-generated ID and timestamps.

  Optional keys: `:id`, `:metadata`, `:inserted_at`, `:updated_at`,
  `:revision`, `:generation`. Both fencing tokens default to `0` (not yet
  persisted).
  """
  @spec new(String.t(), map(), keyword()) :: t()
  def new(key, data \\ %{}, opts \\ []) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: Keyword.get(opts, :id, Arbor.Identifiers.generate_id("rec_")),
      key: key,
      data: data,
      metadata: Keyword.get(opts, :metadata, %{}),
      generation: Keyword.get(opts, :generation, 0),
      revision: Keyword.get(opts, :revision, 0),
      inserted_at: Keyword.get(opts, :inserted_at, now),
      updated_at: Keyword.get(opts, :updated_at, now)
    }
  end

  @doc """
  Update a record's data and bump updated_at.

  Preserves `generation` and `revision` — both are advanced only by persistence
  backends on successful put/CAS, not by this pure transform.
  """
  @spec update(t(), map(), keyword()) :: t()
  def update(%__MODULE__{} = record, data, opts \\ []) do
    %{
      record
      | data: data,
        metadata: Keyword.get(opts, :metadata, record.metadata),
        updated_at: DateTime.utc_now()
    }
  end

  defimpl Jason.Encoder do
    def encode(record, opts) do
      record
      |> Map.from_struct()
      |> Map.update(:inserted_at, nil, &to_string/1)
      |> Map.update(:updated_at, nil, &to_string/1)
      |> Jason.Encode.map(opts)
    end
  end
end
