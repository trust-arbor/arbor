defmodule Arbor.Contracts.Security.CapabilityProfile do
  @moduledoc """
  Risk metadata for a capability URI prefix.

  Capability profiles describe what a capability can do, independent of the URI
  string used to address it. They are the shared Level-0 contract consumed by
  security, trust, actions, and orchestration policy projection code.

  The post-tier-retirement field set intentionally does not include
  `:trust_floor`. Standing-based gates are represented by `:default_approval`
  plus `:graduation_eligible`.
  """

  use TypedStruct

  alias Arbor.Contracts.Security.CapabilityUri
  alias Arbor.Contracts.Security.Classification
  alias Arbor.Contracts.Security.Taint

  @type blast_radius :: :low | :medium | :high | :critical
  @type reversibility :: :read_only | :reversible | :irreversible
  @type default_approval :: :auto | :notify | :require_human | :forbid
  @type cost_class :: :cheap | :metered | :expensive
  @type compensation :: nil | %{optional(atom() | String.t()) => term()}
  @type constraints :: %{optional(atom() | String.t()) => term()}

  @blast_radii [:low, :medium, :high, :critical]
  @reversibilities [:read_only, :reversible, :irreversible]
  @default_approvals [:auto, :notify, :require_human, :forbid]
  @cost_classes [:cheap, :metered, :expensive]

  @fields [
    :uri_prefix,
    :owner,
    :blast_radius,
    :reversibility,
    :compensation,
    :effect_class,
    :data_class,
    :arg_dependent,
    :default_approval,
    :default_constraints,
    :delegable,
    :cost_class,
    :graduation_eligible
  ]

  @required_fields @fields -- [:compensation, :default_constraints]

  @derive Jason.Encoder
  typedstruct enforce: true do
    field(:uri_prefix, String.t())
    field(:owner, atom())
    field(:blast_radius, blast_radius())
    field(:reversibility, reversibility())
    field(:compensation, compensation(), default: nil)
    field(:effect_class, Classification.effect_class())
    field(:data_class, Taint.sensitivity())
    field(:arg_dependent, boolean())
    field(:default_approval, default_approval())
    field(:default_constraints, constraints(), default: %{})
    field(:delegable, boolean())
    field(:cost_class, cost_class())
    field(:graduation_eligible, boolean())
  end

  @doc "Construct and validate a capability profile."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    with :ok <- reject_unknown_fields(attrs),
         :ok <- require_fields(attrs),
         {:ok, uri_prefix} <- validate_uri_prefix(Map.fetch!(attrs, :uri_prefix)),
         {:ok, owner} <- validate_owner(Map.fetch!(attrs, :owner)),
         {:ok, blast_radius} <-
           validate_enum(Map.fetch!(attrs, :blast_radius), @blast_radii, :blast_radius),
         {:ok, reversibility} <-
           validate_enum(Map.fetch!(attrs, :reversibility), @reversibilities, :reversibility),
         {:ok, compensation} <- validate_map_or_nil(Map.get(attrs, :compensation), :compensation),
         {:ok, effect_class} <-
           validate_enum(
             Map.fetch!(attrs, :effect_class),
             Classification.effect_classes(),
             :effect_class
           ),
         {:ok, data_class} <-
           validate_enum(Map.fetch!(attrs, :data_class), Taint.sensitivities(), :data_class),
         {:ok, arg_dependent} <-
           validate_boolean(Map.fetch!(attrs, :arg_dependent), :arg_dependent),
         {:ok, default_approval} <-
           validate_enum(
             Map.fetch!(attrs, :default_approval),
             @default_approvals,
             :default_approval
           ),
         {:ok, default_constraints} <-
           validate_map(Map.get(attrs, :default_constraints, %{}), :default_constraints),
         {:ok, delegable} <- validate_boolean(Map.fetch!(attrs, :delegable), :delegable),
         {:ok, cost_class} <-
           validate_enum(Map.fetch!(attrs, :cost_class), @cost_classes, :cost_class),
         {:ok, graduation_eligible} <-
           validate_boolean(Map.fetch!(attrs, :graduation_eligible), :graduation_eligible) do
      {:ok,
       %__MODULE__{
         uri_prefix: uri_prefix,
         owner: owner,
         blast_radius: blast_radius,
         reversibility: reversibility,
         compensation: compensation,
         effect_class: effect_class,
         data_class: data_class,
         arg_dependent: arg_dependent,
         default_approval: default_approval,
         default_constraints: default_constraints,
         delegable: delegable,
         cost_class: cost_class,
         graduation_eligible: graduation_eligible
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_attrs}

  @doc "Construct a capability profile, raising `ArgumentError` on invalid input."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, profile} ->
        profile

      {:error, reason} ->
        raise ArgumentError, "invalid capability profile: #{inspect(reason)}"
    end
  end

  @doc """
  Merge operator overrides over an existing profile and revalidate the result.

  Overrides may change risk metadata, owner, constraints, or graduation
  eligibility. They may not change the profile's `:uri_prefix`; the caller
  already selected the profile by that key.
  """
  @spec merge(t(), keyword() | map()) :: {:ok, t()} | {:error, term()}
  def merge(%__MODULE__{} = profile, overrides) when is_list(overrides) or is_map(overrides) do
    overrides = if is_list(overrides), do: Map.new(overrides), else: overrides

    if Map.has_key?(overrides, :uri_prefix) do
      {:error, :cannot_override_uri_prefix}
    else
      profile
      |> Map.from_struct()
      |> Map.merge(overrides)
      |> new()
    end
  end

  def merge(_profile, _overrides), do: {:error, :invalid_attrs}

  @doc "Merge operator overrides, raising `ArgumentError` on invalid input."
  @spec merge!(t(), keyword() | map()) :: t()
  def merge!(%__MODULE__{} = profile, overrides) do
    case merge(profile, overrides) do
      {:ok, profile} ->
        profile

      {:error, reason} ->
        raise ArgumentError, "invalid capability profile override: #{inspect(reason)}"
    end
  end

  @doc "Valid blast-radius atoms in increasing severity order."
  @spec blast_radii() :: [blast_radius()]
  def blast_radii, do: @blast_radii

  @doc "Valid reversibility atoms."
  @spec reversibilities() :: [reversibility()]
  def reversibilities, do: @reversibilities

  @doc "Valid default-approval atoms."
  @spec default_approvals() :: [default_approval()]
  def default_approvals, do: @default_approvals

  @doc "Valid cost-class atoms."
  @spec cost_classes() :: [cost_class()]
  def cost_classes, do: @cost_classes

  @doc "All accepted profile fields."
  @spec fields() :: [atom()]
  def fields, do: @fields

  defp reject_unknown_fields(attrs) do
    unknown = Map.keys(attrs) -- @fields

    case unknown do
      [] -> :ok
      fields -> {:error, {:unknown_fields, Enum.sort(fields)}}
    end
  end

  defp require_fields(attrs) do
    missing = Enum.reject(@required_fields, &Map.has_key?(attrs, &1))

    case missing do
      [] -> :ok
      fields -> {:error, {:missing_fields, fields}}
    end
  end

  defp validate_uri_prefix(uri_prefix) when is_binary(uri_prefix) do
    with {:ok, parsed} <- CapabilityUri.parse(uri_prefix),
         :ok <- reject_wildcard(parsed),
         :ok <- reject_traversal(parsed) do
      {:ok, CapabilityUri.canonical(parsed)}
    else
      {:error, reason} -> {:error, {:invalid_uri_prefix, reason}}
    end
  end

  defp validate_uri_prefix(_), do: {:error, {:invalid_uri_prefix, :not_binary}}

  defp reject_wildcard(%CapabilityUri{wildcard: :none}), do: :ok
  defp reject_wildcard(_parsed), do: {:error, :wildcard_prefix_not_allowed}

  defp reject_traversal(%CapabilityUri{segments: segments}) do
    if ".." in segments do
      {:error, :traversal_segment}
    else
      :ok
    end
  end

  defp validate_owner(owner) when is_atom(owner) and not is_nil(owner), do: {:ok, owner}
  defp validate_owner(_owner), do: {:error, {:invalid_owner, :must_be_atom}}

  defp validate_enum(value, allowed, field) do
    if value in allowed do
      {:ok, value}
    else
      {:error, {:invalid_enum, field, value, allowed}}
    end
  end

  defp validate_boolean(value, _field) when is_boolean(value), do: {:ok, value}
  defp validate_boolean(value, field), do: {:error, {:invalid_boolean, field, value}}

  defp validate_map(value, _field) when is_map(value), do: {:ok, value}
  defp validate_map(value, field), do: {:error, {:invalid_map, field, value}}

  defp validate_map_or_nil(nil, _field), do: {:ok, nil}
  defp validate_map_or_nil(value, field), do: validate_map(value, field)
end
