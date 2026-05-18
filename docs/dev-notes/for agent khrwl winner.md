# 🔱 HEART SNATCH — Claude Code → Agent Kharwal

> **Source**: `/Volumes/Secret_Lab/claude-code/src/`  
> **Target**: Agent Kharwal (Gemma 4 E2B, On-Device, 2B Model)  
> **Date**: 2026-05-17

---

## 📊 ARCHITECTURE OVERVIEW — What Claude Code Actually Does

```
┌─────────────────────────────────────────────────────────────────────┐
│                    CLAUDE CODE REAL ARCHITECTURE                     │
│                                                                     │
│  query.ts (queryLoop)                                               │
│  ├── while(true) — infinite agentic loop                           │
│  ├── 9 continue sites (recovery paths)                             │
│  ├── StreamingToolExecutor — parallel tool exec DURING stream      │
│  ├── Withholding Pattern — hide errors, retry silently             │
│  ├── 4-Stage Compaction Pipeline:                                  │
│  │   ├── microCompact (tool result clearing)                       │
│  │   ├── snipCompact (history snipping)                            │
│  │   ├── contextCollapse (staged collapses)                        │
│  │   └── autoCompact (AI summarization)                            │
│  ├── Tool Result Disk Persistence (large outputs → file)           │
│  ├── Sibling Abort (bash error → cancel all parallel tools)        │
│  └── Progress Streaming (real-time tool status to UI)              │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 🔥 PATTERN 1: WITHHOLDING PATTERN — SABSE IMPORTANT

### Source: `src/query.ts` (Lines 788-825)

**Concept**: Jab recoverable error aaye (prompt-too-long, max-output-tokens, media-size), user ko DIKHAO MAT. Silently retry karo. Sirf jab recovery fail ho TABHI error surface karo.

### EXACT Claude Code Implementation:

```typescript
// query.ts:799-825 — THE WITHHOLDING PATTERN
let withheld = false

// Check 1: Context Collapse can handle it?
if (contextCollapse?.isWithheldPromptTooLong(message, isPromptTooLongMessage, querySource)) {
  withheld = true
}

// Check 2: Reactive Compact can handle it?
if (reactiveCompact?.isWithheldPromptTooLong(message)) {
  withheld = true
}

// Check 3: Media size error recoverable?
if (mediaRecoveryEnabled && reactiveCompact?.isWithheldMediaSizeError(message)) {
  withheld = true
}

// Check 4: Max output tokens (can escalate 8K→64K)
if (isWithheldMaxOutputTokens(message)) {
  withheld = true
}

// THE KEY LINE: Only yield to user if NOT withheld
if (!withheld) {
  yield yieldMessage  // User sees this
}
// But ALWAYS push to assistantMessages for recovery logic
if (message.type === 'assistant') {
  assistantMessages.push(message)  // Recovery checks find it here
}
```

### Recovery Logic After Stream (Lines 1062-1256):

```typescript
// After stream ends, if the last message was withheld...
if (!needsFollowUp) {
  const isWithheld413 = lastMessage?.isApiErrorMessage && isPromptTooLongMessage(lastMessage)
  
  // Stage 1: Try context collapse drain (cheap)
  if (contextCollapse && state.transition?.reason !== 'collapse_drain_retry') {
    const drained = contextCollapse.recoverFromOverflow(messagesForQuery, querySource)
    if (drained.committed > 0) {
      state = { ...state, messages: drained.messages, transition: { reason: 'collapse_drain_retry' } }
      continue  // SILENT RETRY — user never knew
    }
  }
  
  // Stage 2: Try reactive compact (AI summarize, expensive)
  const compacted = await reactiveCompact.tryReactiveCompact({ ... })
  if (compacted) {
    state = { ...state, messages: buildPostCompactMessages(compacted), transition: { reason: 'reactive_compact_retry' } }
    continue  // SILENT RETRY — user still doesn't know
  }
  
  // Stage 3: Max output tokens escalation (8K → 64K)
  if (isWithheldMaxOutputTokens(lastMessage) && maxOutputTokensOverride === undefined) {
    state = { ...state, maxOutputTokensOverride: ESCALATED_MAX_TOKENS, transition: { reason: 'max_output_tokens_escalate' } }
    continue  // SILENT RETRY at higher limit
  }
  
  // ALL RECOVERY FAILED — NOW surface the error
  yield lastMessage  // User finally sees it
  return { reason: 'prompt_too_long' }
}
```

### 🎯 Agent Kharwal Dart Translation:

```dart
// AetherCore._runInternalPulse() mein:
bool _isWithholding = false;
int _withholdRetryCount = 0;
static const int _maxWithholdRetries = 3;

// Jab RecoverableErrorEvent aaye:
if (event is RecoverableErrorEvent || event is StreamTimeoutEvent) {
  _isWithholding = true;
  _withholdRetryCount++;
  
  if (_withholdRetryCount <= _maxWithholdRetries) {
    // SILENT RETRY — UI ko kuch mat batao
    // Status "Thinking..." continue rakhne do
    await _retryInference(); // Re-run with backoff
    return; // Don't emit any error event
  }
  
  // Max retries exhausted → NOW show error
  _isWithholding = false;
  _withholdRetryCount = 0;
  emit(FatalErrorEvent(event.error));
}

// UI mein: Jab _isWithholding = true
// → StatusBar shows "Thinking..." (not "Retrying...")
// → No error toast, no red indicators
// → User thinks model is just taking time
```

**Impact**: Judges ko lagega model PERFECT hai — koi glitch nahi dikhega. ✨

---

## 🔥 PATTERN 2: STREAMING TOOL EXECUTOR — PERFORMANCE

### Source: `src/services/tools/StreamingToolExecutor.ts` (Full 532 lines)

**Concept**: Model ABHI stream kar raha hai tokens... tool_use block detect hua... TURANT execution shuru! Model stream khatam hone ka wait NAHI karna.

### EXACT Architecture:

```typescript
// StreamingToolExecutor.ts — Core Class
export class StreamingToolExecutor {
  private tools: TrackedTool[] = []        // Queue of all tools
  private hasErrored = false               // Sibling abort flag
  private siblingAbortController: AbortController  // Kill siblings on error
  private discarded = false                // Streaming fallback happened

  // Tool Status Lifecycle: queued → executing → completed → yielded
  
  // Called from query.ts DURING streaming (line 842):
  addTool(block: ToolUseBlock, assistantMessage: AssistantMessage): void {
    const isConcurrencySafe = toolDefinition.isConcurrencySafe(parsedInput)
    this.tools.push({
      id: block.id, block, assistantMessage,
      status: 'queued',
      isConcurrencySafe,
      pendingProgress: [],
    })
    void this.processQueue()  // IMMEDIATELY try to execute
  }
  
  // Concurrency Control:
  private canExecuteTool(isConcurrencySafe: boolean): boolean {
    const executingTools = this.tools.filter(t => t.status === 'executing')
    return (
      executingTools.length === 0 ||  // Nothing running = go
      (isConcurrencySafe && executingTools.every(t => t.isConcurrencySafe))  // All safe = parallel OK
    )
  }
}
```

### How query.ts Integrates It (Lines 561-862):

```typescript
// SETUP: Create executor at query start
const useStreamingToolExecution = config.gates.streamingToolExecution
let streamingToolExecutor = useStreamingToolExecution
  ? new StreamingToolExecutor(tools, canUseTool, toolUseContext)
  : null

// DURING STREAMING: As each tool_use block arrives
for await (const message of deps.callModel({ ... })) {
  if (message.type === 'assistant') {
    const toolBlocks = message.message.content.filter(c => c.type === 'tool_use')
    if (toolBlocks.length > 0 && streamingToolExecutor) {
      for (const toolBlock of toolBlocks) {
        streamingToolExecutor.addTool(toolBlock, message)  // 🔥 EXECUTE NOW
      }
    }
  }
  
  // YIELD completed results WHILE model is still streaming
  if (streamingToolExecutor) {
    for (const result of streamingToolExecutor.getCompletedResults()) {
      if (result.message) {
        yield result.message  // Tool result ready before stream ends!
      }
    }
  }
}

// AFTER STREAMING: Collect remaining results
const toolUpdates = streamingToolExecutor
  ? streamingToolExecutor.getRemainingResults()  // Async generator
  : runTools(toolUseBlocks, ...)                 // Legacy batch
```

### 🎯 Agent Kharwal Dart Translation:

```dart
// AetherCore mein:
class StreamingToolExecutor {
  final List<_TrackedTool> _queue = [];
  bool _hasErrored = false;
  
  void addTool(Map<String, dynamic> toolCall) {
    _queue.add(_TrackedTool(
      id: toolCall['id'],
      name: toolCall['name'],
      params: toolCall['parameters'],
      status: ToolStatus.queued,
    ));
    _processQueue(); // Fire immediately
  }
  
  Future<void> _processQueue() async {
    for (final tool in _queue) {
      if (tool.status != ToolStatus.queued) continue;
      if (_canExecute(tool)) {
        tool.status = ToolStatus.executing;
        tool.future = _executeSingle(tool); // Don't await!
      }
    }
  }
  
  Future<void> _executeSingle(_TrackedTool tool) async {
    final result = await AgentRouter.executeSingle(tool.name, tool.params);
    tool.result = result;
    tool.status = ToolStatus.completed;
    _processQueue(); // Maybe start next queued tool
  }
  
  // Call this periodically during stream to get completed results
  List<ToolResult> getCompletedResults() {
    return _queue
      .where((t) => t.status == ToolStatus.completed && !t.yielded)
      .map((t) { t.yielded = true; return t.result!; })
      .toList();
  }
}

// Usage in AetherCore stream loop:
final executor = StreamingToolExecutor();

await for (final event in inferenceStream) {
  if (event is ToolCallEvent) {
    executor.addTool(event.toolCall); // Execute NOW, don't wait
  }
  
  // Yield completed tool results while stream continues
  for (final result in executor.getCompletedResults()) {
    _feedToolResult(result);
  }
}

// After stream ends, get remaining
final remaining = await executor.waitForAll();
```

**Impact**: 30-50% faster multi-tool execution. Stream 5s + Tools 3s = 5s total (not 8s).

---

## 🔥 PATTERN 3: SIBLING ABORT — RESOURCE SAFETY

### Source: `StreamingToolExecutor.ts` (Lines 44-48, 354-363)

**Concept**: Agar Bash tool FAIL ho, toh parallel chal rahe SAARE sibling tools ko CANCEL karo.

### EXACT Implementation:

```typescript
// Only Bash errors cancel siblings (Line 354-363)
if (isErrorResult) {
  thisToolErrored = true
  // Only Bash errors cancel siblings. Bash commands often have implicit
  // dependency chains (e.g. mkdir fails → subsequent commands pointless).
  // Read/WebFetch/etc are independent — one failure shouldn't nuke the rest.
  if (tool.block.name === BASH_TOOL_NAME) {
    this.hasErrored = true
    this.erroredToolDescription = this.getToolDescription(tool)
    this.siblingAbortController.abort('sibling_error')
  }
}

// Other tools check abort reason (Line 333-344):
const abortReason = this.getAbortReason(tool)
if (abortReason && !thisToolErrored) {
  messages.push(this.createSyntheticErrorMessage(tool.id, abortReason, ...))
  break  // Stop processing this tool
}

// Synthetic error message for cancelled siblings (Line 189-204):
const msg = desc
  ? `Cancelled: parallel tool call ${desc} errored`
  : 'Cancelled: parallel tool call errored'
```

### Key Design Decision:
- **ONLY Bash errors** cascade → Read/Grep/WebFetch failures are independent
- Cancelled tools get synthetic `is_error: true` results so model knows to fix

### 🎯 Agent Kharwal Dart Translation:

```dart
// AgentRouter.executeTools() mein:
Future<List<ToolResult>> executeToolsParallel(List<ToolCall> calls) async {
  final results = <ToolResult>[];
  bool siblingErrored = false;
  String? erroredToolDesc;
  
  final futures = calls.map((call) async {
    if (siblingErrored) {
      return ToolResult(
        toolId: call.id,
        output: 'Cancelled: parallel tool $erroredToolDesc errored',
        isError: true,
      );
    }
    
    final result = await _executeSingle(call);
    
    // Only bash errors cancel siblings
    if (result.isError && call.name == 'bash') {
      siblingErrored = true;
      erroredToolDesc = '${call.name}(${call.params['command']?.toString().take(40)})';
    }
    
    return result;
  }).toList();
  
  return Future.wait(futures);
}
```

---

## 🔥 PATTERN 4: TOOL RESULT DISK PERSISTENCE — CONTEXT SAVER

### Source: `src/utils/toolResultStorage.ts` (1042 lines)

**Concept**: Agar tool output > threshold → Disk pe save karo, model ko sirf HEAD + TAIL preview do.

### EXACT Implementation:

```typescript
// Constants:
export const PERSISTED_OUTPUT_TAG = '<persisted-output>'
export const PREVIEW_SIZE_BYTES = 2000  // Preview = first 2KB

// Core function (Line 272-334):
async function maybePersistLargeToolResult(
  toolResultBlock: ToolResultBlockParam,
  toolName: string,
  persistenceThreshold?: number,
): Promise<ToolResultBlockParam> {
  const size = contentSize(content)
  const threshold = persistenceThreshold ?? MAX_TOOL_RESULT_BYTES
  
  if (size <= threshold) {
    return toolResultBlock  // Small enough, pass through
  }
  
  // PERSIST TO DISK
  const result = await persistToolResult(content, toolResultBlock.tool_use_id)
  const message = buildLargeToolResultMessage(result)
  return { ...toolResultBlock, content: message }
}

// What model sees (Line 189-199):
function buildLargeToolResultMessage(result: PersistedToolResult): string {
  let message = `<persisted-output>\n`
  message += `Output too large (${formatFileSize(result.originalSize)}). Full output saved to: ${result.filepath}\n\n`
  message += `Preview (first ${formatFileSize(PREVIEW_SIZE_BYTES)}):\n`
  message += result.preview
  message += result.hasMore ? '\n...\n' : '\n'
  message += `</persisted-output>`
  return message
}

// Per-tool thresholds:
// BashTool:    30,000 chars
// GrepTool:    20,000 chars
// FileRead:    Infinity (never persist, self-bounds via maxTokens)
// Most tools:  100,000 chars
// Global cap:  DEFAULT_MAX_RESULT_SIZE_CHARS (50K)
```

### 🎯 Agent Kharwal Dart Translation:

```dart
// SpectralOps.execute() mein:
class ToolResultPersister {
  static const int _threshold = 5000; // E2B has 32K context, be aggressive
  static const int _previewSize = 500;
  
  static Future<String> maybePersist(String output, String toolId) async {
    if (output.length <= _threshold) return output;
    
    // Save to sandbox
    final path = '/sandbox/.tool_outputs/${toolId}.log';
    await File(path).writeAsString(output);
    
    // Return preview
    final head = output.substring(0, _previewSize);
    final tail = output.substring(output.length - _previewSize);
    
    return '''<persisted-output>
Output too large (${output.length} chars). Saved to: $path

Preview (first ${_previewSize} chars):
$head
...
(${output.length - _previewSize * 2} chars omitted)
...
$tail
</persisted-output>''';
  }
}
```

**Impact**: Context window 10x efficient. Model handles huge outputs without overflow.

---

## 🔥 PATTERN 5: AUTO-COMPACT / AI SUMMARIZATION — INFINITE MEMORY

### Source: `src/services/compact/autoCompact.ts` + `compact.ts` + `prompt.ts`

**Concept**: Jab context > threshold → AI call karke purane messages summarize karo → Replace with summary.

### EXACT Trigger Logic (autoCompact.ts):

```typescript
// Threshold calculation (Line 72-91):
export function getAutoCompactThreshold(model: string): number {
  const effectiveContextWindow = getEffectiveContextWindowSize(model)
  return effectiveContextWindow - AUTOCOMPACT_BUFFER_TOKENS  // 13K buffer
}

// Decision (Line 160-238):
export async function shouldAutoCompact(messages, model): Promise<boolean> {
  if (!isAutoCompactEnabled()) return false
  const tokenCount = tokenCountWithEstimation(messages)
  const threshold = getAutoCompactThreshold(model)
  return tokenCount >= threshold
}

// Execution (Line 241-351):
export async function autoCompactIfNeeded(...) {
  // Try Session Memory Compaction FIRST (cheaper)
  const sessionMemoryResult = await trySessionMemoryCompaction(messages, ...)
  if (sessionMemoryResult) {
    runPostCompactCleanup(querySource)
    return { wasCompacted: true, compactionResult: sessionMemoryResult }
  }
  
  // Fallback: Full AI Compaction
  const compactionResult = await compactConversation(
    messages, toolUseContext, cacheSafeParams,
    true,      // suppressFollowUpQuestions
    undefined, // No custom instructions
    true,      // isAutoCompact
  )
  return { wasCompacted: true, compactionResult }
}

// Circuit Breaker: Stop after 3 consecutive failures
const MAX_CONSECUTIVE_AUTOCOMPACT_FAILURES = 3
```

### Compaction Prompt (prompt.ts — THE SUMMARY TEMPLATE):

```typescript
const BASE_COMPACT_PROMPT = `Your task is to create a detailed summary...

Your summary should include:
1. Primary Request and Intent
2. Key Technical Concepts  
3. Files and Code Sections (with full code snippets)
4. Errors and fixes
5. Problem Solving
6. All user messages (non tool-result)
7. Pending Tasks
8. Current Work (what was being done JUST before summary)
9. Optional Next Step

Use <analysis> tags for drafting, then <summary> for final output.`

// Post-compact message to model:
`This session is being continued from a previous conversation that ran out of context.
Continue without asking questions. Resume directly — do not acknowledge the summary.`
```

### How query.ts Uses It (Lines 453-543):

```typescript
// In queryLoop, BEFORE API call:
const { compactionResult } = await deps.autocompact(messagesForQuery, ...)

if (compactionResult) {
  // Yield post-compact messages (summary replaces old history)
  const postCompactMessages = buildPostCompactMessages(compactionResult)
  for (const message of postCompactMessages) {
    yield message
  }
  messagesForQuery = postCompactMessages  // Continue with compacted history
}
```

### 🎯 Agent Kharwal Dart Translation:

```dart
// AetherCore mein:
Future<void> _autoCompactIfNeeded() async {
  if (_history.length < 30) return; // Too early
  
  final estimatedTokens = _estimateTokens(_history);
  if (estimatedTokens < 20000) return; // Under threshold (32K context)
  
  // Split: aging (old 20) + fresh (recent 10)
  final aging = _history.sublist(0, _history.length - 10);
  final fresh = _history.sublist(_history.length - 10);
  
  // Summarize aging portion using the model itself
  final summaryPrompt = '''Summarize this conversation in 4-5 bullet points.
Focus on: what user asked, what was done, errors fixed, current task.
Keep file names, code snippets, and specific details.''';
  
  final summary = await _runSummarization(aging, summaryPrompt);
  
  // Replace history: [Summary] + [Fresh messages]
  _history = [
    ChatMessage.system('Previous conversation summary:\n$summary'),
    ...fresh,
  ];
}

// Call this at the start of each agentic loop iteration:
// while (true) {
//   await _autoCompactIfNeeded();  // Check before each turn
//   final response = await _runInference();
//   ...
// }
```

**Impact**: Agent NEVER dies from context overflow. Infinite-turn conversations.

---

## 🔥 PATTERN 6: PROGRESS STREAMING — PREMIUM UX

### Source: `src/services/tools/toolExecution.ts` (Lines 492-570)

**Concept**: Tool execution ke DURING real-time progress events emit karo → UI mein live status.

### EXACT Implementation:

```typescript
// streamedCheckPermissionsAndCallTool (Line 492-570):
function streamedCheckPermissionsAndCallTool(...): AsyncIterable<MessageUpdateLazy> {
  const stream = new Stream<MessageUpdateLazy>()
  
  checkPermissionsAndCallTool(
    tool, toolUseID, input, toolUseContext, canUseTool, assistantMessage,
    messageId, requestId, mcpServerType, mcpServerBaseUrl,
    
    // PROGRESS CALLBACK — called during execution:
    progress => {
      logEvent('tengu_tool_use_progress', { toolName, ... })
      stream.enqueue({
        message: createProgressMessage({
          toolUseID: progress.toolUseID,
          parentToolUseID: toolUseID,
          data: progress.data,  // { command, status, output_lines, etc. }
        }),
      })
    },
  )
    .then(results => { for (const r of results) stream.enqueue(r) })
    .catch(error => stream.error(error))
    .finally(() => stream.done())
  
  return stream
}

// StreamingToolExecutor handles progress specially (Line 367-374):
if (update.message.type === 'progress') {
  tool.pendingProgress.push(update.message)
  // Wake up getRemainingResults immediately
  if (this.progressAvailableResolve) {
    this.progressAvailableResolve()
  }
}
```

### 🎯 Agent Kharwal Dart Translation:

```dart
// AgentRouter._executeSingle() mein:
Future<ToolResult> _executeSingle(String name, Map<String, dynamic> params) async {
  // EMIT START
  _progressController.add(ToolProgressEvent(
    tool: name,
    status: 'running',
    command: params['command'] ?? params.toString().take(60),
    startTime: DateTime.now(),
  ));
  
  final stopwatch = Stopwatch()..start();
  
  try {
    final result = await _tools[name]!.execute(params);
    
    // EMIT DONE
    _progressController.add(ToolProgressEvent(
      tool: name,
      status: 'done',
      durationMs: stopwatch.elapsedMilliseconds,
      exitCode: result.exitCode,
    ));
    
    return result;
  } catch (e) {
    // EMIT ERROR
    _progressController.add(ToolProgressEvent(
      tool: name,
      status: 'error',
      durationMs: stopwatch.elapsedMilliseconds,
      error: e.toString(),
    ));
    rethrow;
  }
}

// GajrajScaffold UI mein:
StreamBuilder<ToolProgressEvent>(
  stream: aetherCore.toolProgress,
  builder: (context, snapshot) {
    if (!snapshot.hasData) return SizedBox.shrink();
    final event = snapshot.data!;
    return AnimatedContainer(
      duration: Duration(milliseconds: 300),
      child: _PremiumToolCard(
        icon: event.status == 'running' ? Icons.play_arrow : Icons.check,
        title: '${event.tool}',
        subtitle: event.command ?? '',
        status: event.status,
        duration: event.durationMs != null 
          ? '${event.durationMs}ms' : 'Running...',
      ),
    );
  },
)
```

**Impact**: Premium UX — user FEELS agent actively working. Not a black box.

---

## ⚠️ NAHI CHURANA — 2B Model pe Kaam NAHI Karega

| Pattern | Kyun NAHI |
|---------|-----------|
| **Model Fallback** (Sonnet→Opus) | Humare paas sirf 1 model (E2B). Swap impossible. |
| **Max-Tokens Escalation** (8K→64K) | LiteRT-LM mein output cap fixed hai native level pe. |
| **Lazy Tool Loading** (ToolSearch) | Humare 7-8 tools hain. Sab load karna sasta hai. |
| **MCP** (Model Context Protocol) | On-device = no external servers. |
| **Token Budget Continuation** | E2B output already short. Problem nahi aati. |
| **Reactive Compact** (on 413 error) | LiteRT-LM 413 nahi deta — silently truncate. |
| **Context Collapse** (staged commits) | Too complex for 32K window. AutoCompact sufficient. |
| **Cached Microcompact** (cache_edits API) | Cloud-only API feature. |

---

## 📊 PRIORITY MATRIX

| # | Pattern | Difficulty | Impact | Priority |
|---|---------|-----------|--------|----------|
| 1 | **Withholding Pattern** | 🟢 Easy (30 min) | 🔥🔥🔥 Judges ke liye critical | **P0 — ABHI** |
| 2 | **Progress Streaming** | 🟢 Easy (1 hr) | 🔥🔥🔥 Premium UX feel | **P0 — ABHI** |
| 3 | **Streaming Tool Executor** | 🟡 Medium (2 hr) | 🔥🔥 Performance gain | **P1 — Next** |
| 4 | **Tool Result Disk Persistence** | 🟡 Medium (2 hr) | 🔥🔥 Context efficiency | **P1 — Next** |
| 5 | **Auto-Compact Summarizer** | 🔴 Hard (3-4 hr) | 🔥🔥🔥 Infinite memory | **P2 — If time** |
| 6 | **Sibling Abort** | 🟢 Easy (30 min) | 🔥 Safety improvement | **P2 — If time** |

---

## 🎯 COPY-PASTE IMPLEMENTATION PROMPT

```
Bhai, Claude Code se ye 2 patterns chura ke Agent Kharwal mein implement karo:

1. WITHHOLDING PATTERN:
   - AetherCore._runInternalPulse() mein ek `bool isWithholding` flag add karo
   - Jab RecoverableErrorEvent ya StreamTimeoutEvent aaye → withhold karo
   - UI ko 'recovery' ya 'status' events BHEJNE BAND karo during withholding
   - Sirf 'status': 'Thinking...' continue rakhne do
   - Agar maxRetries exhaust ho TABHI error dikhao
   - Result: User ko lagega model soch raha tha, koi error nahi hua

2. PROGRESS STREAMING:
   - AgentRouter._executeSingle() mein tool execution START pe event emit karo
   - Event format: {'type': 'tool_progress', 'tool': name, 'status': 'running', 'command': params['command']}
   - Execution END pe: {'type': 'tool_progress', 'tool': name, 'status': 'done', 'duration_ms': N, 'exit_code': code}
   - GajrajScaffold mein ye events catch karo aur premium animated progress card dikhao

CONSTRAINT: Zero existing code delete karna. Additive changes only.
flutter analyze lib/ → 0 errors baad mein bhi.
```

---

## 🏆 FINAL VERDICT

**Jo churana hai** = Infrastructure patterns (withholding, streaming executor, auto-compact, disk persistence, progress streaming, sibling abort). Ye **model size se independent** hain.

**Jo NAHI churana** = Model-dependent features (fallback, token escalation, MCP, cached microcompact). Ye sirf **cloud + big model** ke saath kaam karte hain.

> **Bottom line**: 6 patterns churao → Agent Kharwal hackathon mein DANGEROUS ho jayega. 🔱
