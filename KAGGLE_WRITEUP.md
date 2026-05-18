# Kaggle Writeup: Apex Lite (Agent Kharwal)

## Title
Agent Kharwal: An Autonomous, Self-Healing AI Agent Running Entirely On-Device with Gemma 4

## Subtitle
Shattering the "Cloud Ceiling" — bringing enterprise-grade agentic tool execution, multi-layer security sandboxing, and silent error recovery to fully offline mobile devices for students and shopkeepers.

## Tracks
- **Impact Track**: Digital Equity & Inclusivity
- **Special Technology Track**: LiteRT

---

## 1. The Story: Breaking the Cloud Ceiling

In 12 days, with limited internet and zero cloud budget, a solo developer set out to prove that frontier AI doesn't require the cloud. The result: **Agent Kharwal** — 10,755 lines of production Dart code that transforms a ₹12,000 Android phone into an autonomous AI workstation.

The motivation came from a simple observation: AI is advancing at lightspeed, but the communities that could benefit the most are being left behind. India alone has **63 million micro-retailers** (KPMG 2023) and **250 million students** (Ministry of Education). For a shopkeeper in a small town who barely uses a smartphone, or a student in a rural classroom with spotty connectivity, cloud-based AI is inaccessible. It demands expensive data plans, constant internet, and forces sensitive business records onto remote servers.

Agent Kharwal eliminates all three barriers. It runs **100% locally** using Gemma 4 E2B via LiteRT, requires **zero internet**, costs **nothing**, and ensures **absolute data privacy** — every byte stays on the device.

## 2. Architecture: The Agentic Operating Layer

Agent Kharwal is not a chatbot — it is a **fully autonomous, multi-tool agent** with shell access, file operations, and self-correction capabilities. The architecture consists of five layers:

**Presentation Layer** — The `GajrajOracleScaffold` provides a premium chat interface with animated `ToolCard` widgets that update in-place (Running → Done), a `SandboxExplorer` ("The Vault") for transparent file browsing, and an `ActivityDrawer` audit log.

**Orchestration Layer (AetherCore — 1,514 lines)** — The autonomous control loop (`_runInternalPulse`) that enables multi-turn task completion. When a user says "create a project folder with a README," the agent calls `mkdir -p`, then `file_write`, then verifies — all without user intervention. This `while(true)` loop is the fundamental difference between a chatbot and an agent.

**Execution Layer** — The `AgentRouter` dispatches tool requests with ordered batch execution (adjacent safe tools run in parallel, unsafe tools run sequentially). A fuzzy name matcher (`_findClosestTool`) handles hallucinated tool names with "Did you mean?" suggestions.

**Security Layer (The Omega Fortress)** — Three-tier pre-execution defense:
- `SentryPurity`: Tokenizes bash commands and blocks shell metacharacters (`$()`, backticks, `eval`, heredocs), dangerous operations (`rm -rf`, `sudo`, `wget`), and pipe-to-interpreter chains.
- `PathJailer`: Symlink-aware directory traversal prevention. Canonicalizes all paths and validates they remain within the sandbox boundary.
- `SpectralOps`: Sandboxed shell with 15-second timeout, 50-PID cap, environment scrubbing (no host secrets), and infinite loop detection (>90% duplicate output lines → SIGKILL).

**Inference Engine (LocalInferenceService — 838 lines)** — Wraps `flutter_gemma` ^0.15.1 with a global engine Mutex (LiteRT-LM is strictly single-threaded), a 3-tier GPU→CPU fallback chain, and a 60-second stream inactivity watchdog.

## 3. How Gemma 4 Is Specifically Used

**Native Function Calling**: Tools are registered via `createChat(tools: [...])` using the `gemma.Tool` constructor. The model emits `<|tool_call|>` tokens that the SDK surfaces as `FunctionCallResponse` objects, mapped to our typed `ToolCallEvent` sealed class.

**Text-to-Tool Interceptor**: Gemma 4 E2B uses native tool tokens ~60% of the time. The remaining ~40%, it writes bash commands in markdown code blocks. Our interceptor extracts these via multi-pattern regex, validates against 30+ known shell commands, and converts them to structured `ToolRequest` objects — ensuring the agent acts on every intent.

**Gemma 4 Escape Token Sanitizer**: We discovered that Gemma 4 wraps tool parameter strings in `<|"|\>` escape tokens. Without stripping these, commands like `mkdir <|"|\>folder<|"|\>` fail silently. Our recursive sanitizer handles strings, nested maps, and lists.

**Vision Pipeline**: High-resolution images are pre-compressed to ≤512px max dimension before GPU inference, preventing `clEnqueueMapBuffer` out-of-memory crashes on mid-range devices.

## 4. Innovations for On-Device 2B Agents ("Kharwal Originals")

Cloud agents (with 200B+ parameters) don't need these. We invented them because a 2B model does:

**The Withholding Pattern**: Recoverable errors are *silently retried* without any UI feedback. The user sees only "Thinking..." while AetherCore runs exponential backoff (500ms → 8s cap, ±20% jitter). Error messages surface **only** after all retries fail — replicating the seamless UX of cloud models on local hardware.

**Adaptive Turn Depth**: Simple tasks ("list files") get 8 turns; complex tasks ("build a project") get 25. Cloud agents can afford unlimited turns, but on-device, every turn drains battery.

**Sandbox Awareness Injection**: Every 3 turns, a lightweight `ls -la` snapshot is injected into history. 2B models "forget" directory contents between turns; this prevents hallucinating missing files.

**7-Layer Context Pipeline**: Before every model call, history passes through MicroCompact (HEAD+TAIL truncation at 2000 chars), system message compaction, sandbox injection, AI-powered summarization (at >20K tokens), audio/thinking stripping, and pair-aware trimming (never splits a tool call from its result).

## 5. Shopkeeper Ledger Mode

Agent Kharwal auto-detects when a user dictates shop inventory in Hindi/Hinglish (e.g., *"5 kilo cheeni, Ramu ke khate mein likh do"*). It parses items, quantities, and units into a structured ledger table, creates the folder, and saves — transforming a voice message into organized bookkeeping without any training.

## 6. The Gauntlet: Proving Enterprise-Grade Resilience

We subjected Agent Kharwal to adversarial attacks:
- **Infinite Spam**: `yes "text" | head -n 1000` → SpectralOps detected >90% duplicate lines, killed process instantly.
- **Sandbox Escape**: `ls /system/etc` → PathJailer canonicalized the path, detected it's outside the sandbox, rejected pre-execution.
- **Payload Injection**: `$((i+1))` arithmetic → SentryPurity caught the `$(` pattern, blocked before shell invocation.
- **Retry Loop Drain**: The agent retried 5 variations → Adaptive Turn Depth Limit severed the loop, preserving battery.

## 7. Impact & Future

For the shopkeeper logging inventory without Wi-Fi, or the student summarizing physics notes at 2 AM in airplane mode, Agent Kharwal provides absolute privacy, zero latency, and 100% uptime. By pushing Gemma 4 E2B to its limits with rigorous system architecture, we prove that the developing world does not need the cloud to harness autonomous intelligence.

---

## 8. Project Links
*   **Public Code Repository:** [GitHub](https://github.com/AbhiKhrwl/Agent-Khrwal)
*   **Live Demo / APK Release:** [GitHub Releases](https://github.com/AbhiKhrwl/Agent-Khrwal/releases)
*   **Video Demo:** [YouTube](https://youtu.be/sx3kzZp7tuU)
