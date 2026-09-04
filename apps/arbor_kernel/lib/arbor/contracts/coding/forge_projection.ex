defmodule Arbor.Contracts.Coding.ForgeProjection do
  @moduledoc """
  Closed-schema v1 forge projection for signed pull-request publishing.

  A projection binds a review ledger digest, candidate commit, and council
  verdict into a compact, signed document. Only `build/1` and `parse/1`
  produce validated projections; `render/2` and `canonical_v1/1` require an
  internally sealed struct and reject forgeries.

  ## Body bytes

  `body_without_footer/2` is the single source of signed bytes:
  `header <> "\\n" <> json` with no trailing newline.

  ## Canonical signing input

  `canonical_v1/1` concatenates 32-bit big-endian length-prefixed UTF-8 fields
  in order: domain tag, factory_id, forge_host, project, task_id, cycle
  (decimal), ledger_digest, candidate, poster_agent_id, key_id, sha256 hex of
  `body_without_footer`.
  """

  alias Arbor.Contracts.Security.SigningAuthority.Validator

  @schema "arbor-forge-projection-v1"
  @domain_tag "arbor-forge-projection-v1"
  @seal_salt "arbor-forge-projection-seal-v1"

  @max_task_id_bytes 256
  @max_cycle 4096
  @max_evidence_ref_bytes 256

  @vote_keys ~w(approve reject abstain failed reported)
  @finding_keys ~w(blocking major minor nit)
  @verdicts ~w(auto_proceed human_review reject)
  @dispositions ~w(succeeded failed cancelled)

  @tier_reasons ~w(
    human_review_required
    security_veto
    high_blast_radius
    authority_widening
    quorum_not_met
    ledger_human_required
    no_changes
    security_app
    contract_change
    cross_app
    database_migration
    frontend_visual
  )

  @verdict_from_disposition %{
    "accept" => "auto_proceed",
    "auto_proceed" => "auto_proceed",
    "human_review" => "human_review",
    "rework" => "human_review",
    "reject" => "reject",
    "stop" => "reject",
    "declined" => "reject"
  }

  @footer_pattern ~r/<!-- arbor-sig v1 key=(?<key_id>[^ ]+) sig=(?<sig>[A-Za-z0-9+\/=]+) -->$/
  @header_pattern ~r/^arbor-projection: v1 task=(?<task>.+) cycle=(?<cycle>\d+) ledger=(?<ledger>sha256:[0-9a-f]{64}) candidate=(?<candidate>[0-9a-f]{40})$/

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
    :factory_id,
    :forge_host,
    :project,
    :poster_agent_id,
    :key_id,
    :__seal__
  ]

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
            factory_id: String.t(),
            forge_host: String.t(),
            project: String.t(),
            poster_agent_id: String.t(),
            key_id: String.t(),
            __seal__: binary()
          }

  @doc """
  Validate outbound projection fields and return a sealed projection.
  """
  @spec build(map()) :: {:ok, t()} | {:error, :projection_invalid}
  def build(attrs) when is_map(attrs) do
    case validate_fields(attrs) do
      {:ok, fields} -> {:ok, seal(fields)}
      {:error, :projection_invalid} -> {:error, :projection_invalid}
    end
  end

  def build(_), do: {:error, :projection_invalid}

  @doc """
  Parse a rendered projection document and return a sealed projection.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, :projection_invalid}
  def parse(document) when is_binary(document) do
    with {:ok, header, json, footer_key_id, _sig_b64} <- split_document(document),
         {:ok, decoded} <- decode_json(json),
         :ok <- enforce_closed_body_schema(decoded),
         :ok <- header_matches_body(header, decoded),
         :ok <- footer_key_matches_body(footer_key_id, decoded),
         {:ok, fields} <- fields_from_parsed(header, decoded, footer_key_id),
         {:ok, projection} <- validate_fields(fields) do
      {:ok, seal(projection)}
    else
      _ -> {:error, :projection_invalid}
    end
  end

  def parse(_), do: {:error, :projection_invalid}

  @doc """
  Render a sealed projection with a detached signature footer.
  """
  @spec render(t(), binary()) :: {:ok, binary()} | {:error, :projection_invalid}
  def render(%__MODULE__{} = projection, signature)
      when is_binary(signature) and byte_size(signature) == 64 do
    case unseal(projection) do
      {:ok, projection} ->
        header = header_line(projection)
        json = encode_body(projection)
        body = body_without_footer(header, json)
        footer = footer_line(projection.key_id, signature)
        {:ok, body <> footer}

      {:error, :projection_invalid} ->
        {:error, :projection_invalid}
    end
  end

  def render(_projection, _signature), do: {:error, :projection_invalid}

  @doc """
  Build the length-prefixed canonical signing message for v1 projections.
  """
  @spec canonical_v1(t()) :: {:ok, binary()} | {:error, :projection_invalid}
  def canonical_v1(%__MODULE__{} = projection) do
    case unseal(projection) do
      {:ok, projection} ->
        header = header_line(projection)
        json = encode_body(projection)
        body = body_without_footer(header, json)
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

      {:error, :projection_invalid} ->
        {:error, :projection_invalid}
    end
  end

  def canonical_v1(_), do: {:error, :projection_invalid}

  @doc """
  Concatenate header and JSON body bytes without the signature footer.
  """
  @spec body_without_footer(String.t(), String.t()) :: binary()
  def body_without_footer(header, json) when is_binary(header) and is_binary(json) do
    header <> "\n" <> json
  end

  @doc false
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc false
  @spec domain_tag() :: String.t()
  def domain_tag, do: @domain_tag

  defp validate_fields(attrs) do
    with {:ok, task} <- validate_task_id(fetch_string(attrs, "task")),
         {:ok, cycle} <- validate_cycle(fetch_value(attrs, "cycle")),
         {:ok, verdict} <- validate_verdict(fetch_string(attrs, "verdict")),
         {:ok, disposition} <- validate_disposition(fetch_string(attrs, "disposition")),
         {:ok, vote_counts} <- validate_vote_counts(fetch_map(attrs, "vote_counts")),
         {:ok, tier_reasons} <- validate_tier_reasons(fetch_list(attrs, "tier_reasons")),
         {:ok, finding_counts} <- validate_finding_counts(fetch_map(attrs, "finding_counts")),
         {:ok, reviewed_commit} <- validate_git_oid(fetch_string(attrs, "reviewed_commit")),
         {:ok, candidate} <- validate_git_oid(fetch_string(attrs, "candidate")),
         {:ok, ledger_digest} <- validate_ledger_digest(fetch_string(attrs, "ledger_digest")),
         {:ok, evidence_ref} <- validate_evidence_ref(fetch_string(attrs, "evidence_ref")),
         {:ok, factory_id} <- validate_bounded_string(fetch_string(attrs, "factory_id")),
         {:ok, forge_host} <- validate_bounded_string(fetch_string(attrs, "forge_host")),
         {:ok, project} <- validate_bounded_string(fetch_string(attrs, "project")),
         {:ok, poster_agent_id} <- validate_key_id(fetch_string(attrs, "poster_agent_id")),
         {:ok, key_id} <- validate_key_id(fetch_string(attrs, "key_id")) do
      fields = %__MODULE__{
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
        factory_id: factory_id,
        forge_host: forge_host,
        project: project,
        poster_agent_id: poster_agent_id,
        key_id: key_id
      }

      {:ok, fields}
    else
      _ -> {:error, :projection_invalid}
    end
  end

  defp seal(%__MODULE__{} = fields) do
    %{fields | __seal__: compute_seal(fields)}
  end

  defp unseal(%__MODULE__{__seal__: seal} = projection) when is_binary(seal) do
    expected = compute_seal(%{projection | __seal__: nil})

    if seal == expected do
      {:ok, projection}
    else
      {:error, :projection_invalid}
    end
  end

  defp unseal(_), do: {:error, :projection_invalid}

  defp compute_seal(%__MODULE__{} = fields) do
    blob =
      [
        fields.task,
        Integer.to_string(fields.cycle),
        fields.verdict,
        fields.disposition,
        Jason.encode!(fields.vote_counts),
        Jason.encode!(fields.tier_reasons),
        Jason.encode!(fields.finding_counts),
        fields.reviewed_commit,
        fields.candidate,
        fields.ledger_digest,
        fields.evidence_ref,
        fields.factory_id,
        fields.forge_host,
        fields.project,
        fields.poster_agent_id,
        fields.key_id
      ]
      |> Enum.map_join("\x1e", &to_string/1)

    :crypto.hash(:sha256, @seal_salt <> blob) |> binary_part(0, 16)
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp fetch_value(map, key), do: Map.get(map, key)

  defp fetch_map(map, key) do
    case Map.get(map, key) do
      value when is_map(value) and not is_struct(value) -> value
      _ -> nil
    end
  end

  defp fetch_list(map, key) do
    case Map.get(map, key) do
      value when is_list(value) -> value
      _ -> nil
    end
  end

  defp validate_task_id(nil), do: {:error, :projection_invalid}

  defp validate_task_id(task) do
    cond do
      not String.valid?(task) ->
        {:error, :projection_invalid}

      String.trim(task) == "" or byte_size(task) > @max_task_id_bytes ->
        {:error, :projection_invalid}

      String.contains?(task, <<0>>) or String.match?(task, ~r/[\x00-\x1F\x7F]/) ->
        {:error, :projection_invalid}

      String.match?(task, ~r/\s|=/) ->
        {:error, :projection_invalid}

      secret_shaped?(task) ->
        {:error, :projection_invalid}

      true ->
        {:ok, task}
    end
  end

  defp validate_cycle(value) when is_integer(value) and value >= 0 and value <= @max_cycle,
    do: {:ok, value}

  defp validate_cycle(_), do: {:error, :projection_invalid}

  defp validate_verdict(nil), do: {:error, :projection_invalid}

  defp validate_verdict(verdict) do
    cond do
      verdict in @verdicts and not secret_shaped?(verdict) -> {:ok, verdict}
      Map.has_key?(@verdict_from_disposition, verdict) -> {:error, :projection_invalid}
      true -> {:error, :projection_invalid}
    end
  end

  @doc false
  @spec verdict_from_review_disposition(String.t()) ::
          {:ok, String.t()} | {:error, :projection_invalid}
  def verdict_from_review_disposition(disposition) when is_binary(disposition) do
    case Map.fetch(@verdict_from_disposition, disposition) do
      {:ok, verdict} -> {:ok, verdict}
      :error -> {:error, :projection_invalid}
    end
  end

  def verdict_from_review_disposition(_), do: {:error, :projection_invalid}

  defp validate_disposition(nil), do: {:error, :projection_invalid}

  defp validate_disposition(disposition) do
    if disposition in @dispositions and not secret_shaped?(disposition),
      do: {:ok, disposition},
      else: {:error, :projection_invalid}
  end

  defp validate_vote_counts(nil), do: {:error, :projection_invalid}

  defp validate_vote_counts(map) do
    keys = Map.keys(map) |> Enum.sort()

    if keys == Enum.sort(@vote_keys) do
      map
      |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
        cond do
          key not in @vote_keys ->
            {:halt, {:error, :projection_invalid}}

          not is_integer(value) or value < 0 ->
            {:halt, {:error, :projection_invalid}}

          secret_shaped?(Integer.to_string(value)) ->
            {:halt, {:error, :projection_invalid}}

          true ->
            {:cont, {:ok, Map.put(acc, key, value)}}
        end
      end)
    else
      {:error, :projection_invalid}
    end
  end

  defp validate_finding_counts(nil), do: {:error, :projection_invalid}

  defp validate_finding_counts(map) do
    keys = Map.keys(map) |> Enum.sort()

    if keys == Enum.sort(@finding_keys) do
      map
      |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
        cond do
          key not in @finding_keys ->
            {:halt, {:error, :projection_invalid}}

          not is_integer(value) or value < 0 ->
            {:halt, {:error, :projection_invalid}}

          true ->
            {:cont, {:ok, Map.put(acc, key, value)}}
        end
      end)
    else
      {:error, :projection_invalid}
    end
  end

  defp validate_tier_reasons(nil), do: {:error, :projection_invalid}

  defp validate_tier_reasons(list) when is_list(list) do
    normalized =
      list
      |> Enum.uniq()
      |> Enum.sort()

    cond do
      normalized == [] and list != [] ->
        {:error, :projection_invalid}

      Enum.any?(normalized, &(&1 not in @tier_reasons)) ->
        {:error, :projection_invalid}

      Enum.any?(normalized, &secret_shaped?/1) ->
        {:error, :projection_invalid}

      true ->
        {:ok, normalized}
    end
  end

  defp validate_tier_reasons(_), do: {:error, :projection_invalid}

  defp validate_git_oid(nil), do: {:error, :projection_invalid}

  defp validate_git_oid(value) do
    if Regex.match?(~r/^[0-9a-f]{40}$/, value),
      do: {:ok, value},
      else: {:error, :projection_invalid}
  end

  defp validate_ledger_digest(nil), do: {:error, :projection_invalid}

  defp validate_ledger_digest(value) do
    if Regex.match?(~r/^sha256:[0-9a-f]{64}$/, value),
      do: {:ok, value},
      else: {:error, :projection_invalid}
  end

  defp validate_evidence_ref(nil), do: {:error, :projection_invalid}

  defp validate_evidence_ref(value) do
    cond do
      not String.valid?(value) ->
        {:error, :projection_invalid}

      byte_size(value) < 1 or byte_size(value) > @max_evidence_ref_bytes ->
        {:error, :projection_invalid}

      String.contains?(value, "..") ->
        {:error, :projection_invalid}

      not Regex.match?(~r/^[A-Za-z0-9_.\/:-]+$/, value) ->
        {:error, :projection_invalid}

      secret_shaped?(value) ->
        {:error, :projection_invalid}

      true ->
        {:ok, value}
    end
  end

  defp validate_bounded_string(nil), do: {:error, :projection_invalid}

  defp validate_bounded_string(value) do
    cond do
      not String.valid?(value) or String.trim(value) == "" ->
        {:error, :projection_invalid}

      secret_shaped?(value) ->
        {:error, :projection_invalid}

      true ->
        {:ok, value}
    end
  end

  defp validate_key_id(nil), do: {:error, :projection_invalid}

  defp validate_key_id(value) do
    case Validator.validate_principal_id(value) do
      :ok -> {:ok, value}
      {:error, _} -> {:error, :projection_invalid}
    end
  end

  defp secret_shaped?(value) when is_binary(value) do
    cond do
      Regex.match?(~r/^ghp_[A-Za-z0-9]{20,}$/, value) -> true
      String.starts_with?(value, "github_pat_") -> true
      String.starts_with?(value, "glpat-") -> true
      String.starts_with?(value, "Bearer ") -> true
      Regex.match?(~r/^[0-9a-fA-F]{40}$/, value) -> true
      secret_https_userinfo?(value) -> true
      true -> false
    end
  end

  defp secret_shaped?(_), do: false

  defp secret_https_userinfo?(value) do
    case URI.parse(value) do
      %URI{scheme: "https", userinfo: userinfo} when is_binary(userinfo) and userinfo != "" ->
        true

      _ ->
        false
    end
  end

  defp header_line(%__MODULE__{} = projection) do
    "arbor-projection: v1 task=#{projection.task} cycle=#{projection.cycle} ledger=#{projection.ledger_digest} candidate=#{projection.candidate}"
  end

  defp encode_body(%__MODULE__{} = projection) do
    body_map = %{
      "schema" => @schema,
      "task" => projection.task,
      "cycle" => projection.cycle,
      "verdict" => projection.verdict,
      "disposition" => projection.disposition,
      "vote_counts" => projection.vote_counts,
      "tier_reasons" => projection.tier_reasons,
      "finding_counts" => projection.finding_counts,
      "reviewed_commit" => projection.reviewed_commit,
      "candidate" => projection.candidate,
      "ledger_digest" => projection.ledger_digest,
      "evidence_ref" => projection.evidence_ref,
      "key_id" => projection.key_id
    }

    body_map |> canonicalize() |> Jason.encode!()
  end

  defp canonicalize(map) when is_map(map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} -> {key, canonicalize(value)} end)
    |> Map.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value

  defp footer_line(key_id, signature) do
    "<!-- arbor-sig v1 key=#{key_id} sig=#{Base.encode64(signature, padding: false)} -->"
  end

  defp split_document(document) do
    case String.split(document, "\n", parts: 2) do
      [header, rest] ->
        case Regex.run(@footer_pattern, rest) do
          [footer | _] ->
            json = String.trim_trailing(String.replace_suffix(rest, footer, ""))

            case Regex.named_captures(@footer_pattern, footer) do
              %{"key_id" => key_id, "sig" => sig} ->
                {:ok, header, json, key_id, sig}

              _ ->
                {:error, :projection_invalid}
            end

          _ ->
            {:error, :projection_invalid}
        end

      _ ->
        {:error, :projection_invalid}
    end
  end

  defp decode_json(json) do
    {:ok, Jason.decode!(json)}
  rescue
    _ -> {:error, :projection_invalid}
  end

  defp enforce_closed_body_schema(decoded) when is_map(decoded) do
    allowed =
      ~w(schema task cycle verdict disposition vote_counts tier_reasons finding_counts reviewed_commit candidate ledger_digest evidence_ref key_id)

    keys = Map.keys(decoded) |> Enum.sort()

    if keys == Enum.sort(allowed) and decoded["schema"] == @schema do
      :ok
    else
      {:error, :projection_invalid}
    end
  end

  defp enforce_closed_body_schema(_), do: {:error, :projection_invalid}

  defp header_matches_body(header, body) do
    case Regex.named_captures(@header_pattern, header) do
      %{
        "task" => task,
        "cycle" => cycle,
        "ledger" => ledger,
        "candidate" => candidate
      } ->
        if task == body["task"] and cycle == Integer.to_string(body["cycle"]) and
             ledger == body["ledger_digest"] and candidate == body["candidate"] do
          :ok
        else
          {:error, :projection_invalid}
        end

      _ ->
        {:error, :projection_invalid}
    end
  end

  defp footer_key_matches_body(footer_key_id, body) do
    if Map.get(body, "key_id") == footer_key_id do
      :ok
    else
      {:error, :projection_invalid}
    end
  end

  defp fields_from_parsed(_header, body, key_id) do
    with {:ok, key_id} <- validate_key_id(key_id) do
      {:ok,
       %{
         "task" => body["task"],
         "cycle" => body["cycle"],
         "verdict" => body["verdict"],
         "disposition" => body["disposition"],
         "vote_counts" => body["vote_counts"],
         "tier_reasons" => body["tier_reasons"],
         "finding_counts" => body["finding_counts"],
         "reviewed_commit" => body["reviewed_commit"],
         "candidate" => body["candidate"],
         "ledger_digest" => body["ledger_digest"],
         "evidence_ref" => body["evidence_ref"],
         "factory_id" => "factory",
         "forge_host" => "forge.local",
         "project" => "acme/arbor",
         "poster_agent_id" => key_id,
         "key_id" => body["key_id"]
       }}
    end
  end

  defp length_prefix(value) when is_binary(value) do
    [<<byte_size(value)::32-big-unsigned-integer>>, value]
  end
end
