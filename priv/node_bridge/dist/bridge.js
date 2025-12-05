/**
 * Node.js Bridge for ClaudeAgent Elixir wrapper
 *
 * This script communicates with Elixir via stdin/stdout using newline-delimited JSON.
 * It wraps the official @anthropic-ai/claude-agent-sdk.
 *
 * Supports:
 * - Multimodal inputs (images) via structured content blocks
 * - Interactive permission handling via canUseTool callback
 */
import * as readline from "readline";
import { randomUUID } from "crypto";
import { query } from "@anthropic-ai/claude-agent-sdk";
// Debug logging - writes to stderr so it doesn't interfere with JSON protocol on stdout
const DEBUG = process.env.CLAUDE_AGENT_DEBUG === "1";
// Store pending permission requests waiting for responses from Elixir
const pendingPermissions = new Map();
// Store active AbortControllers for each request, allowing abort from Elixir
const activeAbortControllers = new Map();
function debug(msg, data) {
    if (DEBUG) {
        const timestamp = new Date().toISOString();
        if (data !== undefined) {
            console.error(`[${timestamp}] [Bridge] ${msg}: ${JSON.stringify(data).slice(0, 300)}`);
        }
        else {
            console.error(`[${timestamp}] [Bridge] ${msg}`);
        }
    }
}
// Send a JSON response to Elixir
function send(response) {
    const json = JSON.stringify(response);
    debug("Sending response", response);
    console.log(json);
}
// Extract text content from an SDK message
function extractTextContent(message) {
    if (message.type === "assistant" && message.message && "content" in message.message) {
        const content = message.message.content;
        if (Array.isArray(content)) {
            return content
                .filter((block) => block.type === "text")
                .map((block) => block.text)
                .join("");
        }
    }
    return "";
}
// Extract tool use from an SDK message
function extractToolUse(message) {
    if (message.type === "assistant" && message.message && "content" in message.message) {
        const content = message.message.content;
        if (Array.isArray(content)) {
            const toolUse = content.find((block) => block.type === "tool_use");
            if (toolUse) {
                return { name: toolUse.name, input: toolUse.input, id: toolUse.id };
            }
        }
    }
    return null;
}
/**
 * Build the prompt parameter for query().
 * Supports both simple string prompts and structured multimodal content.
 *
 * Content format for images:
 * [
 *   { type: "text", text: "What's in this image?" },
 *   { type: "image", source: { type: "base64", media_type: "image/png", data: "..." } }
 * ]
 *
 * Or with URL:
 * [
 *   { type: "text", text: "Describe this:" },
 *   { type: "image", source: { type: "url", url: "https://..." } }
 * ]
 */
function buildPrompt(command) {
    const { prompt, content } = command;
    // If content array is provided, convert to SDKUserMessage async iterable
    if (content && Array.isArray(content)) {
        debug("Building multimodal prompt from content array", { contentLength: content.length });
        // Create a single SDKUserMessage with the structured content
        const userMessage = {
            type: "user",
            message: {
                role: "user",
                content: content
            },
            parent_tool_use_id: null,
            uuid: randomUUID(),
            session_id: randomUUID()
        };
        // Return an async iterable that yields the single message
        return (async function* () {
            yield userMessage;
        })();
    }
    // Otherwise, use the simple string prompt
    return prompt;
}
/**
 * Create a canUseTool callback that sends permission requests to Elixir
 * and waits for responses.
 *
 * @param {string} commandId - The ID of the chat/stream command
 * @returns {Function} The canUseTool callback function
 */
function createCanUseToolCallback(commandId) {
    return async (toolName, input, options) => {
        const requestId = randomUUID();
        debug("canUseTool called", { toolName, requestId, toolUseID: options.toolUseID });
        // Send permission request to Elixir
        send({
            id: commandId,
            type: "permission_request",
            requestId: requestId,
            toolName: toolName,
            toolInput: input,
            toolUseId: options.toolUseID,
            agentId: options.agentID || null,
            suggestions: options.suggestions || [],
            blockedPath: options.blockedPath || null,
            decisionReason: options.decisionReason || null,
        });
        // Wait for response from Elixir (no timeout - matches TypeScript SDK behavior)
        return new Promise((resolve, reject) => {
            pendingPermissions.set(requestId, { resolve, reject });
        });
    };
}
/**
 * Handle a permission response from Elixir
 */
function handlePermissionResponse(response) {
    const { requestId, behavior, updatedInput, updatedPermissions, message, interrupt } = response;
    debug("Handling permission response", { requestId, behavior });
    const pending = pendingPermissions.get(requestId);
    if (!pending) {
        debug("No pending permission request found for requestId", { requestId });
        return;
    }
    pendingPermissions.delete(requestId);
    if (behavior === "allow") {
        pending.resolve({
            behavior: "allow",
            updatedInput: updatedInput || {},
            updatedPermissions: updatedPermissions,
        });
    }
    else {
        pending.resolve({
            behavior: "deny",
            message: message || "Permission denied",
            interrupt: interrupt || false,
        });
    }
}
// Build SDK options from command options
function buildOptions(opts = {}, commandId = null) {
    const sdkOptions = {};
    if (opts.model)
        sdkOptions.model = opts.model;
    if (opts.maxTurns)
        sdkOptions.maxTurns = opts.maxTurns;
    if (opts.maxBudgetUsd)
        sdkOptions.maxBudgetUsd = opts.maxBudgetUsd;
    if (opts.cwd)
        sdkOptions.cwd = opts.cwd;
    if (opts.allowedTools)
        sdkOptions.allowedTools = opts.allowedTools;
    if (opts.disallowedTools)
        sdkOptions.disallowedTools = opts.disallowedTools;
    if (opts.permissionMode)
        sdkOptions.permissionMode = opts.permissionMode;
    if (opts.systemPrompt)
        sdkOptions.systemPrompt = opts.systemPrompt;
    // If interactive permissions are enabled, set up the canUseTool callback
    if (opts.interactivePermissions && commandId) {
        debug("Enabling interactive permissions for command", { commandId });
        sdkOptions.canUseTool = createCanUseToolCallback(commandId);
        // Don't bypass permissions when interactive mode is enabled
        if (!opts.permissionMode) {
            sdkOptions.permissionMode = "default";
        }
    }
    else {
        // Default to bypassing permissions for SDK usage (non-interactive)
        if (!sdkOptions.permissionMode) {
            sdkOptions.permissionMode = "bypassPermissions";
        }
    }
    return sdkOptions;
}
// Handle a chat command (collect all responses)
async function handleChat(command) {
    const { id, prompt, content, options = {} } = command;
    const promptPreview = prompt ? prompt.slice(0, 100) : `[multimodal: ${content?.length || 0} blocks]`;
    debug(`handleChat called`, { id, prompt: promptPreview, options });
    // Create an AbortController for this request
    const abortController = new AbortController();
    activeAbortControllers.set(id, abortController);
    try {
        const sdkOptions = buildOptions(options, id);
        // Add the AbortController to SDK options
        sdkOptions.abortController = abortController;
        debug("SDK options built", sdkOptions);
        debug("Calling query()...");
        const promptParam = buildPrompt(command);
        const response = query({ prompt: promptParam, options: sdkOptions });
        debug("query() returned, starting iteration...");
        let fullContent = "";
        let resultMessage = null;
        let messageCount = 0;
        for await (const message of response) {
            messageCount++;
            debug(`Received SDK message #${messageCount}`, { type: message.type });
            if (message.type === "assistant") {
                const text = extractTextContent(message);
                if (text) {
                    fullContent += text;
                    debug(`Accumulated text (${fullContent.length} chars)`);
                }
            }
            else if (message.type === "result") {
                resultMessage = message;
                debug("Received result message", message);
            }
            else if (message.type === "system") {
                debug("Received system message", message);
            }
        }
        debug(`Iteration complete, ${messageCount} messages received`);
        // If we have a result message with a result string, use that
        if (resultMessage && resultMessage.type === "result" && "result" in resultMessage) {
            send({ id, type: "complete", content: resultMessage.result || fullContent });
        }
        else {
            send({ id, type: "complete", content: fullContent });
        }
    }
    catch (error) {
        // Check if this was an abort
        if (abortController.signal.aborted) {
            debug("Chat aborted", { id });
            send({ id, type: "aborted", message: "Request was aborted" });
        }
        else {
            debug("Error in handleChat", { error: String(error) });
            send({
                id,
                type: "error",
                message: error instanceof Error ? error.message : String(error),
            });
        }
    }
    finally {
        // Clean up the abort controller
        activeAbortControllers.delete(id);
    }
}
// Handle a streaming chat command
async function handleStream(command) {
    const { id, prompt, content, options = {} } = command;
    const promptPreview = prompt ? prompt.slice(0, 100) : `[multimodal: ${content?.length || 0} blocks]`;
    debug(`handleStream called`, { id, prompt: promptPreview, options });
    // Create an AbortController for this request
    const abortController = new AbortController();
    activeAbortControllers.set(id, abortController);
    try {
        const sdkOptions = buildOptions(options, id);
        // Add the AbortController to SDK options
        sdkOptions.abortController = abortController;
        debug("SDK options built for stream", sdkOptions);
        // Enable partial messages for streaming
        sdkOptions.includePartialMessages = true;
        debug("Calling query() for stream...");
        const promptParam = buildPrompt(command);
        const response = query({ prompt: promptParam, options: sdkOptions });
        debug("query() returned, starting stream iteration...");
        // Track what we've already sent to only send deltas
        let sentTextLength = 0;
        let lastToolUseId = null;
        let messageCount = 0;
        for await (const message of response) {
            messageCount++;
            debug(`Stream message #${messageCount}`, { type: message.type });
            switch (message.type) {
                case "assistant": {
                    const fullText = extractTextContent(message);
                    if (fullText && fullText.length > sentTextLength) {
                        // Only send the new text (delta)
                        const delta = fullText.slice(sentTextLength);
                        send({ id, type: "chunk", content: delta });
                        sentTextLength = fullText.length;
                    }
                    const toolUse = extractToolUse(message);
                    if (toolUse && toolUse.id !== lastToolUseId) {
                        send({
                            id,
                            type: "tool_use",
                            name: toolUse.name,
                            input: toolUse.input,
                            toolUseId: toolUse.id,
                        });
                        lastToolUseId = toolUse.id;
                    }
                    break;
                }
                case "stream_event": {
                    // Handle streaming events for real-time text
                    const event = message.event;
                    if (event.type === "content_block_delta" && event.delta.type === "text_delta") {
                        send({ id, type: "chunk", content: event.delta.text });
                        // Update our tracking since stream_event deltas are already incremental
                        sentTextLength += event.delta.text.length;
                    }
                    break;
                }
                case "system": {
                    // Send system info (tools, model, etc.)
                    send({
                        id,
                        type: "system",
                        raw: message,
                    });
                    break;
                }
                case "result": {
                    // Don't send result content - it's already been streamed via assistant messages
                    // The result message contains the same text that was already sent
                    break;
                }
            }
        }
        debug(`Stream iteration complete, ${messageCount} messages received`);
        send({ id, type: "end" });
    }
    catch (error) {
        // Check if this was an abort
        if (abortController.signal.aborted) {
            debug("Stream aborted", { id });
            send({ id, type: "aborted", message: "Request was aborted" });
        }
        else {
            debug("Error in handleStream", { error: String(error) });
            send({
                id,
                type: "error",
                message: error instanceof Error ? error.message : String(error),
            });
        }
    }
    finally {
        // Clean up the abort controller
        activeAbortControllers.delete(id);
    }
}
/**
 * Handle an abort command from Elixir
 */
function handleAbort(command) {
    const { id } = command;
    debug("handleAbort called", { id });
    const controller = activeAbortControllers.get(id);
    if (controller) {
        debug("Aborting request", { id });
        controller.abort();
        // Note: The aborted response will be sent by handleChat/handleStream
        // when they catch the abort error
    }
    else {
        debug("No active request found to abort", { id });
        // Send acknowledgment even if no request found (might have already completed)
        send({ id, type: "abort_ack", found: false });
    }
}
// Main entry point
async function main() {
    debug("Bridge starting...");
    // Set up readline to read from stdin
    const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
        terminal: false,
    });
    debug("Readline interface created, waiting for commands...");
    // Process each line as a JSON command
    rl.on("line", async (line) => {
        debug("Received line", line.slice(0, 200));
        if (!line.trim())
            return;
        let command;
        try {
            command = JSON.parse(line);
            debug("Parsed command", { type: command.type, id: command.id });
        }
        catch (error) {
            debug("JSON parse error", { error: String(error) });
            send({
                id: "unknown",
                type: "error",
                message: `Invalid JSON: ${error}`,
            });
            return;
        }
        switch (command.type) {
            case "chat":
                debug("Dispatching to handleChat");
                await handleChat(command);
                break;
            case "stream":
                debug("Dispatching to handleStream");
                await handleStream(command);
                break;
            case "abort":
                debug("Dispatching to handleAbort");
                handleAbort(command);
                break;
            case "permission_response":
                debug("Handling permission response");
                handlePermissionResponse(command);
                break;
            case "tool_result":
                send({
                    id: command.id,
                    type: "error",
                    message: "Tool results require session management (not yet implemented)",
                });
                break;
            default: {
                // Handle unknown command types
                const unknownCmd = command;
                send({
                    id: unknownCmd.id || "unknown",
                    type: "error",
                    message: `Unknown command type: ${unknownCmd.type}`,
                });
            }
        }
    });
    rl.on("close", () => {
        debug("Readline closed, exiting");
        process.exit(0);
    });
}
main().catch((error) => {
    console.error("Bridge initialization failed:", error);
    process.exit(1);
});
