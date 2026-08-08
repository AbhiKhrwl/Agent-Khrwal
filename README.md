# 🔱 Agent Kharwal — On-Device AI Agent & CLI Powerhouse

> **Your phone is the server. Your privacy is the firewall. Zero cost. Forever.**

Agent Kharwal is a **40,000+ LOC** Flutter-based autonomous AI agent that runs **entirely on your device** using Google's **Gemma 4** model via **LiteRT** — but goes far beyond a simple chatbot. It ships with a **full-featured terminal UI (TUI)**, a **41-tool agentic engine**, a **multi-provider waterfall inference system**, **Vim-modal input**, **MCP support**, **sub-agent orchestration**, and **enterprise-grade security** — all built from scratch in Dart.

**🏆 Submitted to the [Gemma 4 Good Hackathon](https://kaggle.com/competitions/gemma-4-good-hackathon)**

---

## 🎯 The Problem

| Reality | Cloud AI | Agent Kharwal |
|---------|----------|---------------|
| **Cost** | $20–200/month | ₹0 forever |
| **Internet** | Always required | Never needed (on-device) |
| **Privacy** | Data goes to cloud | Data stays on device |
| **Target users** | Developers, corporations | Students, shopkeepers, developers |
| **Autonomous actions** | Limited | 41 tools, sub-agents, plan mode |
| **Interface** | Web browser | Native Flutter GUI + Premium TUI |

A student in a government school can't afford GPT-4. A shopkeeper in a small town can't rely on spotty internet. Agent Kharwal puts **frontier AI intelligence** directly in their hands — for free.

---

## 📊 Project at a Glance

| Metric | Value |
|--------|-------|
| Total Lines of Code | **40,000+** |
| Dart Files | **144** production + **14** test |
| Agentic Tools | **41** |
| Slash Commands | **22** |
| Inference Providers | **7** (Gemini, Groq, NVIDIA, OpenRouter, Ollama, Custom, On-Device) |
| Core Services | **21** |
| CLI Components | **51** files |
| Test Suite | **14** test files |
| Architecture | Clean Architecture (Domain → Infrastructure → Presentation) |

---

## ✨ Key Features

### 🖥️ Dual Interface — Flutter GUI + Premium Terminal UI

**Flutter GUI** (`GajrajOracleScaffold` — 3,768 LOC)
- Complete chat interface with voice input, markdown rendering, and tool execution cards
- Session management drawer, activity log, and sandbox file explorer
- Model picker screen with on-device model validation

**Terminal UI** (`TerminalForge` — 1,511 LOC)
- Alternate-screen TUI with double-buffered delta rendering (zero flicker)
- 7-line pixel-art ASCII shield mascot in the welcome banner
- Dynamic terminal resize handling via `ViewportSentry`
- Real-time status strip with provider info, tool count, activity spinner, and performance metrics
- `ChromeAura` 24-bit TrueColor ANSI theme system with 9 semantic colors
- `ScrollWeaver` — full markdown renderer for terminal (headers, tables, code blocks, lists, inline formatting)
- `DivineWeaverCacher` — MRU token-caching lexer (500 entries) with fast-path markdown bypass
- `DivineSoulTelemetry` — real-time git status, API metrics, and system load sidebar

### ⌨️ Vim-Modal Input System
- 4 modal states: `NORMAL`, `INSERT`, `COMMAND`, `QUESTION`
- `j`/`k` for log scrolling, `g`/`G` for top/bottom, `i`/`a` for insert, `:` for commands
- Raw ANSI byte-stream parsing with paste-burst detection (>3 chars in <5ms)
- Inline autocomplete hints with Tab/Right-arrow acceptance
- History navigation with Up/Down arrows
- Toggle via `/keybinds` or `/vim`

### 🧠 Autonomous Agent Core — AetherCore (1,968 LOC)
- Multi-turn autonomous tool execution loop (`_runInternalPulse`)
- Withholding Pattern — silent error recovery without polluting UI
- Streaming Tool Executor — mid-stream tool detection and start
- Text-to-Tool Interceptor — catches ` ```bash ` in markdown when native calling fails
- Adaptive Turn Depth (8/15/25 turns based on task complexity)
- AI-Powered Context Summarization when >20K tokens
- Sandbox Awareness Injection (workspace snapshot every 3 turns)
- Denial hard-stop guard and same-tool loop detection
- Fatal engine error detection (SIGSEGV, tensor allocation failures)

### 🔧 41-Tool Agentic Engine

| Category | Tools |
|----------|-------|
| **Shell & System** | `bash` (sandboxed), `spectral_ops`, `sleep`, `cron_tools`, `task_tools` |
| **File Operations** | `file_read`, `file_write`, `file_edit`, `directory_briefing`, `glob`, `grep` |
| **Git Native** | `git_status`, `git_diff`, `git_commit`, `git_branch`, `git_log`, `worktree_tools` |
| **Code Intelligence** | `lsp_tool` (Language Server Protocol), `project_mapper`, `verify_project` |
| **Planning & Memory** | `enter_plan_mode`, `exit_plan_mode`, `todo_write`, `search_memory`, `smart_context_gather` |
| **Multi-Agent** | `agent_tool` (sub-agent spawner), `send_message`, `team_tools` |
| **Web & MCP** | `web_search` (DuckDuckGo), `web_fetch` (HTML→Markdown), `mcp_tools` |
| **User Interaction** | `ask_user_question`, `notification_agent`, `voice_munshi`, `data_injector` |
| **Meta-Tools** | `tool_search`, `tool_describe`, `tool_call`, `rollback`, `config`, `brief`, `notebook_edit`, `skill_tool` |
| **Scaling** | `apex_tool_scaling_engine` — Progressive Tool Disclosure (hides tools when schema >10K tokens) |

### 🌊 Multi-Provider Waterfall Inference

```
User Input → Secret Redaction (Chowkidar) → Health-Sorted Provider Pool
  → Waterfall through providers:
    ├─ Gemini (Google AI)
    ├─ Groq (fast inference)
    ├─ NVIDIA (NIM API)
    ├─ OpenRouter (multi-model)
    ├─ Ollama (local large models)
    ├─ Custom (OpenAI-compatible)
    └─ On-Device (Gemma 4 via LiteRT)
  → Error Classification → Auto-Cooldown → Context Overflow Compaction → Retry
```

- **`ProviderHealthRegistry`** — tracks success rates, classifies failures (rate limit, auth, context overflow, network, stream error, policy blocked)
- **Automatic context compaction** — if context overflows, `AetherHistoryCompactor` summarizes history before retrying with the next provider
- **Smart failover UI** — real-time TUI notifications showing provider switches and cooldown timers
- **Ollama auto-retry** — 3 retries with progressive backoff for local model crashes
- **Cognitive optimization** — filters tools to ~10 essentials for local models to prevent latency

### 🔌 MCP (Model Context Protocol) Integration
- Full MCP server lifecycle management via `McpRegistry`
- Server-Sent Events (SSE) client with JSON-RPC 2.0 request/response framing
- Namespaced tool calls: `mcp__<server>__<function>`
- Native MCP tools: `list_mcp_resources`, `read_mcp_resource`
- Progressive Tool Disclosure — auto-hides MCP tools when schema size exceeds 10K tokens

### 🤖 Multi-Agent Orchestration
- **Sub-Agent System** — spawn autonomous child agents with `agent_tool`
- **Inter-Agent Messaging** — `send_message_tool` for direct agent-to-agent communication
- **Swarm Teams** — `team_tools` and `SwarmTeamManager` for multi-agent collaboration
- **SubAgent Supervisor** — hierarchical monitoring of child agent lifecycle

### 📋 22 Slash Commands

| Command | Purpose |
|---------|---------|
| `/help` | Command guide and shortcut cheat sheet |
| `/tools` | Inspect active tool schemas and execution status |
| `/models` | List, switch, and test available models |
| `/config` | View and edit environment configuration |
| `/switch` | Hot-swap active inference provider |
| `/clear` | Wipe viewport logs |
| `/history` | Conversation history browser |
| `/session` | Session switching, creating, deleting |
| `/undo` | Revert last file modification via RollbackTool |
| `/cancel` | Instantly halt ongoing execution |
| `/compact` | Trigger history compactor manually |
| `/export` | Export full session transcript to Markdown/JSON |
| `/stats` | Detailed API call usage and token consumption radar |
| `/curator` | Context snapshot manager |
| `/init` | Re-initialize project workspace |
| `/review` | Code change review and diff auditor |
| `/speculate` | Run speculative code sandbox test |
| `/btw` | Side-question injection without polluting turn state |
| `/limit` | View context window limits and token usage |
| `/keybinds` | Keybinding configuration (Vim toggle) |
| `/refresh_cache` | Evict prompt caches and reload global memory |
| `/vim` | Alias for `/keybinds` |

### 🔒 Enterprise-Grade Security: The Omega Fortress

- **`SentryPurity`** — Pre-execution command validation, blocks shell injection (`$()`, backticks, `eval`, `rm -rf`, `sudo`, heredocs)
- **`PathJailer`** — Symlink-aware directory traversal prevention with canonicalized path boundaries
- **`SpectralOps`** — Sandboxed shell with 15-second timeout, 50-PID cap, orphan process reaping, and infinite loop detection
- **`SecretGuardService`** (Chowkidar) — Automatic API key, token, and password redaction before sending to LLMs
- **`ToolSafetyGuard`** — Pre-dispatch security verification for all tool calls
- **Environment Scrubbing** — Synthetic PATH, no host secrets exposed

### 🧪 Pure Local Inference Engine
- **Gemma 4 E2B** — via `flutter_gemma` ^0.15.1 → LiteRT-LM C++ runtime
- **GPU↔CPU Multi-Level Fallback** — per-prompt, cross-prompt, permanent blacklist
- **Stream Inactivity Watchdog** — 60-second timeout detects hung prefill
- **Vision Pipeline** — Image pre-compression to ≤512px for GPU-safe patches
- **`HybridInferenceCoordinator`** — Seamless orchestration between on-device and cloud providers

---

## 🏗️ Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        PRESENTATION LAYER                               │
│  ┌─────────────────────┐  ┌──────────────────────────────────────────┐  │
│  │   Flutter GUI        │  │   Terminal UI (TUI)                      │  │
│  │   GajrajOracleScaff  │  │   TerminalForge + CLIInputAdapter       │  │
│  │   ChatBubble, Vault  │  │   ChromeAura, ScrollWeaver, Telemetry   │  │
│  │   ToolCard, Session  │  │   VirtualConsoleList, DoubleBuffer      │  │
│  │   ActivityDrawer     │  │   22 Slash Commands + Vim Modes          │  │
│  └─────────────────────┘  └──────────────────────────────────────────┘  │
├──────────────────────────────────────────────────────────────────────────┤
│                        ORCHESTRATION LAYER                              │
│  AetherCore (1,968 LOC)                                                 │
│  ├─ Autonomous while-loop (_runInternalPulse)                           │
│  ├─ Withholding Pattern (silent error recovery)                         │
│  ├─ Streaming Tool Executor (mid-stream start)                          │
│  ├─ Text-to-Tool Interceptor                                           │
│  ├─ Adaptive Turn Depth (8/15/25)                                       │
│  ├─ AI-Powered Context Summarization                                    │
│  ├─ Sandbox Awareness Injection (every 3 turns)                         │
│  └─ Sub-Agent Supervisor + Swarm Team Manager                           │
│                                                                         │
│  CipherProtocol — tool/thought parsing                                  │
│  PlanModeCoordinator — architectural planning mode ("Sutra")            │
├──────────────────────────────────────────────────────────────────────────┤
│                      INFERENCE LAYER                                    │
│  ┌──────────────────┐  ┌─────────────────────────────────────────────┐  │
│  │ On-Device Engine  │  │  Cloud Waterfall (7 Providers)              │  │
│  │ Gemma 4 → LiteRT  │  │  Gemini → Groq → NVIDIA → OpenRouter →   │  │
│  │ GPU↔CPU Fallback  │  │  Ollama → Custom (OpenAI-compatible)       │  │
│  │ Divine Mutex Lock │  │  ProviderHealthRegistry + Auto-Cooldown    │  │
│  └──────────────────┘  └─────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────────────────────────────┤
│                        EXECUTION LAYER                                  │
│  AgentRouter (ordered batch + fuzzy name match)                         │
│  ToolRegistry (41 tools) + ApexToolScalingEngine                        │
│  SentryPurity + PathJailer + ToolSafetyGuard (security)                 │
├──────────────────────────────────────────────────────────────────────────┤
│                          TOOL LAYER (41 Tools)                          │
│  Shell: BashTool → SpectralOps | Files: Read, Write, Edit, Glob, Grep  │
│  Git: Status, Diff, Commit, Branch, Log, Worktree                       │
│  Code: LSP, ProjectMapper, VerifyProject | Web: Search, Fetch           │
│  Agent: SubAgent, SendMessage, TeamTools | MCP: Tools, Resources        │
│  Planning: PlanMode, Todo, Memory, SmartContext, Curator                │
│  Meta: ToolSearch, ToolDescribe, ToolCall, Rollback, Config, Skills     │
├──────────────────────────────────────────────────────────────────────────┤
│                        PERSISTENCE LAYER                                │
│  SessionManager — per-session JSON persistence                          │
│  MemoryDreamScheduler — long-term memory consolidation                  │
│  AtomicWriteEngine — safe file writes with temp-file swap               │
│  ConfigManager — user preferences and provider keys                     │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 📁 Project Structure

```
lib/                                    # 40,000+ lines of Dart
├── main.dart                           # Flutter app entry point
├── cli/                                # ── Terminal UI Engine (13,000+ LOC) ──
│   ├── terminal_forge.dart             # TUI rendering engine (1,511 LOC)
│   ├── cli_input_adapter.dart          # Vim-modal input handler (1,039 LOC)
│   ├── commands/
│   │   ├── apex_command.dart           # Command base classes
│   │   ├── command_parser.dart         # Slash/colon command parser
│   │   ├── command_registry.dart       # 22 registered commands
│   │   └── commands/                   # 22 command implementations
│   ├── components/
│   │   ├── divine_soul_telemetry.dart  # Real-time metrics sidebar (725 LOC)
│   │   ├── divine_weaver_cacher.dart   # Cached markdown lexer
│   │   ├── oracle_heartbeat.dart       # Animated Braille spinner
│   │   ├── scroll_weaver.dart          # Terminal markdown renderer
│   │   └── tool_chrome.dart            # Tool execution formatters
│   ├── input/
│   │   ├── ansi_key_parser.dart        # Raw ANSI escape parser
│   │   └── cli_interactive_dialogs.dart # Interactive card selectors
│   ├── renderer/
│   │   ├── double_buffered_screen.dart # Delta-only screen updates
│   │   ├── viewport_sentry.dart        # Terminal resize detection
│   │   └── virtual_console_list.dart   # ANSI-aware virtual scrollbox
│   ├── services/
│   │   ├── api_call_radar.dart         # API usage tracking
│   │   ├── config_manager.dart         # Provider key management
│   │   ├── plugin_manager.dart         # Plugin system (hooks, consent)
│   │   ├── provider_health_registry.dart # Health tracking & cooldown
│   │   └── inference_bridges/          # 7 provider bridges + setup wizard
│   └── theme/
│       └── chrome_aura.dart            # 24-bit TrueColor ANSI theme
├── core/                               # ── Agent Core Engine (19,000+ LOC) ──
│   ├── domain/
│   │   ├── entities/                   # Message, InferenceEvent, ToolEntities
│   │   └── interfaces/                 # ITool, IInputAdapter contracts
│   └── infrastructure/
│       ├── heartbeat/
│       │   ├── aether_core.dart        # Autonomous agent brain (1,968 LOC)
│       │   ├── history_compactor.dart  # Context window management (608 LOC)
│       │   └── tool_safety_guard.dart  # Pre-dispatch security check
│       ├── handshake/
│       │   └── cipher_protocol.dart    # Tool/thought token parser
│       ├── prompts/
│       │   ├── kharwal_behavior.dart   # Dynamic system prompt
│       │   └── prompt_cache_optimizer.dart # Prefix boundary alignment
│       ├── router/
│       │   ├── agent_router.dart       # Tool dispatch + fuzzy matching
│       │   └── tool_registry.dart      # 41-tool registration hub
│       ├── security/
│       │   ├── sentry_purity.dart      # Command injection blocker
│       │   └── path_jailer.dart        # Directory traversal prevention
│       ├── services/                   # 21 infrastructure services
│       └── tools/                      # 41 tool implementations
└── ui/                                 # ── Flutter GUI (7,500+ LOC) ──
    ├── faces/
    │   ├── model_picker_screen.dart    # Model selection UI
    │   └── gajraj/
    │       └── gajraj_scaffold.dart    # Master GUI scaffold (3,768 LOC)
    ├── theme/
    │   └── divine_palette.dart         # Flutter color system
    └── widgets/                        # 8 modular UI widgets
        ├── chat_bubble.dart
        ├── tool_card.dart
        ├── sandbox_explorer.dart
        ├── activity_drawer.dart
        ├── session_drawer.dart
        ├── markdown_bubble.dart
        ├── collapsible_thought.dart
        └── collapsible_tool_stream.dart

bin/
└── kharwal_cli.dart                    # CLI entry point (708 LOC)

test/                                   # 14 test files
├── apex_tool_protocol_test.dart
├── provider_health_registry_test.dart
├── plan_mode_sutra_test.dart
├── self_healing_test.dart
└── ... (10 more test files)
```

---

## 🚀 Getting Started

### Prerequisites
- Flutter 3.x (Dart 3.9+)
- Android device (for local Gemma 4 inference) or macOS

### Setup
```bash
git clone https://github.com/AbhiKhrwl/Agent-Khrwal.git
cd agent-kharwal
flutter pub get
```

### Run the Flutter GUI
```bash
flutter run
```

### Run the Terminal UI (CLI Mode)
```bash
dart run bin/kharwal_cli.dart
```
First run launches an interactive **Setup Wizard** to configure your inference providers (API keys for Gemini, Groq, NVIDIA, etc.) or connect a local Ollama instance.

Use `--configure` or `-c` to re-run the wizard anytime:
```bash
dart run bin/kharwal_cli.dart --configure
```

---

## 🔬 Technical Depth — How Gemma 4 Is Used

### On-Device Inference
- **flutter_gemma ^0.15.1** → LiteRT-LM engine binding
- GPU delegation (OpenCL/Metal), automatic CPU fallback chain
- Streaming token-by-token via `InferenceEvent` sealed class (7 event types)
- `HybridInferenceCoordinator` seamlessly switches between on-device and cloud providers

### Native Function Calling
- Gemma 4 generates `<|tool_call|>` tokens via `createChat(tools: ...)`
- **Text-to-Tool Interceptor** — parses `` ```bash `` code blocks as fallback (~40% of the time E2B uses text instead of native tokens)
- Self-correction loop with error-specific recovery guidance

### Agentic Loop (AetherCore)
```
User Input → Context Optimization (7-layer pipeline) → Inference
  → Stream Events → Tool Detected?
    → YES: SentryPurity validation → SpectralOps execution → Inject results → Loop
    → NO: Emit response → Break
```

### Context Management
- **7-Layer Pipeline**: MicroCompact → CompactSystem → SandboxInject → AutoCompact → StripAudio → StripThinking → PairAwareTrim
- **AI Summarization**: When >20K tokens, model summarizes its own history into 4–5 bullets
- **Pair-Aware Trimming**: Never splits between a tool call and its result
- **Prompt Cache Optimizer**: 1,024 byte boundary alignment for cloud prompt caching hits

### 21 Infrastructure Services
- `ApexStatefulShell` — persistent interactive bash session state
- `PersistentShellManager` — long-running PTY/shell process pool
- `MemoryDreamScheduler` — autonomous background memory consolidation
- `PredictiveSuggestCoordinator` — real-time next-command prediction
- `REPLBridgeCoordinator` — interactive REPL connector
- `ApexCuratorEngine` — context pruning and historical snapshot curation
- `MagicDocsCoordinator` — automated documentation generation
- `SpeculativeSandbox` — isolated execution sandbox for untrusted operations
- `BackgroundTaskService` — async task runner with notifications
- `StreamingContextScrubber` — dynamic prompt content sanitizer
- `ApexStreamingThoughtScrubber` — stateful lookahead token scrubber for `<think>`, `<reasoning>`, `<memory-context>` tags
- And 10 more...

### "Kharwal Originals" — Unique Innovations
1. **Adaptive Turn Depth** — 8/15/25 turns based on task complexity keywords
2. **Sandbox Awareness Injection** — `ls -la` snapshot every 3 turns (2B models forget fast)
3. **Text-to-Tool Interceptor** — Catches bash in markdown when native calling fails
4. **Gemma 4 Escape Token Sanitizer** — Strips `<|"|\>` from tool params
5. **Progressive Tool Disclosure** — Auto-hides tools when schema exceeds 10K tokens, exposes lightweight bridge tools
6. **Secret Redaction (Chowkidar)** — Pre-flight API key/token scrubbing before LLM inference
7. **Provider Waterfall with Health Tracking** — Automatic failover with error classification, cooldown timers, and context overflow compaction
8. **Vim-Modal Terminal Input** — Full 4-mode state machine with raw ANSI byte parsing
9. **ChromeAura TrueColor Theme** — 24-bit color palette mapped from Flutter's DivinePalette to ANSI
10. **OracleHeartbeat Spinner** — Braille dot animation with color transitions (Cyan 0–5s → Gold 5–15s → Crimson 15s+)

---

## 🏆 Competition Tracks

| Track | How Agent Kharwal Qualifies |
|-------|----------------------------|
| **Main Track** | Full autonomous agent with 40,000+ LOC, 41 tools, novel architecture |
| **Digital Equity & Inclusivity** | Zero-cost, offline, Hindi/Hinglish voice, shopkeeper ledger mode |
| **Future of Education** | Free AI tutor for students without internet access |
| **Safety & Trust** | Omega Fortress: multi-tier security + transparent Activity Log |
| **LiteRT** | Gemma 4 runs via LiteRT-LM on-device inference engine |
| **Cactus** | Local-first mobile app with dual-mode task routing |

---

## 🎨 The TUI Experience

```
╔════════════════════════════════ Agent Kharwal v1.0 ═══════════════════════════════╗
║                                          │ Tips for getting started               ║
║               Welcome back!              │ /help to see all commands              ║
║                                          │ ────────────────────────────           ║
║                  ▐█  ██▙                 │ What's new                             ║
║                   █ ██▘                  │ Web tools now sandbox-safe             ║
║                   ██▌                    │ Pixel art mascot added                 ║
║                  ███ ██                  │ Premium heavy-border UI                ║
║                  █▌█▌█▌                  │ ────────────────────────────           ║
║                                          │ 41 tools armed                         ║
║  Provider: NVIDIA                        │ Workspace: ~/my-project                ║
╚══════════════════════════════════════════════════════════════════════════════════╝
  ⟨K⟩ hello
  ⟨K⟩ [Waterfall] Attempting NVIDIA with model: google/gemma-4-31b-it

  Hello! How can I help you today?

  ├──────────────────────────────────────────────────────────────────────────────┤
  │ NVIDIA google/gemma-4-31... │ 41 tools    😴 Idle     ░░░░░░░░░░ 0% │ 0.0s │
  ⟨K⟩  INSERT
```

Features visible in the TUI:
- **Crown Banner** with pixel-art mascot, tips, and workspace info
- **Waterfall log** showing provider selection
- **Status strip** with provider, tool count, activity spinner, and timing
- **Vim mode badge** (INSERT/NORMAL/COMMAND/QUESTION)
- **ChromeAura colors** — Trident cyan, Oracle white, Mist slate, Celestial amber

---

## 🧪 Test Suite

14 test files covering critical subsystems:

| Test File | Coverage Area |
|-----------|---------------|
| `apex_tool_protocol_test.dart` | Tool parsing and execution protocol |
| `provider_health_registry_test.dart` | Provider health tracking and cooldown |
| `plan_mode_sutra_test.dart` | Plan mode state machine |
| `self_healing_test.dart` | Error recovery and self-correction |
| `apex_tool_scaling_engine_test.dart` | Progressive tool disclosure |
| `api_call_radar_test.dart` | API usage tracking |
| `apex_stateful_shell_test.dart` | Persistent shell state |
| `apex_curator_and_compactor_test.dart` | Context management |
| `phase3_hardening_test.dart` | Security hardening |
| `demo_scenario_test.dart` | End-to-end demo flows |
| `researched_blueprints_test.dart` | Architecture blueprints |
| `refresh_cache_command_test.dart` | Cache management |
| `apex_advanced_machinery_test.dart` | Advanced engine internals |
| `widget_test.dart` | Flutter UI widgets |

Run all tests:
```bash
flutter test
```

---

## 📜 License

Apache 2.0 — Built for the Gemma 4 Good Hackathon.

---

*Built with ❤️ for the people who need AI the most but can afford it the least.*

*"Sacche khojkarta ko raasta pata nahi hota, wo khojta hai."*
