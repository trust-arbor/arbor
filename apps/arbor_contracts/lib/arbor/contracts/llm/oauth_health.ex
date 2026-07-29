defmodule Arbor.Contracts.LLM.OAuthHealth do
  @moduledoc """
  Versioned, closed local readiness for one exact Arbor OAuth route.

  This contract answers *liveness*, not *identity*. It deliberately carries no
  access token, refresh token, account id, token hash, filesystem path, or
  expiry timestamp — account identity belongs to
  `Arbor.Contracts.LLM.AuthProvenance`. Every field is a closed enum or a
  bounded integer, so `inspect/1` output is bounded by construction.
  """

  use TypedStruct

  alias Arbor.Contracts.LLM.ControlPlaneSupport, as: Support

  @schema_version 1
  @routes ["openai_oauth", "xai_oauth"]
  @backends ["openai", "xai"]
  @statuses [
    "ready",
    "login_required",
    "migration_required",
    "expired",
    "invalid",
    "relogin_required",
    "source_unavailable",
    "source_unsupported",
    "store_unreadable"
  ]
  @owners ["arbor_owned", "source_owned"]
  @origins ["arbor_login", "external_cli"]
  @sources ["arbor_oauth_store", "codex_file", "grok_file"]
  @fields [:version, :route, :backend, :status, :owner, :origin, :source, :generation]
  @max_bytes 4_096

  # Statuses reached before any envelope was validated: no ownership metadata
  # may be claimed for them.
  @metadata_free_statuses ["login_required", "migration_required", "store_unreadable"]
  # Statuses that assert something about a validated envelope's token material.
  @owner_required_statuses ["ready", "expired"]

  @route_backends %{"openai_oauth" => "openai", "xai_oauth" => "xai"}
  @source_owned_sources %{"openai" => "codex_file", "xai" => "grok_file"}

  typedstruct enforce: true do
    field(:version, pos_integer(), default: @schema_version)
    field(:route, String.t())
    field(:backend, String.t())
    field(:status, String.t())
    field(:owner, String.t() | nil, default: nil)
    field(:origin, String.t() | nil, default: nil)
    field(:source, String.t() | nil, default: nil)
    field(:generation, non_neg_integer() | nil, default: nil)
  end

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec routes() :: [String.t()]
  def routes, do: @routes

  @spec backends() :: [String.t()]
  def backends, do: @backends

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec owners() :: [String.t()]
  def owners, do: @owners

  @spec origins() :: [String.t()]
  def origins, do: @origins

  @spec sources() :: [String.t()]
  def sources, do: @sources

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, tuple()}
  def new(attrs) do
    with {:ok, attrs} <- Support.normalize_object(attrs, @fields, :invalid_oauth_health),
         {:ok, version} <- version(Map.get(attrs, :version, @schema_version)),
         {:ok, route} <- Support.normalize_enum(Map.get(attrs, :route), @routes, :route),
         {:ok, backend} <- Support.normalize_enum(Map.get(attrs, :backend), @backends, :backend),
         {:ok, status} <- Support.normalize_enum(Map.get(attrs, :status), @statuses, :status),
         {:ok, owner} <- Support.optional_enum(attrs, :owner, @owners),
         {:ok, origin} <- Support.optional_enum(attrs, :origin, @origins),
         {:ok, source} <- Support.optional_enum(attrs, :source, @sources),
         {:ok, generation} <- Support.optional_nonnegative_integer(attrs, :generation),
         :ok <-
           validate_combination(%{
             route: route,
             backend: backend,
             status: status,
             owner: owner,
             origin: origin,
             source: source,
             generation: generation
           }) do
      {:ok,
       %__MODULE__{
         version: version,
         route: route,
         backend: backend,
         status: status,
         owner: owner,
         origin: origin,
         source: source,
         generation: generation
       }}
    end
  rescue
    _ -> {:error, {:invalid_oauth_health, :malformed}}
  catch
    _, _ -> {:error, {:invalid_oauth_health, :malformed}}
  end

  @spec to_map(t()) :: map() | {:error, tuple()}
  def to_map(%__MODULE__{} = health) do
    %{
      "version" => health.version,
      "route" => health.route,
      "backend" => health.backend,
      "status" => health.status
    }
    |> Support.put_optional("owner", health.owner)
    |> Support.put_optional("origin", health.origin)
    |> Support.put_optional("source", health.source)
    |> Support.put_optional("generation", health.generation)
  end

  def to_map(_value), do: {:error, {:invalid_oauth_health, :struct_required}}

  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, tuple()}
  def normalize(attrs) do
    with {:ok, health} <- new(attrs), do: {:ok, to_map(health)}
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = health), do: match?({:ok, _}, new(to_map(health)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  @spec canonical_bytes(t() | map() | keyword()) :: {:ok, binary()} | {:error, tuple()}
  def canonical_bytes(%__MODULE__{} = health) do
    with {:ok, health} <- new(to_map(health)) do
      Support.canonical_bytes(to_map(health), @fields, :invalid_oauth_health, @max_bytes)
    end
  end

  def canonical_bytes(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, health} <- new(attrs), do: canonical_bytes(health)
  end

  def canonical_bytes(_value), do: {:error, {:invalid_oauth_health, :object_required}}

  defp version(@schema_version), do: {:ok, @schema_version}
  defp version(_version), do: {:error, {:invalid_field, "version"}}

  # Every rejection below is a combination the LLM-side derivation must never be
  # able to emit; they are asserted directly in the contract test.
  defp validate_combination(%{route: route, backend: backend} = fields) do
    cond do
      Map.fetch!(@route_backends, route) != backend ->
        {:error, {:invalid_oauth_health, :route_backend_mismatch}}

      partial_ownership?(fields) ->
        {:error, {:invalid_oauth_health, :partial_ownership}}

      not valid_ownership?(fields) ->
        {:error, {:invalid_oauth_health, :ownership_mismatch}}

      is_integer(fields.generation) and is_nil(fields.owner) ->
        {:error, {:invalid_oauth_health, :generation_without_owner}}

      fields.status in @metadata_free_statuses and claims_metadata?(fields) ->
        {:error, {:invalid_oauth_health, :metadata_without_envelope}}

      fields.status == "source_unsupported" and backend != "xai" ->
        {:error, {:invalid_oauth_health, :source_unsupported_backend}}

      fields.status in @owner_required_statuses and is_nil(fields.owner) ->
        {:error, {:invalid_oauth_health, :owner_required}}

      true ->
        :ok
    end
  end

  defp partial_ownership?(%{owner: owner, origin: origin, source: source}) do
    present = Enum.count([owner, origin, source], &(not is_nil(&1)))
    present > 0 and present < 3
  end

  defp valid_ownership?(%{owner: nil}), do: true

  defp valid_ownership?(%{owner: "arbor_owned", origin: origin, source: source}),
    do: origin == "arbor_login" and source == "arbor_oauth_store"

  defp valid_ownership?(%{
         owner: "source_owned",
         origin: origin,
         source: source,
         backend: backend
       }),
       do: origin == "external_cli" and source == Map.fetch!(@source_owned_sources, backend)

  defp claims_metadata?(%{owner: owner, origin: origin, source: source, generation: generation}) do
    Enum.any?([owner, origin, source, generation], &(not is_nil(&1)))
  end
end
