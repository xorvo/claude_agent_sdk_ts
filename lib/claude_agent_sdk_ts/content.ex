defmodule ClaudeAgentSdkTs.Content do
  @moduledoc """
  Helper functions for building multimodal content blocks.

  Claude supports various types of content blocks in messages:
    - Text blocks for regular text input
    - Image blocks for visual input (JPEG, PNG, GIF, WebP)

  ## Supported Image Formats

    - JPEG (`image/jpeg`)
    - PNG (`image/png`)
    - GIF (`image/gif`)
    - WebP (`image/webp`)

  ## Note on PDFs

  PDFs are not directly supported for vision analysis. To analyze PDF content,
  you must first convert PDF pages to images (PNG or JPEG) and then use the
  image content blocks.

  ## Examples

      # Simple text
      content = Content.text("What's in this image?")

      # Image from base64
      image_data = File.read!("photo.png") |> Base.encode64()
      content = [
        Content.text("What's in this image?"),
        Content.image_base64(image_data, "image/png")
      ]
      ClaudeAgentSdkTs.chat(%{content: content})

      # Image from URL
      content = [
        Content.text("Describe this:"),
        Content.image_url("https://example.com/image.jpg")
      ]
      ClaudeAgentSdkTs.chat(%{content: content})

      # Multiple images
      content = [
        Content.text("Compare these two images:"),
        Content.image_file("first.png"),
        Content.image_file("second.png")
      ]
      ClaudeAgentSdkTs.chat(%{content: content})
  """

  @type media_type :: String.t()
  @type text_block :: %{type: String.t(), text: String.t()}
  @type image_block :: %{
          type: String.t(),
          source: %{
            type: String.t(),
            media_type: media_type(),
            data: String.t()
          }
        }
  @type content_block :: text_block() | image_block()

  @supported_image_types ["image/jpeg", "image/png", "image/gif", "image/webp"]

  @doc """
  Creates a text content block.

  ## Examples

      Content.text("Hello, Claude!")
  """
  @spec text(String.t()) :: text_block()
  def text(text) when is_binary(text) do
    %{type: "text", text: text}
  end

  @doc """
  Creates an image content block from base64-encoded data.

  ## Arguments

    - `data` - Base64-encoded image data
    - `media_type` - MIME type of the image (e.g., "image/png", "image/jpeg")

  ## Examples

      image_data = File.read!("photo.png") |> Base.encode64()
      Content.image_base64(image_data, "image/png")
  """
  @spec image_base64(String.t(), media_type()) :: image_block()
  def image_base64(data, media_type) when is_binary(data) and media_type in @supported_image_types do
    %{
      type: "image",
      source: %{
        type: "base64",
        media_type: media_type,
        data: data
      }
    }
  end

  @doc """
  Creates an image content block from a URL.

  ## Arguments

    - `url` - URL of the image

  ## Examples

      Content.image_url("https://example.com/image.jpg")
  """
  @spec image_url(String.t()) :: map()
  def image_url(url) when is_binary(url) do
    %{
      type: "image",
      source: %{
        type: "url",
        url: url
      }
    }
  end

  @doc """
  Creates an image content block from a local file.

  Automatically detects the media type from the file extension.

  ## Arguments

    - `path` - Path to the image file

  ## Supported Extensions

    - `.jpg`, `.jpeg` - image/jpeg
    - `.png` - image/png
    - `.gif` - image/gif
    - `.webp` - image/webp

  ## Examples

      Content.image_file("screenshots/capture.png")
  """
  @spec image_file(String.t()) :: image_block()
  def image_file(path) when is_binary(path) do
    media_type = detect_media_type(path)
    data = File.read!(path) |> Base.encode64()
    image_base64(data, media_type)
  end

  @doc """
  Builds a content array from a mix of text and images.

  Accepts strings (converted to text blocks), image blocks, or already-formed content blocks.

  ## Examples

      # Mix of strings and images
      Content.build([
        "What's in these images?",
        Content.image_file("photo1.png"),
        Content.image_file("photo2.png"),
        "Please describe them in detail."
      ])
  """
  @spec build(list(String.t() | content_block())) :: [content_block()]
  def build(items) when is_list(items) do
    Enum.map(items, fn
      item when is_binary(item) -> text(item)
      %{type: _} = block -> block
    end)
  end

  # Private functions

  defp detect_media_type(path) do
    case Path.extname(path) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ext -> raise ArgumentError, "Unsupported image extension: #{ext}. Supported: .jpg, .jpeg, .png, .gif, .webp"
    end
  end
end
