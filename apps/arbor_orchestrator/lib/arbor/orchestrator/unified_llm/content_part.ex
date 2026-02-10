defmodule Arbor.Orchestrator.UnifiedLLM.ContentPart do
  @moduledoc false

  @type part ::
          %{
            kind: :text,
            text: String.t()
          }
          | %{
              kind: :image,
              url: String.t() | nil,
              data: binary() | nil,
              media_type: String.t() | nil,
              detail: String.t() | nil
            }
          | %{
              kind: :audio,
              url: String.t() | nil,
              data: binary() | nil,
              media_type: String.t() | nil
            }
          | %{
              kind: :document,
              url: String.t() | nil,
              data: binary() | nil,
              media_type: String.t() | nil,
              file_name: String.t() | nil
            }
          | %{
              kind: :tool_call,
              id: String.t(),
              name: String.t(),
              arguments: map() | String.t(),
              type: String.t()
            }
          | %{
              kind: :tool_result,
              tool_call_id: String.t(),
              content: String.t() | map(),
              is_error: boolean(),
              name: String.t() | nil
            }
          | %{
              kind: :thinking,
              text: String.t(),
              signature: String.t() | nil,
              redacted: boolean()
            }

  @spec text(String.t()) :: part()
  def text(value), do: %{kind: :text, text: to_string(value)}

  @spec image_url(String.t(), keyword()) :: part()
  def image_url(url, opts \\ []) do
    %{
      kind: :image,
      url: to_string(url),
      data: nil,
      media_type: nil,
      detail: Keyword.get(opts, :detail)
    }
  end

  @spec image_base64(binary(), String.t() | nil, keyword()) :: part()
  def image_base64(data, media_type \\ "image/png", opts \\ []) when is_binary(data) do
    %{
      kind: :image,
      url: nil,
      data: data,
      media_type: media_type,
      detail: Keyword.get(opts, :detail)
    }
  end

  @spec image_file(String.t(), keyword()) :: part()
  def image_file(path, opts \\ []) do
    %{
      kind: :image,
      url: to_string(path),
      data: nil,
      media_type: Keyword.get(opts, :media_type),
      detail: Keyword.get(opts, :detail)
    }
  end

  @spec audio_url(String.t(), keyword()) :: part()
  def audio_url(url, opts \\ []) do
    %{kind: :audio, url: to_string(url), data: nil, media_type: Keyword.get(opts, :media_type)}
  end

  @spec audio_base64(binary(), String.t() | nil) :: part()
  def audio_base64(data, media_type \\ "audio/wav") do
    %{kind: :audio, url: nil, data: data, media_type: media_type}
  end

  @spec audio_file(String.t(), keyword()) :: part()
  def audio_file(path, opts \\ []) do
    %{kind: :audio, url: to_string(path), data: nil, media_type: Keyword.get(opts, :media_type)}
  end

  @spec document_url(String.t(), keyword()) :: part()
  def document_url(url, opts \\ []) do
    %{
      kind: :document,
      url: to_string(url),
      data: nil,
      media_type: Keyword.get(opts, :media_type, "application/pdf"),
      file_name: Keyword.get(opts, :file_name)
    }
  end

  @spec document_base64(binary(), String.t() | nil, keyword()) :: part()
  def document_base64(data, media_type \\ "application/pdf", opts \\ []) do
    %{
      kind: :document,
      url: nil,
      data: data,
      media_type: media_type,
      file_name: Keyword.get(opts, :file_name)
    }
  end

  @spec document_file(String.t(), keyword()) :: part()
  def document_file(path, opts \\ []) do
    %{
      kind: :document,
      url: to_string(path),
      data: nil,
      media_type: Keyword.get(opts, :media_type),
      file_name: Keyword.get(opts, :file_name) || Path.basename(path)
    }
  end

  @spec tool_call(String.t(), String.t(), map() | String.t(), keyword()) :: part()
  def tool_call(id, name, arguments, opts \\ []) do
    %{
      kind: :tool_call,
      id: to_string(id),
      name: to_string(name),
      arguments: arguments,
      type: Keyword.get(opts, :type, "function")
    }
  end

  @spec tool_result(String.t(), String.t() | map(), keyword()) :: part()
  def tool_result(tool_call_id, content, opts \\ []) do
    %{
      kind: :tool_result,
      tool_call_id: to_string(tool_call_id),
      content: content,
      is_error: Keyword.get(opts, :is_error, false),
      name: normalize_optional_name(Keyword.get(opts, :name))
    }
  end

  @spec thinking(String.t(), keyword()) :: part()
  def thinking(text, opts \\ []) do
    %{
      kind: :thinking,
      text: to_string(text),
      signature: Keyword.get(opts, :signature),
      redacted: Keyword.get(opts, :redacted, false)
    }
  end

  @spec redacted_thinking(String.t(), keyword()) :: part()
  def redacted_thinking(text, opts \\ []) do
    thinking(text, Keyword.put(opts, :redacted, true))
  end

  @spec normalize(term()) :: [part()]
  def normalize(content) when is_binary(content), do: [text(content)]

  def normalize(content) when is_list(content) do
    content
    |> Enum.map(&normalize_part/1)
    |> Enum.reject(&is_nil/1)
  end

  def normalize(nil), do: []
  def normalize(other), do: [text(inspect(other))]

  @spec text_content(term()) :: String.t()
  def text_content(content) do
    content
    |> normalize()
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map(& &1.text)
    |> Enum.join("")
  end

  defp normalize_part(%{kind: kind} = part) when kind in [:text, "text"] do
    text(Map.get(part, :text) || Map.get(part, "text") || "")
  end

  defp normalize_part(%{kind: kind} = part) when kind in [:image, "image"] do
    normalize_image(part)
  end

  defp normalize_part(%{kind: kind} = part) when kind in [:audio, "audio"] do
    normalize_audio(part)
  end

  defp normalize_part(%{kind: kind} = part) when kind in [:document, "document"] do
    normalize_document(part)
  end

  defp normalize_part(%{kind: kind} = part) when kind in [:tool_call, "tool_call"] do
    normalize_tool_call(part)
  end

  defp normalize_part(%{kind: kind} = part) when kind in [:tool_result, "tool_result"] do
    normalize_tool_result(part)
  end

  defp normalize_part(%{kind: kind} = part)
       when kind in [:thinking, "thinking", :redacted_thinking, "redacted_thinking"] do
    normalize_thinking(part)
  end

  defp normalize_part(%{"kind" => kind} = part) when kind in [:text, "text"] do
    text(Map.get(part, :text) || Map.get(part, "text") || "")
  end

  defp normalize_part(%{"kind" => kind} = part) when kind in [:image, "image"] do
    normalize_image(part)
  end

  defp normalize_part(%{"kind" => kind} = part) when kind in [:audio, "audio"] do
    normalize_audio(part)
  end

  defp normalize_part(%{"kind" => kind} = part) when kind in [:document, "document"] do
    normalize_document(part)
  end

  defp normalize_part(%{"kind" => kind} = part) when kind in [:tool_call, "tool_call"] do
    normalize_tool_call(part)
  end

  defp normalize_part(%{"kind" => kind} = part) when kind in [:tool_result, "tool_result"] do
    normalize_tool_result(part)
  end

  defp normalize_part(%{"kind" => kind} = part)
       when kind in [:thinking, "thinking", :redacted_thinking, "redacted_thinking"] do
    normalize_thinking(part)
  end

  defp normalize_part(%{"text" => txt}) when is_binary(txt), do: text(txt)
  defp normalize_part(%{text: txt}) when is_binary(txt), do: text(txt)
  defp normalize_part(value) when is_binary(value), do: text(value)
  defp normalize_part(_), do: nil

  defp normalize_image(part) do
    url =
      Map.get(part, :url) || Map.get(part, "url") || Map.get(part, :path) || Map.get(part, "path")

    data = Map.get(part, :data) || Map.get(part, "data")
    media_type = Map.get(part, :media_type) || Map.get(part, "media_type")
    detail = Map.get(part, :detail) || Map.get(part, "detail")

    case normalize_blob(:image, url, data, media_type, "image/png") do
      nil -> nil
      blob -> Map.put(blob, :detail, normalize_detail(detail))
    end
  end

  defp normalize_audio(part) do
    url =
      Map.get(part, :url) || Map.get(part, "url") || Map.get(part, :path) || Map.get(part, "path")

    data = Map.get(part, :data) || Map.get(part, "data")
    media_type = Map.get(part, :media_type) || Map.get(part, "media_type")
    normalize_blob(:audio, url, data, media_type, "audio/wav")
  end

  defp normalize_document(part) do
    url =
      Map.get(part, :url) || Map.get(part, "url") || Map.get(part, :path) || Map.get(part, "path")

    data = Map.get(part, :data) || Map.get(part, "data")
    media_type = Map.get(part, :media_type) || Map.get(part, "media_type")
    file_name = Map.get(part, :file_name) || Map.get(part, "file_name")

    case normalize_blob(:document, url, data, media_type, "application/pdf") do
      nil -> nil
      blob -> Map.put(blob, :file_name, file_name)
    end
  end

  defp normalize_tool_call(part) do
    id = Map.get(part, :id) || Map.get(part, "id")
    name = Map.get(part, :name) || Map.get(part, "name")
    args = Map.get(part, :arguments) || Map.get(part, "arguments") || %{}
    type = Map.get(part, :type) || Map.get(part, "type") || "function"

    if id in [nil, ""] or name in [nil, ""] do
      nil
    else
      %{
        kind: :tool_call,
        id: to_string(id),
        name: to_string(name),
        arguments: args,
        type: to_string(type)
      }
    end
  end

  defp normalize_tool_result(part) do
    tool_call_id = Map.get(part, :tool_call_id) || Map.get(part, "tool_call_id")
    content = Map.get(part, :content) || Map.get(part, "content")
    is_error = Map.get(part, :is_error, Map.get(part, "is_error", false))
    name = Map.get(part, :name) || Map.get(part, "name")

    if tool_call_id in [nil, ""] do
      nil
    else
      %{
        kind: :tool_result,
        tool_call_id: to_string(tool_call_id),
        content: content,
        is_error: !!is_error,
        name: normalize_optional_name(name)
      }
    end
  end

  defp normalize_thinking(part) do
    text = Map.get(part, :text) || Map.get(part, "text") || ""
    signature = Map.get(part, :signature) || Map.get(part, "signature")
    redacted = Map.get(part, :redacted, Map.get(part, "redacted", false))

    %{
      kind: :thinking,
      text: to_string(text),
      signature: signature && to_string(signature),
      redacted: !!redacted
    }
  end

  defp normalize_blob(kind, url, data, media_type, default_media_type) do
    cond do
      is_binary(data) and data != "" ->
        %{kind: kind, url: nil, data: data, media_type: media_type || default_media_type}

      is_binary(url) and url != "" and local_path?(url) ->
        case File.read(expand_path(url)) do
          {:ok, bytes} ->
            %{
              kind: kind,
              url: nil,
              data: bytes,
              media_type: media_type || infer_media_type(url, default_media_type)
            }

          {:error, _} ->
            %{kind: kind, url: url, data: nil, media_type: media_type}
        end

      is_binary(url) and url != "" ->
        %{kind: kind, url: url, data: nil, media_type: media_type}

      true ->
        nil
    end
  end

  defp normalize_detail(nil), do: nil
  defp normalize_detail(value), do: to_string(value)

  defp normalize_optional_name(nil), do: nil
  defp normalize_optional_name(""), do: nil
  defp normalize_optional_name(value), do: to_string(value)

  defp local_path?(value) do
    String.starts_with?(value, "/") or String.starts_with?(value, "./") or
      String.starts_with?(value, "~/")
  end

  defp expand_path("~/"), do: Path.expand("~/")
  defp expand_path(value) when is_binary(value), do: Path.expand(value)

  defp infer_media_type(path, default) do
    case path |> String.downcase() |> Path.extname() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".heic" -> "image/heic"
      ".heif" -> "image/heif"
      ".wav" -> "audio/wav"
      ".mp3" -> "audio/mpeg"
      ".m4a" -> "audio/mp4"
      ".pdf" -> "application/pdf"
      _ -> default
    end
  end
end
