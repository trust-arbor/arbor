defmodule Arbor.Persistence.EngagementStore do
  @moduledoc """
  Durable store for engagements (device-independent conversations), backed by
  `Arbor.Persistence.Repo`. The Repo is adapter-aware — SQLite3 by default,
  PostgreSQL when configured (`ARBOR_DB=postgres`) — so this uses whichever DB the
  install runs on; no backend-specific code.

  Speaks the `Arbor.Contracts.Comms.Engagement` struct in and out (scope/status/
  visibility atoms ↔ string columns). `Arbor.Comms.EngagementStore` (the in-memory
  ETS resolver) writes through to here and recovers from here on a cache miss, so
  engagements survive restarts and "list my conversations" is a real query.
  """

  import Ecto.Query

  alias Arbor.Contracts.Comms.Engagement
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.Engagement, as: Schema

  @spec available?() :: boolean()
  def available?, do: Process.whereis(Repo) != nil

  @doc "Insert or update an engagement (by engagement_id)."
  @spec upsert(Engagement.t()) :: {:ok, Engagement.t()} | {:error, term()}
  def upsert(%Engagement{id: id} = engagement) when is_binary(id) do
    attrs = to_attrs(engagement)
    existing = Repo.one(from(e in Schema, where: e.engagement_id == ^id))

    result =
      (existing || %Schema{})
      |> Schema.changeset(attrs)
      |> then(&if(existing, do: Repo.update(&1), else: Repo.insert(&1)))

    with {:ok, schema} <- result, do: {:ok, to_contract(schema)}
  end

  @doc "Fetch an engagement by id."
  @spec get(String.t()) :: {:ok, Engagement.t()} | {:error, :not_found}
  def get(engagement_id) when is_binary(engagement_id) do
    case Repo.one(from(e in Schema, where: e.engagement_id == ^engagement_id)) do
      nil -> {:error, :not_found}
      schema -> {:ok, to_contract(schema)}
    end
  end

  @doc "All engagements for an agent, most-recently-updated first."
  @spec list_for_agent(String.t()) :: [Engagement.t()]
  def list_for_agent(agent_id) when is_binary(agent_id) do
    from(e in Schema, where: e.agent_id == ^agent_id, order_by: [desc: e.updated_at])
    |> Repo.all()
    |> Enum.map(&to_contract/1)
  end

  @doc "Delete an engagement by id."
  @spec delete(String.t()) :: :ok
  def delete(engagement_id) when is_binary(engagement_id) do
    Repo.delete_all(from(e in Schema, where: e.engagement_id == ^engagement_id))
    :ok
  end

  # ── contract <-> schema ───────────────────────────────────────────

  defp to_attrs(%Engagement{} = e) do
    %{
      engagement_id: e.id,
      agent_id: e.agent_id,
      owner_tenant: e.owner_tenant,
      scope: to_string(e.scope),
      status: to_string(e.status),
      visibility: to_string(e.visibility),
      attached_channels: e.attached_channels || [],
      primary_channel: e.primary_channel,
      metadata: e.metadata || %{}
    }
  end

  defp to_contract(%Schema{} = s) do
    %Engagement{
      id: s.engagement_id,
      agent_id: s.agent_id,
      owner_tenant: s.owner_tenant,
      scope: from_string(s.scope, [:channel, :user, :role], :channel),
      status: from_string(s.status, [:active, :parked, :archived], :active),
      visibility: from_string(s.visibility, [:private, :group, :internal, :public], :private),
      attached_channels: s.attached_channels || [],
      primary_channel: s.primary_channel,
      created_at: s.inserted_at,
      metadata: s.metadata || %{}
    }
  end

  # Map a stored string back to its known atom without String.to_atom (the value
  # set is closed; default if a row ever holds something unexpected).
  defp from_string(value, allowed, default) do
    Enum.find(allowed, default, &(to_string(&1) == value))
  end
end
