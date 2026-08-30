defmodule Arbor.Contracts.Coding.ValidationProgram do
  @moduledoc """
  Sealed, digest-bound validation-program manifest for a coding work packet.

  `required_evidence` is authorized as **one** reviewed-validation resource
  whose canonical URI carries the SHA-256 digest of this manifest's
  domain-separated, length-delimited encoding. The digest is always recomputed
  from the admitted struct; an executor-supplied digest is never accepted.

  This packet is the shared `arbor_kernel` contract only: construct, admit,
  encode, digest, and render. It has no side effects and does not call any
  other umbrella library.

  Executor and authorization wiring is the **next packet** and is intentionally
  absent here: policy for the exact resource URI, `SignedRequest` and approval
  binding, approved-retry equality, argv `--` separation, and revalidation
  before execution. See the council decision of 2026-08-29 (13/13) and the
  durable factory contract in `docs/arbor/SOFTWARE_FACTORY.md`.
  """

  use TypedStruct

  alias Arbor.Contracts.Security.CapabilityUri

  @schema_version 1
  @domain_prefix <<"arbor-coding-validation-v1", 0>>
  @digest_prefix "sha256:"
  @uri_prefix "arbor://action/coding/validate/v1/"
  @hex64_re ~r/\A[0-9a-f]{64}\z/
  @snapshot_digest_re ~r/\Asha256:[0-9a-f]{64}\z/
  @c0_del_re ~r/[\x00-\x1F\x7F]/
  @drive_letter_re ~r/\A[A-Za-z]:/
  @max_json_safe_integer 9_007_199_254_740_991
  @max_text_bytes 256
  @max_path_bytes 4_096
  @max_component_bytes 255
  @max_path_depth 48
  @max_stages 16
  @max_test_paths 256
  # A candidate-tree inventory lists every regular file the snapshot holds;
  # this umbrella alone tracks >4,100 files, so the bound must cover a real
  # monorepo while still refusing an unbounded list (council, 2026-08-29).
  @max_inventory_entries 65_536
  @fields [
    :schema_version,
    :profile,
    :stages,
    :snapshot_digest,
    :budget,
    :deadline_unix_ms,
    :containment_profile,
    :executor_version
  ]
  @constructor_fields [:inventory | @fields]
  @budget_fields [:compile_share_ms, :evidence_share_ms, :total_ms]
  @stage_kinds [:mix_compile, :mix_test]
  @inventory_types [:regular, :directory, :symlink]

  @type stage_kind :: :mix_compile | :mix_test
  @type inventory_type :: :regular | :directory | :symlink
  @type mix_compile_stage :: %{kind: :mix_compile, profile: String.t()}
  @type mix_test_stage :: %{kind: :mix_test, paths: [String.t()]}
  @type stage :: mix_compile_stage() | mix_test_stage()
  @type budget :: %{
          compile_share_ms: non_neg_integer(),
          evidence_share_ms: non_neg_integer(),
          total_ms: non_neg_integer()
        }
  @type inventory_entry ::
          String.t()
          | {String.t(), inventory_type()}
          | %{required(:path) => String.t(), optional(:type) => inventory_type() | String.t()}
          | %{required(String.t()) => term()}

  typedstruct enforce: true do
    @typedoc "Canonical validation-program manifest."

    field(:schema_version, pos_integer())
    field(:profile, String.t())
    field(:stages, [stage()])
    field(:snapshot_digest, String.t())
    field(:budget, budget())
    field(:deadline_unix_ms, non_neg_integer())
    field(:containment_profile, String.t())
    field(:executor_version, String.t())
  end

  @doc "Return the sealed schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Return the sealed stage kinds."
  @spec stage_kinds() :: [stage_kind()]
  def stage_kinds, do: @stage_kinds

  @doc "Canonical candidate-tree digest pattern: `sha256:` plus 64 lowercase hex."
  @spec snapshot_digest_pattern() :: Regex.t()
  def snapshot_digest_pattern, do: @snapshot_digest_re

  @doc """
  Construct and validate a closed validation-program manifest.

  `inventory` is constructor-only (not stored). When `mix_test` stages are
  present, requested paths are admitted first and the inventory is indexed
  once, then reused across those stages.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs, inventory} <- normalize_constructor(attrs),
         {:ok, schema_version} <- normalize_schema_version(attrs),
         {:ok, profile} <- required_text(attrs, :profile, @max_text_bytes),
         {:ok, stages} <- normalize_stages(attrs, inventory),
         {:ok, snapshot_digest} <- required_snapshot_digest(attrs),
         {:ok, budget} <- normalize_budget(attrs),
         {:ok, deadline_unix_ms} <- required_integer(attrs, :deadline_unix_ms),
         {:ok, containment_profile} <-
           required_text(attrs, :containment_profile, @max_text_bytes),
         {:ok, executor_version} <- required_text(attrs, :executor_version, @max_text_bytes) do
      {:ok,
       %__MODULE__{
         schema_version: schema_version,
         profile: profile,
         stages: stages,
         snapshot_digest: snapshot_digest,
         budget: budget,
         deadline_unix_ms: deadline_unix_ms,
         containment_profile: containment_profile,
         executor_version: executor_version
       }}
    end
  rescue
    _ -> {:error, {:invalid_validation_program, :malformed}}
  catch
    _, _ -> {:error, {:invalid_validation_program, :malformed}}
  end

  @doc """
  Admit mix_test paths against a candidate-tree inventory.

  Inventory entries are either relative regular-file paths or typed
  `{path, type}` / `%{path, type}` records (`:regular`, `:directory`,
  `:symlink`). Directory and symlink rejection uses that type, never a
  lexical prefix of another path.

  Requested paths are validated before the inventory is scanned. The scan is
  bounded and retains only entries whose normalized path is in the requested
  set. Inventory-entry failures use `{:invalid_inventory, reason}`.
  """
  @spec admit_test_paths([term()], [inventory_entry()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def admit_test_paths(paths, inventory) when is_list(paths) and is_list(inventory) do
    with {:ok, normalized} <- normalize_requested_paths(paths),
         {:ok, index} <- inventory_index(inventory, MapSet.new(normalized)) do
      lookup_admitted_paths(normalized, index)
    end
  rescue
    _ -> {:error, {:invalid_test_path, :malformed}}
  catch
    _, _ -> {:error, {:invalid_test_path, :malformed}}
  end

  def admit_test_paths(_paths, _inventory), do: {:error, {:invalid_test_path, :expected_list}}

  @doc """
  Domain-separated, length-delimited canonical bytes.

  Prefix is `arbor-coding-validation-v1` followed by a NUL. Field order is
  fixed; map key order of the constructor input cannot change the bytes.
  """
  @spec canonical_encode(t()) :: binary()
  def canonical_encode(%__MODULE__{} = program) do
    IO.iodata_to_binary([
      @domain_prefix,
      encode_u32(program.schema_version),
      encode_string(program.profile),
      encode_u32(length(program.stages)),
      Enum.map(program.stages, &encode_stage/1),
      encode_string(program.snapshot_digest),
      encode_u64(program.budget.compile_share_ms),
      encode_u64(program.budget.evidence_share_ms),
      encode_u64(program.budget.total_ms),
      encode_u64(program.deadline_unix_ms),
      encode_string(program.containment_profile),
      encode_string(program.executor_version)
    ])
  end

  @doc "SHA-256 digest of `canonical_encode/1`, prefixed with `sha256:`."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = program) do
    @digest_prefix <>
      Base.encode16(:crypto.hash(:sha256, canonical_encode(program)), case: :lower)
  end

  @doc """
  Canonical reviewed-validation resource URI.

  The digest hex is a path segment:
  `arbor://action/coding/validate/v1/<hex>`. `parse_resource_uri/1` accepts
  only that exact spelling and rejects `#fragment`, query, trailing slash,
  and invalid UTF-8.
  """
  @spec resource_uri(t()) :: String.t()
  def resource_uri(%__MODULE__{} = program) do
    @uri_prefix <> digest_hex(digest(program))
  end

  @doc "Parse an exact path-segment resource URI and return the `sha256:` digest."
  @spec parse_resource_uri(String.t()) :: {:ok, String.t()} | {:error, term()}
  def parse_resource_uri(uri) when is_binary(uri) do
    parse_valid_resource_uri(uri)
  rescue
    _ -> {:error, {:invalid_resource_uri, :malformed}}
  catch
    _, _ -> {:error, {:invalid_resource_uri, :malformed}}
  end

  def parse_resource_uri(_uri), do: {:error, {:invalid_resource_uri, :malformed}}

  @doc """
  Human-readable manifest for the operator gate.

  Interpolates admitted struct fields (profile, stages, exact paths, counts,
  budget split, snapshot id, containment, executor). Only the digest and
  fingerprint are derived from `canonical_encode/1` via `digest/1`.
  """
  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = program) do
    paths = test_paths(program)
    digest = digest(program)

    [
      "Validation program",
      "profile: #{program.profile}",
      "stages: #{render_stage_list(program.stages)}",
      "path_count: #{length(paths)}",
      "paths:",
      Enum.map(paths, &["  ", &1]),
      "budget: compile_share_ms=#{program.budget.compile_share_ms} " <>
        "evidence_share_ms=#{program.budget.evidence_share_ms} " <>
        "total_ms=#{program.budget.total_ms}",
      "snapshot: #{program.snapshot_digest}",
      "digest: #{digest}",
      "fingerprint: #{digest_hex(digest)}",
      "containment_profile: #{program.containment_profile}",
      "executor_version: #{program.executor_version}"
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp parse_valid_resource_uri(uri) do
    with true <- String.valid?(uri),
         :ok <- reject_fragment_or_query(uri),
         {:ok, parsed} <- CapabilityUri.parse(uri),
         {:ok, hex} <- resource_hex(parsed.segments),
         true <- uri == @uri_prefix <> hex do
      {:ok, @digest_prefix <> hex}
    else
      false -> {:error, {:invalid_resource_uri, :malformed}}
      {:error, {:invalid_resource_uri, _}} = error -> error
      {:error, _reason} -> {:error, {:invalid_resource_uri, :malformed}}
      _ -> {:error, {:invalid_resource_uri, :malformed}}
    end
  end

  defp normalize_constructor(attrs) do
    with {:ok, attrs} <- normalize_object(attrs, @constructor_fields) do
      {inventory, attrs} = Map.pop(attrs, :inventory, [])
      {:ok, attrs, inventory}
    end
  end

  defp normalize_schema_version(attrs) do
    case Map.get(attrs, :schema_version, @schema_version) do
      @schema_version -> {:ok, @schema_version}
      _other -> {:error, {:invalid_field, "schema_version", :unsupported}}
    end
  end

  defp required_snapshot_digest(attrs) do
    case Map.fetch(attrs, :snapshot_digest) do
      {:ok, value} -> admit_snapshot_digest(value)
      :error -> {:error, {:missing_field, "snapshot_digest"}}
    end
  end

  defp admit_snapshot_digest(value) when is_binary(value) do
    cond do
      not String.valid?(value) ->
        {:error, {:invalid_field, "snapshot_digest", :invalid_utf8}}

      Regex.match?(@snapshot_digest_re, value) ->
        {:ok, value}

      true ->
        {:error, {:invalid_field, "snapshot_digest", :not_a_digest}}
    end
  end

  defp admit_snapshot_digest(_value),
    do: {:error, {:invalid_field, "snapshot_digest", :not_a_digest}}

  defp normalize_budget(attrs) do
    case Map.fetch(attrs, :budget) do
      {:ok, budget} -> admit_budget(budget)
      :error -> {:error, {:missing_field, "budget"}}
    end
  end

  defp admit_budget(budget) do
    with {:ok, budget} <- normalize_object(budget, @budget_fields),
         :ok <- require_keys(budget, @budget_fields, "budget"),
         {:ok, compile_share_ms} <- required_integer(budget, :compile_share_ms),
         {:ok, evidence_share_ms} <- required_integer(budget, :evidence_share_ms),
         {:ok, total_ms} <- required_integer(budget, :total_ms) do
      finish_budget(compile_share_ms, evidence_share_ms, total_ms)
    end
  end

  defp finish_budget(compile_share_ms, evidence_share_ms, total_ms) do
    if compile_share_ms + evidence_share_ms <= total_ms do
      {:ok,
       %{
         compile_share_ms: compile_share_ms,
         evidence_share_ms: evidence_share_ms,
         total_ms: total_ms
       }}
    else
      {:error, {:invalid_field, "budget", :shares_exceed_total}}
    end
  end

  defp normalize_stages(attrs, inventory) do
    case Map.fetch(attrs, :stages) do
      {:ok, stages} when is_list(stages) -> prepare_and_admit_stages(stages, inventory)
      {:ok, _stages} -> {:error, {:invalid_field, "stages", :expected_list}}
      :error -> {:error, {:missing_field, "stages"}}
    end
  end

  defp prepare_and_admit_stages(stages, inventory) do
    with {:ok, prepared} <- collect_prepared_stages(stages, 0, []),
         {:ok, index} <- inventory_index_for_stages(prepared, inventory) do
      admit_prepared_stages(prepared, index, [])
    end
  end

  defp collect_prepared_stages([], _index, acc), do: {:ok, Enum.reverse(acc)}

  defp collect_prepared_stages(_stages, index, _acc) when index >= @max_stages,
    do: {:error, {:invalid_field, "stages", :list_too_large}}

  defp collect_prepared_stages([stage | rest], index, acc) do
    with {:ok, prepared} <- prepare_stage(stage) do
      collect_prepared_stages(rest, index + 1, [prepared | acc])
    end
  end

  defp collect_prepared_stages(_improper, _index, _acc),
    do: {:error, {:invalid_field, "stages", :improper_list}}

  defp prepare_stage(stage) do
    with {:ok, kind, params} <- split_stage(stage),
         {:ok, kind} <- canonicalize_stage_kind(kind) do
      prepare_stage_kind(kind, params)
    end
  end

  defp prepare_stage_kind(:mix_compile, params), do: admit_mix_compile(params)

  defp prepare_stage_kind(:mix_test, params) do
    with {:ok, params} <- normalize_object(params, [:paths]),
         {:ok, paths} <- fetch_mix_test_paths(params),
         {:ok, normalized} <- normalize_requested_paths(paths) do
      {:ok, %{kind: :mix_test, paths: normalized}}
    end
  end

  defp inventory_index_for_stages(prepared, inventory) do
    requested =
      prepared
      |> Enum.flat_map(fn
        %{kind: :mix_test, paths: paths} -> paths
        _stage -> []
      end)
      |> MapSet.new()

    if MapSet.size(requested) == 0 do
      {:ok, %{}}
    else
      inventory_index(inventory, requested)
    end
  end

  defp admit_prepared_stages([], _index, acc), do: {:ok, Enum.reverse(acc)}

  defp admit_prepared_stages([%{kind: :mix_compile} = stage | rest], index, acc) do
    admit_prepared_stages(rest, index, [stage | acc])
  end

  defp admit_prepared_stages([%{kind: :mix_test, paths: paths} | rest], index, acc) do
    with {:ok, admitted} <- lookup_admitted_paths(paths, index) do
      admit_prepared_stages(rest, index, [%{kind: :mix_test, paths: admitted} | acc])
    end
  end

  defp split_stage(%{kind: kind} = stage), do: {:ok, kind, Map.delete(stage, :kind)}
  defp split_stage(%{"kind" => kind} = stage), do: {:ok, kind, Map.delete(stage, "kind")}
  defp split_stage({kind, params}), do: {:ok, kind, params}
  defp split_stage(_stage), do: {:error, {:invalid_field, "stages", :unknown_stage}}

  defp canonicalize_stage_kind(kind) when kind in @stage_kinds, do: {:ok, kind}
  defp canonicalize_stage_kind("mix_compile"), do: {:ok, :mix_compile}
  defp canonicalize_stage_kind("mix_test"), do: {:ok, :mix_test}
  defp canonicalize_stage_kind(_kind), do: {:error, {:invalid_field, "stages", :unknown_stage}}

  defp admit_mix_compile(params) do
    with {:ok, params} <- normalize_object(params, [:profile]),
         {:ok, profile} <- required_text(params, :profile, @max_text_bytes) do
      {:ok, %{kind: :mix_compile, profile: profile}}
    end
  end

  defp fetch_mix_test_paths(params) do
    case Map.fetch(params, :paths) do
      {:ok, []} -> {:error, {:invalid_field, "stages", :empty_mix_test_paths}}
      {:ok, paths} when is_list(paths) -> {:ok, paths}
      {:ok, _paths} -> {:error, {:invalid_field, "stages", :expected_list}}
      :error -> {:error, {:invalid_field, "stages", :empty_mix_test_paths}}
    end
  end

  defp normalize_requested_paths(paths) do
    if length(paths) > @max_test_paths do
      {:error, {:invalid_test_path, :list_too_large}}
    else
      collect_requested_paths(paths, [], MapSet.new())
    end
  end

  defp collect_requested_paths([], acc, _seen), do: {:ok, Enum.reverse(acc)}

  defp collect_requested_paths([path | rest], acc, seen) do
    with {:ok, path} <- normalize_test_path(path) do
      collect_unique_path(path, rest, acc, seen)
    end
  end

  defp collect_requested_paths(_improper, _acc, _seen),
    do: {:error, {:invalid_test_path, :improper_list}}

  defp collect_unique_path(path, rest, acc, seen) do
    if MapSet.member?(seen, path) do
      {:error, {:invalid_test_path, :duplicate}}
    else
      collect_requested_paths(rest, [path | acc], MapSet.put(seen, path))
    end
  end

  defp lookup_admitted_paths(paths, index) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case Map.fetch(index, path) do
        {:ok, :regular} -> {:cont, {:ok, [path | acc]}}
        {:ok, :directory} -> {:halt, {:error, {:invalid_test_path, :directory}}}
        {:ok, :symlink} -> {:halt, {:error, {:invalid_test_path, :symlink}}}
        :error -> {:halt, {:error, {:invalid_test_path, :not_in_inventory}}}
      end
    end)
    |> finish_admitted_paths()
  end

  defp finish_admitted_paths({:ok, acc}), do: {:ok, acc |> Enum.reverse() |> Enum.sort()}
  defp finish_admitted_paths({:error, _reason} = error), do: error

  defp inventory_index(entries, requested) do
    with {:ok, entries} <- take_inventory_entries(entries) do
      reduce_inventory(entries, requested, %{})
    end
  end

  defp take_inventory_entries(entries) when is_list(entries) do
    taken = Enum.take(entries, @max_inventory_entries + 1)

    if length(taken) > @max_inventory_entries do
      {:error, {:invalid_inventory, :list_too_large}}
    else
      {:ok, taken}
    end
  end

  defp take_inventory_entries(_entries), do: {:error, {:invalid_inventory, :expected_list}}

  defp reduce_inventory([], _requested, acc), do: {:ok, acc}

  defp reduce_inventory([entry | rest], requested, acc) do
    case inventory_entry(entry) do
      {:ok, path, type} ->
        merge_requested_entry(path, type, rest, requested, acc)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp merge_requested_entry(path, type, rest, requested, acc) do
    if MapSet.member?(requested, path) do
      case merge_inventory_type(acc, path, type) do
        {:ok, acc} -> reduce_inventory(rest, requested, acc)
        {:error, reason} -> {:error, reason}
      end
    else
      reduce_inventory(rest, requested, acc)
    end
  end

  defp merge_inventory_type(acc, path, type) do
    case Map.fetch(acc, path) do
      :error -> {:ok, Map.put(acc, path, type)}
      {:ok, ^type} -> {:ok, acc}
      {:ok, _other} -> {:error, {:invalid_inventory, :type_conflict}}
    end
  end

  defp inventory_entry(path) when is_binary(path) do
    with {:ok, path} <- normalize_relative_path(path, :invalid_inventory) do
      {:ok, path, :regular}
    end
  end

  defp inventory_entry({path, type}) do
    with {:ok, path} <- normalize_relative_path(path, :invalid_inventory),
         {:ok, type} <- inventory_type(type) do
      {:ok, path, type}
    end
  end

  defp inventory_entry(%{} = entry) do
    with {:ok, path} <- fetch_inventory_path(entry),
         {:ok, path} <- normalize_relative_path(path, :invalid_inventory),
         {:ok, type} <- inventory_type(Map.get(entry, :type, Map.get(entry, "type", :regular))) do
      {:ok, path, type}
    end
  end

  defp inventory_entry(_entry), do: {:error, {:invalid_inventory, :entry}}

  defp fetch_inventory_path(%{path: path}), do: {:ok, path}
  defp fetch_inventory_path(%{"path" => path}), do: {:ok, path}
  defp fetch_inventory_path(_entry), do: {:error, {:invalid_inventory, :entry}}

  defp inventory_type(type) when type in @inventory_types, do: {:ok, type}
  defp inventory_type("regular"), do: {:ok, :regular}
  defp inventory_type("directory"), do: {:ok, :directory}
  defp inventory_type("symlink"), do: {:ok, :symlink}
  defp inventory_type(_type), do: {:error, {:invalid_inventory, :type}}

  defp normalize_test_path(path) do
    with {:ok, path} <- normalize_relative_path(path, :invalid_test_path) do
      if String.ends_with?(path, "_test.exs") do
        {:ok, path}
      else
        {:error, {:invalid_test_path, :not_test_exs}}
      end
    end
  end

  defp normalize_relative_path(path, tag) when is_binary(path) do
    cond do
      byte_size(path) == 0 ->
        {:error, {tag, :empty_path}}

      # Bound the input before any per-codepoint scan so an oversized path is
      # refused in O(1) instead of being converted to a charlist first.
      byte_size(path) > @max_path_bytes ->
        {:error, {tag, :path_too_long}}

      not String.valid?(path) ->
        {:error, {tag, :invalid_utf8}}

      unsafe_display?(path) ->
        display_path_reason(path, tag)

      true ->
        path
        |> String.replace("\\", "/")
        |> String.normalize(:nfc)
        |> validate_relative_components(tag)
    end
  end

  defp normalize_relative_path(_path, tag), do: {:error, {tag, :expected_string}}

  defp display_path_reason(path, tag) do
    if :binary.match(path, <<0>>) != :nomatch do
      {:error, {tag, :nul}}
    else
      {:error, {tag, :control_character}}
    end
  end

  defp validate_relative_components(path, tag) do
    segments = :binary.split(path, <<"/">>, [:global])

    cond do
      absolute_path?(path) ->
        {:error, {tag, :absolute}}

      segments == [] ->
        {:error, {tag, :empty_path}}

      length(segments) > @max_path_depth ->
        {:error, {tag, :path_depth}}

      Enum.any?(segments, &forbidden_component?/1) ->
        component_reason(segments, tag)

      true ->
        {:ok, path}
    end
  end

  defp forbidden_component?(segment) do
    segment == <<>> or segment == <<".">> or segment == <<"..">> or
      String.starts_with?(segment, "-") or byte_size(segment) > @max_component_bytes
  end

  defp component_reason(segments, tag) do
    cond do
      ".." in segments ->
        {:error, {tag, :dot_dot}}

      Enum.any?(segments, &String.starts_with?(&1, "-")) ->
        {:error, {tag, :leading_dash}}

      Enum.any?(segments, &(&1 == <<".">>)) ->
        {:error, {tag, :dot_component}}

      Enum.any?(segments, &(byte_size(&1) > @max_component_bytes)) ->
        {:error, {tag, :component_too_long}}

      true ->
        {:error, {tag, :empty_component}}
    end
  end

  defp absolute_path?(path) do
    String.starts_with?(path, "/") or Regex.match?(@drive_letter_re, path) or
      Path.type(path) == :absolute
  end

  defp required_text(attrs, field, maximum) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> admit_text(value, Atom.to_string(field), maximum)
      :error -> {:error, {:missing_field, Atom.to_string(field)}}
    end
  end

  defp admit_text(value, field, maximum) when is_binary(value) do
    cond do
      not String.valid?(value) ->
        {:error, {:invalid_field, field, :invalid_utf8}}

      byte_size(value) == 0 or String.trim(value) == "" ->
        {:error, {:invalid_field, field, :blank}}

      byte_size(value) > maximum ->
        {:error, {:invalid_field, field, :text_too_large}}

      unsafe_display?(value) ->
        {:error, {:invalid_field, field, :control_character}}

      true ->
        {:ok, value}
    end
  end

  defp admit_text(_value, field, _maximum),
    do: {:error, {:invalid_field, field, :expected_string}}

  defp unsafe_display?(value) do
    String.match?(value, @c0_del_re) or unsafe_unicode_display?(value)
  end

  defp unsafe_unicode_display?(value) do
    value
    |> String.to_charlist()
    |> Enum.any?(&unsafe_codepoint?/1)
  end

  defp unsafe_codepoint?(codepoint) when codepoint <= 0x1F, do: true
  defp unsafe_codepoint?(0x7F), do: true
  defp unsafe_codepoint?(codepoint) when codepoint in 0x80..0x9F, do: true
  defp unsafe_codepoint?(codepoint) when codepoint in 0x200B..0x200F, do: true
  defp unsafe_codepoint?(codepoint) when codepoint in 0x202A..0x202E, do: true
  defp unsafe_codepoint?(0x2028), do: true
  defp unsafe_codepoint?(0x2029), do: true
  defp unsafe_codepoint?(codepoint) when codepoint in 0x2066..0x2069, do: true
  defp unsafe_codepoint?(_codepoint), do: false

  defp required_integer(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} when is_integer(value) and value >= 0 and value <= @max_json_safe_integer ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, Atom.to_string(field), :expected_integer}}

      :error ->
        {:error, {:missing_field, Atom.to_string(field)}}
    end
  end

  defp require_keys(map, fields, label) do
    missing = fields |> Enum.reject(&Map.has_key?(map, &1)) |> Enum.map(&Atom.to_string/1)

    if missing == [], do: :ok, else: {:error, {:missing_field, label <> "." <> hd(missing)}}
  end

  defp normalize_object(attrs, allowed) when is_map(attrs) do
    cond do
      is_struct(attrs) ->
        {:error, {:invalid_validation_program, :struct_not_allowed}}

      map_size(attrs) > length(allowed) ->
        {:error, {:invalid_validation_program, :object_too_large}}

      true ->
        normalize_entries(Map.to_list(attrs), allowed)
    end
  end

  defp normalize_object(attrs, allowed) when is_list(attrs) do
    entries = Enum.take(attrs, length(allowed) + 1)

    cond do
      length(entries) > length(allowed) ->
        {:error, {:invalid_validation_program, :object_too_large}}

      Enum.all?(entries, &match?({_, _}, &1)) ->
        normalize_entries(entries, allowed)

      true ->
        {:error, {:invalid_validation_program, :object_required}}
    end
  end

  defp normalize_object(_attrs, _allowed),
    do: {:error, {:invalid_validation_program, :object_required}}

  defp normalize_entries(entries, allowed) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      case canonical_key(key, allowed) do
        {:ok, canonical} when not is_map_key(normalized, canonical) ->
          {:cont, {:ok, Map.put(normalized, canonical, value)}}

        {:ok, _canonical} ->
          {:halt, {:error, {:invalid_validation_program, :duplicate_field}}}

        :error ->
          {:halt, {:error, {:invalid_validation_program, :unknown_field}}}
      end
    end)
  end

  defp canonical_key(key, allowed) when is_atom(key) do
    if key in allowed, do: {:ok, key}, else: :error
  end

  defp canonical_key(key, allowed) when is_binary(key) do
    Enum.find_value(allowed, :error, fn field ->
      if Atom.to_string(field) == key, do: {:ok, field}
    end)
  end

  defp canonical_key(_key, _allowed), do: :error

  defp encode_stage(%{kind: :mix_compile, profile: profile}) do
    [encode_string("mix_compile"), encode_string(profile)]
  end

  defp encode_stage(%{kind: :mix_test, paths: paths}) do
    [encode_string("mix_test"), encode_u32(length(paths)), Enum.map(paths, &encode_string/1)]
  end

  defp encode_string(value) when is_binary(value) do
    [<<byte_size(value)::unsigned-big-32>>, value]
  end

  defp encode_u32(value) when is_integer(value) and value >= 0 do
    <<value::unsigned-big-32>>
  end

  defp encode_u64(value) when is_integer(value) and value >= 0 do
    <<value::unsigned-big-64>>
  end

  defp reject_fragment_or_query(uri) do
    if String.contains?(uri, ["#", "?"]),
      do: {:error, {:invalid_resource_uri, :fragment}},
      else: :ok
  end

  defp resource_hex(["action", "coding", "validate", "v1", hex]) do
    if Regex.match?(@hex64_re, hex),
      do: {:ok, hex},
      else: {:error, {:invalid_resource_uri, :malformed}}
  end

  defp resource_hex(_segments), do: {:error, {:invalid_resource_uri, :malformed}}

  defp digest_hex(@digest_prefix <> hex), do: hex

  defp test_paths(%__MODULE__{stages: stages}) do
    Enum.flat_map(stages, fn
      %{kind: :mix_test, paths: paths} -> paths
      _stage -> []
    end)
  end

  defp render_stage_list(stages), do: Enum.map_join(stages, ", ", &render_stage/1)

  defp render_stage(%{kind: :mix_compile, profile: profile}),
    do: "mix_compile(profile=#{profile})"

  defp render_stage(%{kind: :mix_test, paths: paths}),
    do: "mix_test(paths=#{length(paths)})"
end
