defmodule Arbor.Contracts.LLM.AuthProvenance do
  @moduledoc """
  Versioned, closed metadata for the owner of a rotating authentication family.

  This contract deliberately carries no credential, token, authority, or
  executable data. `source` identifies where read-through metadata came from;
  it is not a path or a secret.
  """

  use TypedStruct

  alias Arbor.Contracts.LLM.ControlPlaneSupport, as: Support

  @schema_version 2
  @providers ["openai", "xai"]
  @owners ["arbor_owned", "source_owned"]
  @origins ["arbor_login", "external_cli"]
  @sources ["arbor_oauth_store", "codex_file", "grok_file"]
  @fields [
    :version,
    :provider,
    :account_id,
    :origin,
    :owner,
    :source,
    :generation,
    :source_generation,
    :source_observed_at
  ]
  @max_bytes 16_384

  typedstruct enforce: true do
    field(:version, pos_integer(), default: @schema_version)
    field(:provider, String.t())
    field(:account_id, String.t() | nil)
    field(:origin, String.t())
    field(:owner, String.t())
    field(:source, String.t())
    field(:generation, non_neg_integer())
    field(:source_generation, non_neg_integer() | nil, default: nil)
    field(:source_observed_at, String.t() | nil, default: nil)
  end

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec owners() :: [String.t()]
  def owners, do: @owners

  @spec providers() :: [String.t()]
  def providers, do: @providers

  @spec origins() :: [String.t()]
  def origins, do: @origins

  @spec sources() :: [String.t()]
  def sources, do: @sources

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, tuple()}
  def new(attrs) do
    with {:ok, attrs} <- Support.normalize_object(attrs, @fields, :invalid_auth_provenance),
         {:ok, version} <- version(Map.get(attrs, :version, @schema_version)),
         {:ok, provider} <-
           Support.normalize_enum(Map.get(attrs, :provider), @providers, :provider),
         {:ok, account_id} <- account_id(Map.get(attrs, :account_id)),
         {:ok, origin} <- Support.normalize_enum(Map.get(attrs, :origin), @origins, :origin),
         {:ok, owner} <- Support.normalize_enum(Map.get(attrs, :owner), @owners, :owner),
         {:ok, source} <- Support.normalize_enum(Map.get(attrs, :source), @sources, :source),
         {:ok, generation} <- generation(Map.get(attrs, :generation), :generation),
         {:ok, source_generation} <-
           Support.optional_nonnegative_integer(attrs, :source_generation),
         {:ok, source_observed_at, _datetime} <-
           Support.optional_timestamp(attrs, :source_observed_at),
         :ok <-
           validate_ownership(
             provider,
             origin,
             owner,
             source,
             source_generation,
             source_observed_at
           ) do
      {:ok,
       %__MODULE__{
         version: version,
         provider: provider,
         account_id: account_id,
         origin: origin,
         owner: owner,
         source: source,
         generation: generation,
         source_generation: source_generation,
         source_observed_at: source_observed_at
       }}
    end
  rescue
    _ -> {:error, {:invalid_auth_provenance, :malformed}}
  catch
    _, _ -> {:error, {:invalid_auth_provenance, :malformed}}
  end

  @spec to_map(t()) :: map() | {:error, tuple()}
  def to_map(%__MODULE__{} = provenance) do
    %{
      "version" => provenance.version,
      "provider" => provenance.provider,
      "account_id" => provenance.account_id,
      "origin" => provenance.origin,
      "owner" => provenance.owner,
      "source" => provenance.source,
      "generation" => provenance.generation
    }
    |> Support.put_optional("source_generation", provenance.source_generation)
    |> Support.put_optional("source_observed_at", provenance.source_observed_at)
  end

  def to_map(_value), do: {:error, {:invalid_auth_provenance, :struct_required}}

  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, tuple()}
  def normalize(attrs) do
    with {:ok, provenance} <- new(attrs), do: {:ok, to_map(provenance)}
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = provenance), do: match?({:ok, _}, new(to_map(provenance)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  @spec canonical_bytes(t() | map() | keyword()) :: {:ok, binary()} | {:error, tuple()}
  def canonical_bytes(%__MODULE__{} = provenance) do
    with {:ok, normalized} <- new(to_map(provenance)),
         {:ok, bytes} <-
           Support.canonical_bytes(
             to_map(normalized),
             @fields,
             :invalid_auth_provenance,
             @max_bytes
           ) do
      {:ok, bytes}
    end
  end

  def canonical_bytes(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, provenance} <- new(attrs), do: canonical_bytes(provenance)
  end

  def canonical_bytes(_value), do: {:error, {:invalid_auth_provenance, :object_required}}

  @spec digest(t() | map() | keyword()) :: {:ok, String.t()} | {:error, tuple()}
  def digest(value) do
    with {:ok, bytes} <- canonical_bytes(value),
         do: Support.digest(bytes, :invalid_auth_provenance)
  rescue
    _ -> {:error, {:invalid_auth_provenance, :malformed}}
  catch
    _, _ -> {:error, {:invalid_auth_provenance, :malformed}}
  end

  defp version(@schema_version), do: {:ok, @schema_version}
  defp version(_version), do: {:error, {:invalid_field, "version"}}

  defp account_id(nil), do: {:ok, nil}
  defp account_id(value), do: Support.normalize_text(value, :account_id, 512)

  defp generation(value, _field)
       when is_integer(value) and value >= 0 and value <= 1_000_000_000_000,
       do: {:ok, value}

  defp generation(_value, field), do: {:error, {:invalid_field, Atom.to_string(field)}}

  defp validate_ownership(
         _provider,
         "arbor_login",
         "arbor_owned",
         "arbor_oauth_store",
         nil,
         nil
       ),
       do: :ok

  defp validate_ownership(
         "openai",
         "external_cli",
         "source_owned",
         "codex_file",
         source_generation,
         source_observed_at
       )
       when is_integer(source_generation) and is_binary(source_observed_at),
       do: :ok

  defp validate_ownership(
         "xai",
         "external_cli",
         "source_owned",
         "grok_file",
         source_generation,
         source_observed_at
       )
       when is_integer(source_generation) and is_binary(source_observed_at),
       do: :ok

  defp validate_ownership(
         _provider,
         _origin,
         _owner,
         _source,
         _source_generation,
         _source_observed_at
       ),
       do: {:error, {:invalid_auth_provenance, :ownership_semantics}}
end
