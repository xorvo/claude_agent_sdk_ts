defmodule ClaudeAgentSdkTs.ContentTest do
  use ExUnit.Case, async: true

  alias ClaudeAgentSdkTs.Content

  describe "text/1" do
    test "creates a text content block" do
      assert Content.text("Hello, Claude!") == %{type: "text", text: "Hello, Claude!"}
    end
  end

  describe "image_base64/2" do
    test "creates an image content block from base64 data" do
      result = Content.image_base64("SGVsbG8=", "image/png")

      assert result == %{
               type: "image",
               source: %{
                 type: "base64",
                 media_type: "image/png",
                 data: "SGVsbG8="
               }
             }
    end

    test "supports jpeg media type" do
      result = Content.image_base64("data", "image/jpeg")
      assert result.source.media_type == "image/jpeg"
    end

    test "supports gif media type" do
      result = Content.image_base64("data", "image/gif")
      assert result.source.media_type == "image/gif"
    end

    test "supports webp media type" do
      result = Content.image_base64("data", "image/webp")
      assert result.source.media_type == "image/webp"
    end
  end

  describe "image_url/1" do
    test "creates an image content block from a URL" do
      result = Content.image_url("https://example.com/photo.jpg")

      assert result == %{
               type: "image",
               source: %{
                 type: "url",
                 url: "https://example.com/photo.jpg"
               }
             }
    end
  end

  describe "image_file/1" do
    test "raises for unsupported extension" do
      assert_raise ArgumentError, ~r/Unsupported image extension/, fn ->
        Content.image_file("document.pdf")
      end
    end

    test "raises for unknown extension" do
      assert_raise ArgumentError, ~r/Unsupported image extension/, fn ->
        Content.image_file("file.xyz")
      end
    end
  end

  describe "build/1" do
    test "converts strings to text blocks" do
      result = Content.build(["Hello", "World"])

      assert result == [
               %{type: "text", text: "Hello"},
               %{type: "text", text: "World"}
             ]
    end

    test "passes through existing content blocks" do
      image = Content.image_url("https://example.com/photo.jpg")
      result = Content.build(["Describe this:", image])

      assert result == [
               %{type: "text", text: "Describe this:"},
               image
             ]
    end

    test "handles mixed content" do
      image = Content.image_base64("data", "image/png")

      result =
        Content.build([
          "First text",
          image,
          "Second text"
        ])

      assert length(result) == 3
      assert Enum.at(result, 0) == %{type: "text", text: "First text"}
      assert Enum.at(result, 1) == image
      assert Enum.at(result, 2) == %{type: "text", text: "Second text"}
    end
  end
end
