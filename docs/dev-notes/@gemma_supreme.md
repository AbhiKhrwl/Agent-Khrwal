# 🔱 GEMMA 4 SUPREME GUIDELINES (FLUTTER INTEGRATION)
**DO NOT DEVIATE FROM THIS DOCUMENT. THIS IS THE 2026 TRUTH.**

This file contains the absolute rules and production-grade architecture for integrating Gemma 4 within Flutter using `flutter_gemma`. Any agent working on this project MUST strictly follow these guidelines. Ignoring this will cause Out-Of-Memory (OOM) crashes, thermal throttling, or broken tool calling.

---

## 1. THE INFERENCE ENGINE (`flutter_gemma` v0.15.1)
- **No Custom Native Code:** Do NOT write custom Kotlin MethodChannels or Java JVM code. `flutter_gemma` v0.15.1 already handles Native Platform Channels for Android and zero-copy `dart:ffi` for Desktop.
- **Model Format:** STRICTLY use `.litertlm` models (e.g., `gemma-4-E2B-it.litertlm`). Do NOT use `.bin` or `.task` files.
- **Initialization:** Must register `ModelType.gemma4` to enable native function calling.
  ```dart
  await FlutterGemma.initialize(
    huggingFaceToken: const String.fromEnvironment('HUGGINGFACE_TOKEN'),
    maxDownloadRetries: 10,
    webStorageMode: WebStorageMode.cacheApi, 
  );
  ```
- **Concurrency:** ALWAYS use a global engine mutex. LiteRT-LM is single-threaded — two concurrent conversations WILL SIGSEGV.

## 2. NATIVE FUNCTION CALLING (THE GOLDEN RULES)
### 2a. Schema Format
- `gemma.Tool()` expects FLAT format: `{ 'name': 'bash', 'description': '...', 'parameters': {...} }`
- Do NOT use OpenAI-nested format: `{ 'type': 'function', 'function': {...} }`
- Use `getToolDefinitionsFlat()` from AgentRouter — NOT `getToolDefinitionsForApi()`

### 2b. createChat() Config (CRITICAL)
```dart
final chat = await model.createChat(
  temperature: 0.7,              // NEVER 0.0 — kills <|tool_call|> token emission
  tools: tools,                   // Flat gemma.Tool objects
  isThinking: false,              // NEVER true with tools — memory conflict
  maxFunctionBufferLength: 1024,  // 4096 is overkill for E2B flat schemas
  systemInstruction: 'You are Apex, a helpful AI assistant. '
      'You have access to tools. When the user asks you to perform '
      'an action, use the appropriate tool to accomplish it.',
);
```

### 2c. Tool Schema Design
- Keep schemas FLAT — only `type` + `description` per property
- E2B's 8:1 GQA compression loses track of deeply nested structures
- Max 7 tools per createChat() call for reliable function selection

### 2d. Response Handling
- `FunctionCallResponse` comes as structured Dart object — no text parsing needed
- Surface as `ToolCallEvent(name, args)` — AetherCore handles directly
- CipherProtocol text parsing is LEGACY FALLBACK only

## 3. VISION & MULTIMODAL (Variable Image Resolution)
Gemma 4 natively supports Vision. Do NOT use external cloud APIs for basic image processing.
- **Image Conversion:** Always convert images from ImagePicker/Assets into `Uint8List`.
- **Pre-Processing:** Resize images to ≤512px max dimension BEFORE sending to model.
  - Original: 900x1600 → 2376 patches → GPU crash
  - After: 288x512 → ~280 patches → smooth inference
- **Token Budgeting:** 
  - **70-280 Tokens (Low Budget):** Basic classification. Saves RAM.
  - **560-1120 Tokens (High Budget):** MANDATORY for OCR, document parsing.
- **Injection:**
  ```dart
  chat.addQueryChunk(
    Message.withImage(text: 'Analyze this image.', imageBytes: imageBytes, isUser: true)
  );
  ```

## 4. AUDIO (Gemma 4 Native)
- Gemma 4 E2B/E4B supports native audio input via `Message.withAudio()`
- Configure: 16kHz, 16-bit PCM, mono WAV
- Only enable `supportAudio: true` when audio is present in history
- `supportAudio` + `enableSpeculativeDecoding` = crash when no audio present

## 5. THINKING MODE (Reasoning)
- Enable `isThinking: true` in `createChat()` ONLY when tools are NOT active
- The model emits `ThinkingResponse` and `TextResponse` separately
- **UX Rule:** Render `ThinkingResponse` inside a collapsible "Thinking Bubble"
- **NEVER combine isThinking: true with tools** — causes memory allocation conflict

## 6. SPECULATIVE DECODING (MTP)
- Enable `enableSpeculativeDecoding: true` for plain chat (no tools)
- **MUST disable when tools are active** — MTP drafter predictions conflict with constrained decoding grammar
- Provides ~2x speed improvement on compatible hardware

## 7. HARDWARE & MEMORY CONSTRAINTS (Survival Rules)
- **RAM Footprint:** E2B requires 2-3GB active RAM. E4B requires 4-5GB.
- **Garbage Collection:** Manually dispose of old `InferenceModel` instances and `Uint8List` image bytes.
- **Thermal Throttling:** Continuous token generation overheats NPU/GPU. Enforce strict `maxTokens` limits.
- **Backend Selection:** Use auto-detect pattern — try GPU first, fallback to CPU on error, permanent CPU after 3 consecutive GPU failures.
- **MediaTek Chipsets:** Force CPU backend — GPU/Vision backend crashes on MediaTek.

## 8. EMPTY RESPONSE RECOVERY
- E2B sometimes returns completely empty strings (hallucination mode)
- AetherCore MUST detect empty responses and auto-retry with system nudge
- Max 3 retries before giving up and showing user-facing message

## 9. HYBRID CLOUD ROUTING (`firebase_ai`)
- **Low RAM Fallback:** If device has < 6GB RAM, bypass local Gemma 4 and fallback to `firebase_ai` (Gemini Flash-Lite).
- **Security:** NEVER hardcode API Keys in Flutter. Use Firebase App Check.

---
**AGENTS:** Whenever implementing a feature, reference this `@gemma_supreme.md` document. Do not hallucinate old 2024 TensorFlow Lite code. You are working in 2026.
