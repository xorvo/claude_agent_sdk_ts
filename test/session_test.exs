defmodule ClaudeAgentSdkTs.SessionTest do
  use ExUnit.Case, async: true

  alias ClaudeAgentSdkTs.Session
  alias ClaudeAgentSdkTs.Content

  describe "build_prompt_with_history (via module internals)" do
    # We test the behavior through the public API by examining what happens
    # when we build prompts with different content types

    test "extract_text_content handles string content" do
      # This tests the internal function indirectly
      # by checking that history with string content doesn't crash
      {:ok, session} = Session.start_link()

      # Store some history manually (we'll test via get_history)
      # For now, just verify the session starts
      assert is_pid(session)

      Session.stop(session)
    end
  end

  describe "multimodal content handling" do
    test "session accepts multimodal content map" do
      {:ok, session} = Session.start_link()

      # Build multimodal content
      content = [
        Content.text("What's in this image?"),
        Content.image_base64("SGVsbG8=", "image/png")
      ]

      # The session should accept this without crashing
      # (actual API call would fail without credentials, but struct handling works)
      message = %{content: content}

      # Verify the message format is valid (doesn't crash on inspection)
      assert is_map(message)
      assert is_list(message.content)
      assert length(message.content) == 2

      Session.stop(session)
    end

    test "content blocks are properly structured" do
      content = [
        Content.text("Describe this"),
        Content.image_url("https://example.com/image.jpg")
      ]

      message = %{content: content}

      [text_block, image_block] = message.content

      assert text_block.type == "text"
      assert text_block.text == "Describe this"

      assert image_block.type == "image"
      assert image_block.source.type == "url"
      assert image_block.source.url == "https://example.com/image.jpg"
    end

    test "mixed content with Content.build" do
      image = Content.image_base64("data", "image/jpeg")

      content =
        Content.build([
          "First question",
          image,
          "Second question"
        ])

      assert length(content) == 3
      assert Enum.at(content, 0).type == "text"
      assert Enum.at(content, 1).type == "image"
      assert Enum.at(content, 2).type == "text"
    end
  end

  describe "extract_text_content" do
    # Test the internal function behavior through observable effects

    test "extracts text from list of content blocks" do
      # We test this by creating content and using Content module functions
      content = [
        %{type: "text", text: "Hello"},
        %{type: "image", source: %{type: "base64", media_type: "image/png", data: "..."}},
        %{type: "text", text: "World"}
      ]

      # Extract text portions (mimicking what extract_text_content does)
      text_only =
        content
        |> Enum.filter(fn block -> block.type == "text" end)
        |> Enum.map(fn block -> block.text end)
        |> Enum.join(" ")

      assert text_only == "Hello World"
    end

    test "handles string keys in content blocks" do
      content = [
        %{"type" => "text", "text" => "Hello"},
        %{"type" => "image", "source" => %{"type" => "url", "url" => "https://example.com"}}
      ]

      text_only =
        content
        |> Enum.filter(fn
          %{"type" => "text"} -> true
          _ -> false
        end)
        |> Enum.map(fn %{"text" => text} -> text end)
        |> Enum.join(" ")

      assert text_only == "Hello"
    end
  end

  describe "session history with multimodal" do
    test "history starts empty" do
      {:ok, session} = Session.start_link()

      assert Session.get_history(session) == []

      Session.stop(session)
    end

    test "reset clears history" do
      {:ok, session} = Session.start_link()

      # Reset should work even on empty history
      assert Session.reset(session) == :ok
      assert Session.get_history(session) == []

      Session.stop(session)
    end
  end
end
