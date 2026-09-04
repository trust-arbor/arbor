defmodule Arbor.Contracts.Coding.ForgeProjection do
  @moduledoc """
  Closed-schema v1 forge projection: the signed, free-text-free summary of a
  reviewed coding candidate that packet 1c publishes as a pull-request body.

  A projection carries only enums, digests, counts and refs. Every outbound
  field is validated against this schema before anything is rendered or
  signed; there is no path that emits or signs an unvalidated value.

  ## Producers and the single validation core

  `build/1` (from adapted terminal data) and `parse/2` (from a rendered
  document plus the signing context) are the only producers of a projection.
  Both run `validate_fields/1`. Elixir cannot forbid constructing a struct
  literal from another module, so `render/2`, `canonical_v1/1` and
  `body_bytes/1` **re-validate the struct they are given** through the same
  core: a struct that would not pass `build/1` cannot be rendered, signed or
  hashed. That is the guarantee — invalid projection data is unrepresentable
  at every effectful entry — and it does not depend on a flag or seal.

  ## Wire format

      arbor-projection: v1 task=<task> cycle=<n> ledger=<sha256:hex> candidate=<40hex>
      {"candidate":...,"cycle":...,...}          # compact JSON, keys sorted
      <!-- arbor-sig v1 key=<key_id> sig=<base64 of 64-byte Ed25519> -->

  `body_without_footer/2` (`header <> "\\n" <> json`, no trailing newline) is
  the single source of the signed bytes; `render/2` emits exactly those bytes
  followed by `"\\n"` and the footer, and `parse_document/1` recovers exactly
  those bytes. The header and the JSON body must agree on `task`, `cycle`,
  `ledger_digest` and `candidate`; the footer `key_id` must equal the body
  `key_id`.

  ## Signing context

  `factory_id`, `forge_host`, `project` and `poster_agent_id` are signed but are
  deliberately **not** in the body: a verifier supplies them (from host config,
  the PR URL, or CLI flags) so a body copied to another forge or project does
  not verify. `parse_document/1` therefore yields the body fields, the footer
  key and signature; `parse/2` adds the signing context and returns a full
  projection.

  ## Canonical signing input

  `canonical_v1/1` concatenates 32-bit big-endian length-prefixed UTF-8 fields
  in this order: the domain tag `#{"arbor-forge-projection-v1"}`, `factory_id`,
  `forge_host`, `project`, `task`, `cycle` (decimal), `ledger_digest`,
  `candidate`, `poster_agent_id`, `key_id`, and the lowercase hex SHA-256 of
  `body_without_footer`. The domain tag is the first field so the signing
  authority can require it before signing (`Arbor.Security.sign_detached_with_authority/3`).
  """

  alias Arbor.Contracts.Security.SigningAuthority.Validator

  @schema "arbor-forge-projection-v1"
  @domain_tag "arbor-forge-projection-v1"

  @max_task_bytes 256
  @max_cycle 4096
  @max_evidence_ref_bytes 256
  @max_context_bytes 256
  @max_document_bytes 65_536

  @vote_keys ~w(approve reject abstain failed reported)
  @finding_keys ~w(blocking major minor nit)
  @verdicts ~w(auto_proceed human_review reject)
  @dispositions ~w(succeeded failed cancelled)

  # The routing reasons the code-review council actually emits
  # (Arbor.Actions.Council.BlastRadius classification + route reasons and the
  # ledger's human-required reason). Unknown values are dropped by callers
  # that filter and rejected here.
  @tier_reasons ~w(
    human_review_required
    security_veto
    ledger_human_required
    security_app
    trust_app
    contracts_app
    dot_engine
    coding_agent_manifest
    code_reviewer_manifest
    council_evaluator_manifest
    code_review_council_dot
    code_review_action_gate
    tiering_policy
    security_authority_surface
    trust_authority_surface
    security_contract_surface
  )

  # Council review dispositions that map onto a projection verdict. Anything
  # else is not a verdict and must fail, never be coerced.
  @verdict_from_disposition %{
    "accept" => "auto_proceed",
    "auto_proceed" => "auto_proceed",
    "human_review" => "human_review",
    "reject" => "reject"
  }

  @body_keys ~w(
    candidate cycle disposition evidence_ref finding_counts key_id ledger_digest
    reviewed_commit schema task tier_reasons verdict vote_counts
  )

  @header_pattern ~r/\Aarbor-projection: v1 task=(?<task>[^ =\n]+) cycle=(?<cycle>[0-9]{1,4}) ledger=(?<ledger>sha256:[0-9a-f]{64}) candidate=(?<candidate>[0-9a-f]{40})\z/
  @footer_pattern ~r/\A<!-- arbor-sig v1 key=(?<key_id>[^ \n]+) sig=(?<sig>[A-Za-z0-9+\/]+={0,2}) -->\z/

  @body_fields ~w(task cycle verdict disposition vote_counts tier_reasons finding_counts reviewed_commit candidate ledger_digest evidence_ref key_id)
  @context_fields ~w(factory_id forge_host project poster_agent_id)

  defstruct [
    :task,
    :cycle,
    :verdict,
    :disposition,
    :vote_counts,
    :tier_reasons,
    :finding_counts,
    :reviewed_commit,
    :candidate,
    :ledger_digest,
    :evidence_ref,
    :key_id,
    :factory_id,
    :forge_host,
    :project,
    :poster_agent_id
  ]

  @typedoc "A validated projection. Produced only by `build/1` and `parse/2`."
  @opaque t :: %__MODULE__{
            task: String.t(),
            cycle: non_neg_integer(),
            verdict: String.t(),
            disposition: String.t(),
            vote_counts: %{String.t() => non_neg_integer()},
            tier_reasons: [String.t()],
            finding_counts: %{String.t() => non_neg_integer()},
            reviewed_commit: String.t(),
            candidate: String.t(),
            ledger_digest: String.t(),
            evidence_ref: String.t(),
            key_id: String.t(),
            factory_id: String.t(),
            forge_host: String.t(),
            project: String.t(),
            poster_agent_id: String.t()
          }

  @typedoc """
  The signing context a verifier supplies to `parse/2`: string-keyed map with
  exactly `factory_id`, `forge_host`, `project` and `poster_agent_id`.
  """
  @type signing_context :: %{String.t() => String.t()}

  @typedoc """
  A parsed document before the signing context is known:
  the validated body fields (string-keyed, including `key_id`), the footer
  `key_id`, the 64-byte `signature`, and the exact `body_without_footer` bytes.
  """
  @type document :: %{
          fields: %{String.t() => term()},
          key_id: String.t(),
          signature: binary(),
          body_without_footer: binary()
        }

  @doc "The closed body schema identifier."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "The domain tag that starts every canonical signing message."
  @spec domain_tag() :: String.t()
  def domain_tag, do: @domain_tag

  @doc "Closed vote-count keys."
  @spec vote_keys() :: [String.t()]
  def vote_keys, do: @vote_keys

  @doc "Closed finding-count keys."
  @spec finding_keys() :: [String.t()]
  def finding_keys, do: @finding_keys

  @doc "Closed verdict enum."
  @spec verdicts() :: [String.t()]
  def verdicts, do: @verdicts

  @doc "Closed disposition enum."
  @spec dispositions() :: [String.t()]
  def dispositions, do: @dispositions

  @doc "Closed tier-reason enum (the council's routing reasons)."
  @spec tier_reasons() :: [String.t()]
  def tier_reasons, do: @tier_reasons

  @doc "The JSON body keys, sorted; nothing else may appear in a body."
  @spec body_keys() :: [String.t()]
  def body_keys, do: @body_keys

  @doc """
  Map a council review disposition onto a projection verdict. Unknown
  dispositions are an error, never a default.
  """
  @spec verdict_from_review_disposition(term()) ::
          {:ok, String.t()} | {:error, :projection_invalid}
  def verdict_from_review_disposition(disposition) when is_binary(disposition) do
    case Map.fetch(@verdict_from_disposition, disposition) do
      {:ok, verdict} -> {:ok, verdict}
      :error -> {:error, :projection_invalid}
    end
  end

  def verdict_from_review_disposition(_), do: {:error, :projection_invalid}

  @doc """
  Keep the known tier reasons from a source list. Unknown entries are
  dropped; a non-empty source with no known entry is invalid.
  """
  @spec filter_tier_reasons(term()) :: {:ok, [String.t()]} | {:error, :projection_invalid}
  def filter_tier_reasons(list) when is_list(list) do
    known = list |> Enum.filter(&(is_binary(&1) and &1 in @tier_reasons)) |> Enum.uniq()

    if list != [] and known == [] do
      {:error, :projection_invalid}
    else
      {:ok, Enum.sort(known)}
    end
  end

  def filter_tier_reasons(_), do: {:error, :projection_invalid}

  @doc """
  Validate every outbound field and return a projection.

  `attrs` is a string-keyed map with exactly the body fields and the signing
  context; unknown keys and atom/string aliases of the same key are rejected.
  """
  @spec build(term()) :: {:ok, t()} | {:error, :projection_invalid}
  def build(attrs) when is_map(attrs) and not is_struct(attrs) do
    with {:ok, attrs} <- closed_input(attrs, @body_fields ++ @context_fields) do
      validate_fields(attrs)
    end
  end

  def build(_), do: {:error, :projection_invalid}

  @doc """
  Split and validate a rendered document without a signing context.

  Checks the header grammar, the closed body schema, header/body equality on
  `task`, `cycle`, `ledger_digest` and `candidate`, the footer grammar, a
  64-byte signature, and footer/body `key_id` equality. Returns the exact
  signed bytes so a verifier can hash them.
  """
  @spec parse_document(term()) :: {:ok, document()} | {:error, :projection_invalid}
  def parse_document(document)
      when is_binary(document) and byte_size(document) <= @max_document_bytes do
    with {:ok, header, json, footer} <- split_document(document),
         {:ok, header_fields} <- parse_header(header),
         {:ok, body} <- decode_body(json),
         :ok <- header_matches_body(header_fields, body),
         {:ok, key_id, signature} <- parse_footer(footer),
         :ok <- footer_matches_body(key_id, body),
         {:ok, fields} <- validate_body_fields(body) do
      {:ok,
       %{
         fields: fields,
         key_id: key_id,
         signature: signature,
         body_without_footer: body_without_footer(header, json)
       }}
    end
  end

  def parse_document(_), do: {:error, :projection_invalid}

  @doc """
  Parse a rendered document and bind it to the signing context, returning a
  projection whose `canonical_v1/1` reproduces the message that was signed.
  """
  @spec parse(term(), term()) :: {:ok, t()} | {:error, :projection_invalid}
  def parse(document, signing_context)
      when is_binary(document) and is_map(signing_context) and not is_struct(signing_context) do
    with {:ok, parsed} <- parse_document(document),
         {:ok, context} <- closed_input(signing_context, @context_fields),
         {:ok, projection} <- validate_fields(Map.merge(parsed.fields, context)),
         # The rendered body of the validated projection must be byte-identical
         # to what was parsed, or the document is not a v1 projection.
         {:ok, bytes} <- body_bytes(projection),
         true <- bytes == parsed.body_without_footer do
      {:ok, projection}
    else
      _ -> {:error, :projection_invalid}
    end
  end

  def parse(_document, _signing_context), do: {:error, :projection_invalid}

  @doc """
  Render a projection with a detached signature footer. Re-validates the
  projection; a struct that would not pass `build/1` is not rendered.
  """
  @spec render(term(), term()) :: {:ok, binary()} | {:error, :projection_invalid}
  def render(%__MODULE__{} = projection, signature)
      when is_binary(signature) and byte_size(signature) == 64 do
    with {:ok, projection} <- revalidate(projection) do
      header = header_line(projection)
      json = encode_body(projection)

      {:ok,
       body_without_footer(header, json) <> "\n" <> footer_line(projection.key_id, signature)}
    end
  end

  def render(_projection, _signature), do: {:error, :projection_invalid}

  @doc """
  The exact signed bytes of a projection (`header <> "\\n" <> json`).
  Re-validates the projection.
  """
  @spec body_bytes(term()) :: {:ok, binary()} | {:error, :projection_invalid}
  def body_bytes(%__MODULE__{} = projection) do
    with {:ok, projection} <- revalidate(projection) do
      {:ok, body_without_footer(header_line(projection), encode_body(projection))}
    end
  end

  def body_bytes(_), do: {:error, :projection_invalid}

  @doc """
  The length-prefixed canonical signing message for a projection.
  Re-validates the projection.
  """
  @spec canonical_v1(term()) :: {:ok, binary()} | {:error, :projection_invalid}
  def canonical_v1(%__MODULE__{} = projection) do
    with {:ok, projection} <- revalidate(projection),
         {:ok, body} <- body_bytes(projection) do
      body_sha = Base.encode16(:crypto.hash(:sha256, body), case: :lower)

      message =
        [
          @domain_tag,
          projection.factory_id,
          projection.forge_host,
          projection.project,
          projection.task,
          Integer.to_string(projection.cycle),
          projection.ledger_digest,
          projection.candidate,
          projection.poster_agent_id,
          projection.key_id,
          body_sha
        ]
        |> Enum.map(&length_prefix/1)
        |> IO.iodata_to_binary()

      {:ok, message}
    end
  end

  def canonical_v1(_), do: {:error, :projection_invalid}

  @doc "The signed bytes for a header line and a JSON body: `header <> \"\\n\" <> json`."
  @spec body_without_footer(String.t(), String.t()) :: binary()
  def body_without_footer(header, json) when is_binary(header) and is_binary(json),
    do: header <> "\n" <> json

  # --- validation core ------------------------------------------------------

  defp revalidate(%__MODULE__{} = projection) do
    projection
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> validate_fields()
  end

  defp validate_fields(attrs) when is_map(attrs) do
    with {:ok, task} <- validate_task(Map.get(attrs, "task")),
         {:ok, cycle} <- validate_cycle(Map.get(attrs, "cycle")),
         {:ok, verdict} <- validate_enum(Map.get(attrs, "verdict"), @verdicts),
         {:ok, disposition} <- validate_enum(Map.get(attrs, "disposition"), @dispositions),
         {:ok, vote_counts} <- validate_counts(Map.get(attrs, "vote_counts"), @vote_keys),
         {:ok, tier_reasons} <- validate_tier_reasons(Map.get(attrs, "tier_reasons")),
         {:ok, finding_counts} <- validate_counts(Map.get(attrs, "finding_counts"), @finding_keys),
         {:ok, reviewed_commit} <- validate_git_oid(Map.get(attrs, "reviewed_commit")),
         {:ok, candidate} <- validate_git_oid(Map.get(attrs, "candidate")),
         {:ok, ledger_digest} <- validate_ledger_digest(Map.get(attrs, "ledger_digest")),
         {:ok, evidence_ref} <- validate_evidence_ref(Map.get(attrs, "evidence_ref")),
         {:ok, key_id} <- validate_agent_id(Map.get(attrs, "key_id")),
         {:ok, factory_id} <- validate_factory_id(Map.get(attrs, "factory_id")),
         {:ok, forge_host} <- validate_host(Map.get(attrs, "forge_host")),
         {:ok, project} <- validate_project(Map.get(attrs, "project")),
         {:ok, poster_agent_id} <- validate_agent_id(Map.get(attrs, "poster_agent_id")) do
      {:ok,
       %__MODULE__{
         task: task,
         cycle: cycle,
         verdict: verdict,
         disposition: disposition,
         vote_counts: vote_counts,
         tier_reasons: tier_reasons,
         finding_counts: finding_counts,
         reviewed_commit: reviewed_commit,
         candidate: candidate,
         ledger_digest: ledger_digest,
         evidence_ref: evidence_ref,
         key_id: key_id,
         factory_id: factory_id,
         forge_host: forge_host,
         project: project,
         poster_agent_id: poster_agent_id
       }}
    else
      _ -> {:error, :projection_invalid}
    end
  end

  # Body-only validation for parse_document/1 (no signing context yet).
  defp validate_body_fields(body) do
    probe =
      Map.merge(body, %{
        "factory_id" => "probe",
        "forge_host" => "probe.invalid",
        "project" => "probe/probe",
        "poster_agent_id" => Map.get(body, "key_id")
      })

    with {:ok, projection} <- validate_fields(probe) do
      fields =
        projection
        |> Map.from_struct()
        |> Map.drop([:factory_id, :forge_host, :project, :poster_agent_id])
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

      {:ok, fields}
    end
  end

  # Closed input: string keys only, exactly the allowed set, no atom/string
  # aliases of the same key (an atom key is rejected outright).
  defp closed_input(map, allowed) do
    keys = Map.keys(map)

    cond do
      Enum.any?(keys, &(not is_binary(&1))) -> {:error, :projection_invalid}
      Enum.sort(keys) != Enum.sort(allowed) -> {:error, :projection_invalid}
      true -> {:ok, map}
    end
  end

  defp validate_task(task) when is_binary(task) do
    if String.valid?(task) and byte_size(task) in 1..@max_task_bytes and
         Regex.match?(~r/\Atask_[A-Za-z0-9._-]+\z/, task) and not secret_shaped?(task),
       do: {:ok, task},
       else: {:error, :projection_invalid}
  end

  defp validate_task(_), do: {:error, :projection_invalid}

  defp validate_cycle(value) when is_integer(value) and value >= 0 and value <= @max_cycle,
    do: {:ok, value}

  defp validate_cycle(_), do: {:error, :projection_invalid}

  defp validate_enum(value, allowed) when is_binary(value) do
    if value in allowed, do: {:ok, value}, else: {:error, :projection_invalid}
  end

  defp validate_enum(_value, _allowed), do: {:error, :projection_invalid}

  defp validate_counts(map, keys) when is_map(map) and not is_struct(map) do
    if Enum.sort(Map.keys(map)) == Enum.sort(keys) and
         Enum.all?(map, fn {_key, value} -> is_integer(value) and value >= 0 end),
       do: {:ok, map},
       else: {:error, :projection_invalid}
  end

  defp validate_counts(_map, _keys), do: {:error, :projection_invalid}

  # Outbound tier reasons are already filtered (filter_tier_reasons/1); here
  # every element must be a known reason, sorted and unique.
  defp validate_tier_reasons(list) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and &1 in @tier_reasons)) and
         list == list |> Enum.uniq() |> Enum.sort(),
       do: {:ok, list},
       else: {:error, :projection_invalid}
  end

  defp validate_tier_reasons(_), do: {:error, :projection_invalid}

  defp validate_git_oid(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, value),
      do: {:ok, value},
      else: {:error, :projection_invalid}
  end

  defp validate_git_oid(_), do: {:error, :projection_invalid}

  defp validate_ledger_digest(value) when is_binary(value) do
    if Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, value),
      do: {:ok, value},
      else: {:error, :projection_invalid}
  end

  defp validate_ledger_digest(_), do: {:error, :projection_invalid}

  defp validate_evidence_ref(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) in 1..@max_evidence_ref_bytes and
         Regex.match?(~r/\A[A-Za-z0-9_.\/:-]+\z/, value) and
         not String.contains?(value, "..") and not secret_shaped?(value),
       do: {:ok, value},
       else: {:error, :projection_invalid}
  end

  defp validate_evidence_ref(_), do: {:error, :projection_invalid}

  defp validate_agent_id(value) when is_binary(value) do
    case Validator.validate_principal_id(value) do
      :ok -> {:ok, value}
      {:error, _} -> {:error, :projection_invalid}
    end
  end

  defp validate_agent_id(_), do: {:error, :projection_invalid}

  defp validate_factory_id(value) when is_binary(value) do
    if byte_size(value) <= @max_context_bytes and
         Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,127}\z/, value) and not secret_shaped?(value),
       do: {:ok, value},
       else: {:error, :projection_invalid}
  end

  defp validate_factory_id(_), do: {:error, :projection_invalid}

  # Hostname: DNS labels, optional port.
  defp validate_host(value) when is_binary(value) do
    if byte_size(value) <= @max_context_bytes and
         Regex.match?(
           ~r/\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*(:[0-9]{1,5})?\z/,
           value
         ) and not secret_shaped?(value),
       do: {:ok, value},
       else: {:error, :projection_invalid}
  end

  defp validate_host(_), do: {:error, :projection_invalid}

  defp validate_project(value) when is_binary(value) do
    if byte_size(value) <= @max_context_bytes and
         Regex.match?(~r/\A[A-Za-z0-9._-]+(\/[A-Za-z0-9._-]+){1,3}\z/, value) and
         not String.contains?(value, "..") and not secret_shaped?(value),
       do: {:ok, value},
       else: {:error, :projection_invalid}
  end

  defp validate_project(_), do: {:error, :projection_invalid}

  # Value-shaped secrets only; never applied to digest or commit fields, which
  # have their own exact grammars.
  defp secret_shaped?(value) when is_binary(value) do
    Regex.match?(~r/\Aghp_[A-Za-z0-9]{20,}\z/, value) or
      String.starts_with?(value, "github_pat_") or
      String.starts_with?(value, "glpat-") or
      String.starts_with?(value, "Bearer ") or
      Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, value) or
      https_userinfo?(value)
  end

  defp https_userinfo?(value) do
    match?(
      %URI{scheme: "https", userinfo: userinfo} when is_binary(userinfo) and userinfo != "",
      URI.parse(value)
    )
  end

  # --- wire format ----------------------------------------------------------

  defp header_line(%__MODULE__{} = p) do
    "arbor-projection: v1 task=#{p.task} cycle=#{p.cycle} ledger=#{p.ledger_digest} candidate=#{p.candidate}"
  end

  defp encode_body(%__MODULE__{} = p) do
    %{
      "schema" => @schema,
      "task" => p.task,
      "cycle" => p.cycle,
      "verdict" => p.verdict,
      "disposition" => p.disposition,
      "vote_counts" => p.vote_counts,
      "tier_reasons" => p.tier_reasons,
      "finding_counts" => p.finding_counts,
      "reviewed_commit" => p.reviewed_commit,
      "candidate" => p.candidate,
      "ledger_digest" => p.ledger_digest,
      "evidence_ref" => p.evidence_ref,
      "key_id" => p.key_id
    }
    |> canonical_json()
  end

  # Compact JSON with keys sorted at every level, independent of map size or
  # insertion order.
  defp canonical_json(value) do
    value |> ordered() |> Jason.encode!()
  end

  defp ordered(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map(fn {key, value} -> {key, ordered(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value

  defp footer_line(key_id, signature) do
    "<!-- arbor-sig v1 key=#{key_id} sig=#{Base.encode64(signature)} -->"
  end

  # header "\n" json "\n" footer — exactly three lines; the JSON body is
  # compact so it contains no newline.
  defp split_document(document) do
    case String.split(document, "\n") do
      [header, json, footer] -> {:ok, header, json, footer}
      _ -> {:error, :projection_invalid}
    end
  end

  defp parse_header(header) do
    case Regex.named_captures(@header_pattern, header) do
      %{"task" => task, "cycle" => cycle, "ledger" => ledger, "candidate" => candidate} ->
        {:ok,
         %{task: task, cycle: String.to_integer(cycle), ledger: ledger, candidate: candidate}}

      _ ->
        {:error, :projection_invalid}
    end
  end

  defp decode_body(json) do
    case Jason.decode(json) do
      {:ok, body} when is_map(body) ->
        if Enum.sort(Map.keys(body)) == @body_keys and body["schema"] == @schema,
          do: {:ok, body},
          else: {:error, :projection_invalid}

      _ ->
        {:error, :projection_invalid}
    end
  end

  defp header_matches_body(header, body) do
    if header.task == body["task"] and header.cycle == body["cycle"] and
         header.ledger == body["ledger_digest"] and header.candidate == body["candidate"],
       do: :ok,
       else: {:error, :projection_invalid}
  end

  defp parse_footer(footer) do
    with %{"key_id" => key_id, "sig" => sig} <- Regex.named_captures(@footer_pattern, footer),
         {:ok, signature} <- Base.decode64(sig),
         true <- byte_size(signature) == 64 do
      {:ok, key_id, signature}
    else
      _ -> {:error, :projection_invalid}
    end
  end

  defp footer_matches_body(key_id, body) do
    if body["key_id"] == key_id, do: :ok, else: {:error, :projection_invalid}
  end

  defp length_prefix(value) when is_binary(value) do
    [<<byte_size(value)::32-big-unsigned-integer>>, value]
  end
end
