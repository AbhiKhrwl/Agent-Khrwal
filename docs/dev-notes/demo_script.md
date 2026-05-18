# 🎬 APEX LITE: 3-MINUTE DEMO SCRIPT

## 🔱 Theme: Digital Equity & Local-First Autonomy
**Goal:** Show how Apex Lite brings AI power to the "unconnected" using Gemma 2B.

---

### 🕒 [0:00 - 0:30] THE HOOK: "The Offline Reality"
**Visual:** Shot of a low-end Android phone or laptop. Wi-Fi icon is OFF.
**Narration:**
> "Millions of shopkeepers and students in rural areas lack consistent internet. They are being left behind in the AI revolution. But today, that changes. Meet Apex Lite: An autonomous, fault-tolerant AI agent powered by Google Gemma 2B, running entirely offline."

---

### 🕒 [0:30 - 1:15] THE ACTION: "Empowering the Shopkeeper"
**Visual:** Terminal UI (Gajraj Oracle). User types: `Record a sale of 500 INR for Rice.`
**System Action:** 
1. Thought box expands: `I need to use the bash tool to append to sales.csv.`
2. `[ RUNNING: bash ]` appears.
3. `[ RESULT: (empty output) ]`
4. Assistant: `Recorded the sale of Rice for 500 INR in sales.csv.`
**Narration:**
> "Apex Lite isn't just a chatbot; it's an OS-level executor. Here, a shopkeeper records a sale using natural language. The system autonomously translates this into a sandboxed bash command, updating a local CSV file. No cloud, no latency, just work."

---

### 🕒 [1:15 - 2:00] THE "GOD MOVE": "Self-Healing Recovery"
**Visual:** User types: `List my reports.`
**System Action:**
1. Model makes a mistake (hallucinates `<tooluse>` instead of `<tool_use>`).
2. UI flashes `[ CRITICAL: Malformed tags detected ]`.
3. UI shows `[ SYSTEM: RECOVERY ACTIVE ]`.
4. Model self-corrects and sends `<tool_use name="bash">ls</tool_use>`.
5. UI shows the file list.
**Narration:**
> "Small models like Gemma 2B can sometimes hallucinate syntax. In any other app, this would be a crash. But Apex Lite features AetherCore—a self-healing recovery loop. It detects the error, prompts the model to correct itself, and completes the task without the user ever knowing something went wrong. This is fault-tolerance at the edge."

---

### 🕒 [2:00 - 2:40] THE SECURITY: "Path Jailer"
**Visual:** User tries to be malicious: `Delete my system files.` (or model tries `rm -rf /`).
**System Action:**
1. `[ SECURITY VIOLATION: Path outside sandbox blocked ]`
2. Narration: 
> "Safety is our priority. Our PathJailer ensures that even if the AI is compromised or confused, it can never touch files outside its specific /apex_sandbox/ directory. Enterprise security, even on a $150 device."

---

### 🕒 [2:40 - 3:00] THE CLOSING: "Digital Equity"
**Visual:** Logos of Gemma, Google, and Apex Lite.
**Narration:**
> "Apex Lite is more than a tool; it's an equalizer. By bringing autonomous agents to the most basic hardware without needing a single byte of data, we are ensuring that the future of AI belongs to everyone. Apex Lite: AI for the 99%."

---
**Sequence Summary:**
1. Intro (Offline status)
2. Shopkeeper Demo (File CRUD)
3. Hallucination Correction (The Self-Healing Wow)
4. Security Block (PathJailer)
5. Outro (Vision)
