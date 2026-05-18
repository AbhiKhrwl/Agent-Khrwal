/// 🔱 Typed inference events from Gemma 4 via flutter_gemma SDK.
///
/// With native function calling (flutter_gemma 0.15.1+), the SDK surfaces
/// structured FunctionCallResponse objects — NOT raw text tokens.
/// These sealed classes let AetherCore handle tool calls DIRECTLY
/// without any text-based CipherProtocol parsing.
sealed class InferenceEvent {}

/// A text token from the model's response.
class TextToken extends InferenceEvent {
  final String token;
  TextToken(this.token);
}

/// A thinking/reasoning token (rendered in collapsible thought bubble).
class ThinkingToken extends InferenceEvent {
  final String content;
  ThinkingToken(this.content);
}

/// A native function call from Gemma 4.
/// The SDK already parsed name + args from <|tool_call|> tokens.
/// No CipherProtocol parsing needed — this is a STRUCTURED Dart object.
class ToolCallEvent extends InferenceEvent {
  final String name;
  final Map<String, dynamic> args;
  ToolCallEvent({required this.name, required this.args});
}

/// A fatal engine error that requires model reload.
class FatalErrorEvent extends InferenceEvent {
  final String message;
  FatalErrorEvent(this.message);
}

/// GPU fallback signal — switched to CPU mid-stream.
class GpuFallbackEvent extends InferenceEvent {
  final String message;
  GpuFallbackEvent(this.message);
}

/// 🔱 Phase 4: Non-fatal stream error that AetherCore can retry.
/// Unlike FatalErrorEvent (requires model reload) or thrown exceptions
/// (crash the loop), this signals "this turn failed, try again".
/// Common cause: LiteRT-LM's prefill/sampler errors between agentic turns.
class RecoverableErrorEvent extends InferenceEvent {
  final String message;
  RecoverableErrorEvent(this.message);
}

/// 🔱 Supreme Fix 12: Stream produced no tokens within the inactivity window.
/// Distinct from RecoverableError because this specifically means the model's
/// prefill or decode phase hung — not a stream error. Recovery may need
/// model reload (if consecutive) rather than simple retry.
class StreamTimeoutEvent extends InferenceEvent {
  final String message;
  final Duration timeoutDuration;
  StreamTimeoutEvent(this.message, {required this.timeoutDuration});
}
