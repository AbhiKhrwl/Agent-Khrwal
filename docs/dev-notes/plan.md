# Apex Lite: Hackathon Winning Strategy & Project Plan

## 🔱 Vision: Digital Equity & Local-First Autonomy
**Apex Lite** is a fault-tolerant, autonomous AI agent designed for low-resource environments. It brings OS-level automation to the "next billion users" (shopkeepers, students, rural workers) using local-only LLMs (Gemma 2B) on $150 devices without internet.

---

## 🏗️ 1. The "Strategic Cut" (What to include vs. hide)

To win, we show "Engineering Excellence" without giving away our business secrets.

### ✅ Included (The Winning Core)
1.  **AetherCore (Lite):** The self-healing recovery loop. Shows how we fix LLM hallucinations automatically. (Stripped of Cloud APIs).
2.  **CipherProtocol:** Our custom XML/Thought-Channel parser optimized for small models.
3.  **BashTool & SpectralOps:** The "Executioner". Demonstrates safe, sandboxed OS-level task fulfillment (File CRUD, directory management).
4.  **PathJailer:** Enterprise-grade security that ensures the AI stays within its sandbox.
5.  **DirectoryBriefingTool:** A "Wow" feature that summarizes local folders instantly without internet.

### ❌ Excluded (The SaaS Moat - PRIVATE)
1.  **HybridInferenceService:** No OpenAI/Claude routing. This competition is for Gemma.
2.  **Isar Context Manager:** We will use simple in-memory history for the 3-minute demo to avoid DB complexity/leaks.
3.  **ChargingPulseEngine:** Our "Killer Pro Feature" for background autonomy stays in the vault.
4.  **DataInjectorTool (AppleScript):** Too risky and macOS specific; we focus on cross-platform Bash.
5.  **Multi-Persona UIs:** We will use a clean, "Hacker/Terminal" style UI for the hackathon.

### ✅ Added (Phase 3.5 — Model Picker Feature)
1. **Local Model Picker:** Users select pre-downloaded model files from local storage via file picker — no mandatory download.
2. **Multi-Model Support:** Gemma 2B, DeepSeek 1.3B, Qwen2 1.5B, Phi-3 Mini + CPU/GPU backend toggle.
3. **Premium Boot Flow:** Splash → Model picker (with drag-zone UX) → Main chat.

---

## 📽️ 2. The Winning Pitch (The 3-Minute Story)

We won't just show a chatbot. We will show a **Fault-Tolerant System**.

*   **Hook (0:00-0:30):** Wi-Fi is OFF. We are on a mid-range device. We introduce the "Logistics/Shopkeeper" problem.
*   **The Action (0:30-1:30):**
    *   Shopkeeper says: *"Record a sale of 500 INR for Rice."*
    *   System executes `echo "Sale: 500, Item: Rice" >> sales.csv` via BashTool.
    *   Student says: *"What's in my study folder?"*
    *   System summarizes files via DirectoryBriefingTool.
*   **The "God Move" (1:30-2:30):**
    *   Model makes a syntax error in its tool call.
    *   UI shows the Error.
    *   **AetherCore** detects the failure, sends the error back to Gemma, and Gemma **self-corrects** the command.
    *   *Result:* Task completed successfully on the second try without user intervention.
*   **Closing (2:30-3:00):** Impact on Digital Equity. Technology for the 99%.

---

## 🛠️ 3. Technical Implementation Plan (12 Days)

### Phase 1: Surgical Extraction (Days 1-3)
*   Scaffold new Flutter project `apex_lite`.
*   Port `AetherCore`, `CipherProtocol`, `BashTool`, and `SpectralOps`.
*   **Hard-Cut:** Remove all references to `HybridInferenceService`, `Isar`, and `ChargingPulse`.
*   Implement a `SimpleMemoryService` (List-based) for the demo.

### Phase 2: Bug Squashing & Hardening (Days 4-7)
*   Fix `SpectralOps` SIGTERM/Orphan process bugs (as identified in `maksad.md`).
*   Optimize `CipherProtocol` for Gemma 2B's specific XML hallucination patterns.
*   Test `BashTool` on Android and Windows to ensure "Digital Equity" story holds.

### Phase 3: The "Hacker" UI (Days 8-9)
*   Create a single, high-polish "Gajraj Oracle" terminal interface.
*   Add a "Thinking/Thought-Channel" expander so judges see the internal reasoning.
*   Add a "Recovery Console" that lights up when AetherCore fixes an error.

### Phase 4: The Shoot & Report (Days 10-12)
*   Record the "No-WiFi" demo.
*   Write the 1500-word Kaggle report based on `maksad.md` (removing pro features).
*   Submit to Kaggle/Devpost.

---

## 🚩 Critical Success Factors (Zero Tolerance)
*   **No Crashes:** The system must handle "empty bash output" or "invalid commands" gracefully.
*   **Pure Gemma:** Ensure 100% of inference is via `flutter_gemma`.
*   **Security:** PathJailer must block `rm -rf /` commands if the model hallucinations try it.

---
**Status:** Plan ready for execution.
**Next Step:** Initialize `apex_lite` and begin Component Extraction.
