# 🔱 Agent Kharwal — On-Device AI Agent

> **Your phone is the server. Your privacy is the firewall. Zero cost. Forever.**

Agent Kharwal is a Flutter-based autonomous AI agent that runs **entirely on your device** using Google's **Gemma 4** model via **LiteRT**. No cloud. No subscription. No data leaving your phone. Built for students who can't afford paid AI and shopkeepers who don't have stable internet.

**🏆 Submitted to the [Gemma 4 Good Hackathon](https://kaggle.com/competitions/gemma-4-good-hackathon)**

---

## 🎯 The Problem

| Reality | Cloud AI | Agent Kharwal |
|---------|----------|---------------|
| **Cost** | $20-200/month | ₹0 forever |
| **Internet** | Always required | Never needed |
| **Privacy** | Data goes to cloud | Data stays on device |
| **Target users** | Developers, corporations | Students, shopkeepers |
| **Autonomous actions** | Limited | Full tool execution in sandbox |

A student in a government school can't afford GPT-4. A shopkeeper in a small town can't rely on spotty internet. Agent Kharwal puts **frontier AI intelligence** directly in their hands — for free.

---

## ✨ Key Features

### Dual-Mode AI
- **Just Talk** — Clean chat interface for homework help, writing, brainstorming
- **Let's Do** — Full autonomous agent with shell commands, file operations, and self-correction

### Agentic Tool Execution (7 Tools)
- 🖥️ **BashTool** — Execute shell commands in a hardened sandbox (SpectralOps)
- 📁 **File Explorer (Vault)** — Browse, create, share, and download agent-created files
- 📂 **DirectoryBriefingTool** — Smart folder summarization with file sizes
- ✏️ **FileWriteTool** — Create and overwrite files with path-jailed safety
- 📖 **FileReadTool** — Read file contents (up to 10K chars)
- 🔔 **NotificationAgentTool** — Native OS notifications
- 🎤 **VoiceMunshiTool** — Voice input via push-to-talk

### Enterprise-Grade Security: The Omega Fortress
- **SentryPurity** — Pre-execution command validation, blocks shell injection (`$()`, backticks, `eval`, `rm -rf`, `sudo`, heredocs)
- **PathJailer** — Symlink-aware directory traversal prevention with canonicalized path boundaries
- **SpectralOps** — Sandboxed shell with 15-second timeout, 50-PID cap, orphan process reaping, and infinite loop detection
- **Environment Scrubbing** — Synthetic PATH, no host secrets exposed

### Pure Local Inference Engine
- **Gemma 4 E2B** — via `flutter_gemma` ^0.15.1 → LiteRT-LM C++ runtime
- **GPU↔CPU Multi-Level Fallback** — per-prompt, cross-prompt, permanent blacklist
- **Stream Inactivity Watchdog** — 60-second timeout detects hung prefill
- **Vision Pipeline** — Image pre-compression to ≤512px for GPU-safe patches

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────┐
│           PRESENTATION LAYER                     │
│  ModelPickerScreen → GajrajOracleScaffold        │
│  ChatBubble, ToolCard, MarkdownBubble,           │
│  CollapsibleThought, SandboxExplorer,            │
│  SessionDrawer, ActivityDrawer                   │
├──────────────────────────────────────────────────┤
│           ORCHESTRATION LAYER                    │
│  AetherCore (1,514 lines)                        │
│  ├─ Autonomous while-loop (_runInternalPulse)    │
│  ├─ Withholding Pattern (silent error recovery)  │
│  ├─ Streaming Tool Executor (mid-stream start)   │
│  ├─ Text-to-Tool Interceptor                     │
│  ├─ Adaptive Turn Depth (8/15/25)                │
│  ├─ AI-Powered Context Summarization             │
│  └─ Sandbox Awareness Injection (every 3 turns)  │
│                                                  │
│  CipherProtocol — tool/thought parsing           │
├──────────────────────────────────────────────────┤
│           EXECUTION LAYER                        │
│  AgentRouter (ordered batch + fuzzy name match)  │
│  SentryPurity + PathJailer (security)            │
├──────────────────────────────────────────────────┤
│           TOOL LAYER                             │
│  BashTool → SpectralOps (sandboxed shell)        │
│  FileRead, FileWrite, DirectoryBriefing          │
│  DataInjector, VoiceMunshi, NotificationAgent    │
├──────────────────────────────────────────────────┤
│           INFERENCE ENGINE                       │
│  LocalInferenceService (838 lines)               │
│  flutter_gemma → LiteRT-LM (C++ runtime)         │
│  GPU↔CPU fallback chain, Divine Mutex            │
├──────────────────────────────────────────────────┤
│           PERSISTENCE                            │
│  SessionManager — JSON file-based persistence    │
│  Per-session: messages.json + tool_history.json  │
└──────────────────────────────────────────────────┘
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
flutter run
```

### First Run
1. App launches → Model Picker screen
2. Download or select Gemma 4 E2B model (.litertlm format)
3. Model validated via size check
4. Start chatting — 100% local, zero internet

---

## 🔬 Technical Depth — How Gemma 4 Is Used

### On-Device Inference
- **flutter_gemma ^0.15.1** → LiteRT-LM engine binding
- GPU delegation (OpenCL/Metal), automatic CPU fallback chain
- Streaming token-by-token via `InferenceEvent` sealed class (7 event types)

### Native Function Calling
- Gemma 4 generates `<|tool_call|>` tokens via `createChat(tools: ...)`
- **Text-to-Tool Interceptor** — parses `\`\`\`bash` code blocks as fallback (~40% of the time E2B uses text instead of native tokens)
- Self-correction loop with error-specific recovery guidance

### Agentic Loop (AetherCore)
```
User Input → Context Optimization (7-layer pipeline) → Gemma 4 Inference
  → Stream Events → Tool Detected?
    → YES: SentryPurity validation → SpectralOps execution → Inject results → Loop
    → NO: Emit response → Break
```

### Context Management
- **7-Layer Pipeline**: MicroCompact → CompactSystem → SandboxInject → AutoCompact → StripAudio → StripThinking → PairAwareTrim
- **AI Summarization**: When >20K tokens, model summarizes its own history into 4-5 bullets
- **Pair-Aware Trimming**: Never splits between a tool call and its result

### "Kharwal Originals" — Unique to On-Device 2B Agents
1. **Adaptive Turn Depth** — 8/15/25 turns based on task complexity keywords
2. **Sandbox Awareness Injection** — `ls -la` snapshot every 3 turns (2B models forget)
3. **Text-to-Tool Interceptor** — Catches bash in markdown when native calling fails
4. **Gemma 4 Escape Token Sanitizer** — Strips `<|"|\>` from tool params

---

## 🏆 Competition Tracks

| Track | How Agent Kharwal Qualifies |
|-------|----------------------------|
| **Main Track** | Full autonomous agent with 11,000+ LOC, novel architecture |
| **Digital Equity & Inclusivity** | Zero-cost, offline, Hindi/Hinglish voice, shopkeeper ledger mode |
| **Future of Education** | Free AI tutor for students without internet access |
| **Safety & Trust** | Omega Fortress: 3-tier security + transparent Activity Log |
| **LiteRT** | Gemma 4 runs via LiteRT-LM on-device inference engine |
| **Cactus** | Local-first mobile app with dual-mode task routing |

---

## 📁 Project Structure

```
lib/
├── core/
│   ├── domain/           # Entities (Message, InferenceEvent, ToolEntities)
│   │   ├── entities/     # Data models + sealed classes
│   │   └── interfaces/   # ITool, IInputAdapter
│   └── infrastructure/
│       ├── heartbeat/    # AetherCore — autonomous agent brain (1,514 LOC)
│       ├── handshake/    # CipherProtocol — tool/thought parsing
│       ├── router/       # AgentRouter — tool dispatch + fuzzy matching
│       ├── security/     # SentryPurity + PathJailer
│       ├── services/     # LocalInferenceService, SessionManager, ProcessUtils
│       ├── tools/        # 7 tools: Bash, FileR/W, Directory, Voice, Notification
│       └── prompts/      # KharwalBehavior — modular system prompt
└── ui/
    ├── faces/            # ModelPickerScreen + GajrajOracleScaffold
    ├── widgets/          # ChatBubble, ToolCard, Vault, Activity/Session drawers
    └── theme/            # DivinePalette color system
```

---

## 📜 License

Apache 2.0 — Built for the Gemma 4 Good Hackathon.

---

*Built with ❤️ for the people who need AI the most but can afford it the least.*

*"Sacche khojkarta ko raasta pata nahi hota, wo khojta hai."*
