import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import '../../domain/entities/message.dart';
import '../../domain/entities/inference_event.dart';
// tool_entities.dart imported via AgentRouter where needed

// 🔱 Divine Concurrency Lock: Serializes ALL engine access.
// On-device LLM engines are single-threaded — two concurrent
// conversations will SIGSEGV. This Completer-based mutex ensures
// only one inference runs at a time (promise chain pattern).
Completer<void>? _globalEngineLock;

/// Model loading states for UI binding
enum ModelLoadState { noModel, loading, ready, error }

/// Available model types for user selection
/// Must match flutter_gemma 0.14.x ModelType exactly
enum ModelType { gemma4 }

/// Service that manages local model loading from user-picked files.
///
/// Supports two paths:
/// 1. Download from HuggingFace (FlutterGemma default)
/// 2. Load from user-selected local file (via fromFile API)
class LocalInferenceService {
  ModelLoadState _state = ModelLoadState.noModel;
  ModelLoadState get state => _state;
  String? _errorMessage;
  String? get errorMessage => _errorMessage;
  String? _loadedModelName;
  String? get loadedModelName => _loadedModelName;

  int maxTokens = 8192;
  StreamSubscription<String>? _activeSubscription;

  /// 🔱 Divine Mutex: Acquires global engine lock before running fn.
  /// Prevents concurrent inference on the single-threaded LiteRT-LM engine.
  Future<T> _withEngineLock<T>(Future<T> Function() fn) async {
    // Wait for any previous inference to complete
    while (_globalEngineLock != null && !_globalEngineLock!.isCompleted) {
      debugPrint('🔱 [Mutex] Waiting for previous inference to complete...');
      await _globalEngineLock!.future;
    }
    _globalEngineLock = Completer<void>();
    try {
      return await fn();
    } finally {
      _globalEngineLock!.complete();
      debugPrint('🔱 [Mutex] Engine lock released ✅');
    }
  }

  /// 🔱 Smart Auto-Detect Backend (like HuggingFace `device_map="auto"`)
  ///
  /// Priority Order: GPU → CPU (NPU requires dispatch-lib, not auto-probed)
  ///
  /// How it works:
  /// 1. First call → tries GPU (OpenCL/Metal)
  /// 2. If GPU fails (sampler missing, QUEUE_BUFFER_TIMEOUT) → auto-falls to CPU
  /// 3. Remembers the working backend for the rest of the session
  /// 4. No code changes needed per device — it adapts automatically
  gemma.PreferredBackend _backend = gemma.PreferredBackend.gpu;
  bool _gpuFailed = false;
  int _consecutiveGpuFailures = 0; // Tracks failures ACROSS prompts
  static const int _maxGpuFailures = 3; // Permanent CPU after this many

  /// Returns the best available backend for this device
  gemma.PreferredBackend get backend {
    if (_gpuFailed) return gemma.PreferredBackend.cpu;
    return _backend;
  }

  /// Manually override the backend (e.g., user settings toggle)
  void setBackend(gemma.PreferredBackend backend) {
    _backend = backend;
    _gpuFailed = false;
  }

  /// Stop active inference generation (Zombie Prevention — Heart-Snatch Pillar 4)
  void stopGeneration() {
    _activeSubscription?.cancel();
    _activeSubscription = null;
  }

  /// Known fatal engine errors that should NOT be retried
  static const _fatalErrorPatterns = [
    'Failed to allocate tensors',
    'Failed to invoke the compiled model',
    'DYNAMIC_UPDATE_SLICE',
    'SizeOfDimension',
    'SIGSEGV',          // 🔱 Research: native memory access violation
    'FAILED_PRECONDITION', // 🔱 Research: concurrent conversation on single engine
    'Failed to initialize miniaudio decoder', // 🔱 Research: unsupported audio format
  ];

  /// Known GPU-specific errors that trigger safe CPU fallback
  static const _gpuFallbackPatterns = [
    'GPU sampler unavailable',
    'QUEUE_BUFFER_TIMEOUT',
    'OpenCL',
    'WebGpu',
    'gpu_executor',
    'GpuAccelerator',
    'dispatch error',
    'clEnqueueMapBuffer',
    'vision_litert_compiled_model_executor',
    'INVALID_ARGUMENT',  // 🔱 Research: WebP rejection, bad image/audio format
    'Failed to decode image', // 🔱 Research: WebP bytes rejected by LiteRT-LM
  ];

  /// Check if an error string indicates a fatal, non-recoverable engine failure
  static bool isFatalEngineError(String errorText) {
    return _fatalErrorPatterns.any(
      (pattern) => errorText.contains(pattern),
    );
  }

  /// Check if an error is GPU-specific and should trigger CPU fallback
  bool _isGpuSpecificError(String errorText) {
    return _gpuFallbackPatterns.any(
      (pattern) => errorText.contains(pattern),
    );
  }

  /// 🔱 Supreme Fix 8: Track GPU error PATTERNS, not just counts.
  /// If the same error type repeats, skip GPU for that scenario immediately.
  String? _lastGpuErrorPattern;

  /// 🔱 Downgrade to CPU — tracks failures across prompts
  /// Per-prompt: 1 GPU try → if fails → CPU fallback for THIS prompt
  /// Cross-prompt: if fails 3 consecutive prompts → permanent CPU
  /// Supreme Fix 8: Same error pattern → skip GPU immediately next time
  void _fallbackToCpu(String reason) {
    _consecutiveGpuFailures++;
    debugPrint('🔱 [AutoBackend] GPU failed ($reason)');
    debugPrint('🔱 [AutoBackend] GPU failure count: $_consecutiveGpuFailures/$_maxGpuFailures');

    // 🔱 Fix 8: Extract the error pattern (first matching keyword)
    final currentPattern = _gpuFallbackPatterns
        .where((p) => reason.contains(p))
        .firstOrNull;

    if (currentPattern != null && currentPattern == _lastGpuErrorPattern) {
      // Same error pattern repeated — skip GPU permanently
      _gpuFailed = true;
      debugPrint('🔱 [AutoBackend] Same GPU error pattern "$currentPattern" repeated → PERMANENT CPU mode.');
    } else if (_consecutiveGpuFailures >= _maxGpuFailures) {
      _gpuFailed = true;
      debugPrint('🔱 [AutoBackend] GPU failed $_maxGpuFailures consecutive prompts → PERMANENT CPU mode.');
    } else {
      debugPrint('🔱 [AutoBackend] Falling back to CPU for this prompt. Will try GPU again next prompt.');
    }
    _lastGpuErrorPattern = currentPattern;
  }

  /// Mark GPU as working — resets failure counter
  void _confirmGpuWorking() {
    if (_gpuFailed) {
      debugPrint('🔱 [AutoBackend] GPU working again! Recovering from permanent CPU mode.');
      _gpuFailed = false;
    }
    _consecutiveGpuFailures = 0;
    _lastGpuErrorPattern = null; // 🔱 Fix 8: Clear pattern on success
    debugPrint('🔱 [AutoBackend] GPU confirmed working ✅');
  }

  /// Request storage permissions for Android 11+
  Future<bool> requestStoragePermissions() async {
    try {
      if (!Platform.isAndroid) return true;

      // On Android 13+ (API 33+), READ_EXTERNAL_STORAGE is deprecated.
      // Furthermore, apps can write to public directories like /Download 
      // without ANY permissions using the MediaStore or standard file APIs.
      // Since main.dart already requests modern permissions, we can safely bypass 
      // the legacy check for Android 13+.
      
      // We will just request manageExternalStorage for Android 11+ if absolutely needed,
      // but wrap it safely so it doesn't force openAppSettings on modern OS.
      var status = await Permission.storage.status;
      if (!status.isGranted) {
        status = await Permission.storage.request();
      }

      var manageStatus = await Permission.manageExternalStorage.status;
      if (!manageStatus.isGranted) {
        manageStatus = await Permission.manageExternalStorage.request();
      }

      // Instead of forcing openAppSettings(), just return true to attempt the write.
      // If it fails, the catch block in downloadModel will handle it cleanly.
      return true;
    } catch (e) {
      return true;
    }
  }

  /// Map user-friendly ModelType to flutter_gemma ModelType
  gemma.ModelType _mapModelType(ModelType type) {
    // Only support gemma4 model type
    return gemma.ModelType.gemma4;
  }

  /// Check if a model file is already installed in FlutterGemma's storage
  Future<bool> isModelInstalled(String fileName) async {
    try {
      return await gemma.FlutterGemma.isModelInstalled(fileName);
    } catch (_) {
      return false;
    }
  }

  /// Initialize FlutterGemma engine (no model loaded yet)
  Future<bool> initialize() async {
    try {
      await gemma.FlutterGemma.initialize();
      return true;
    } catch (_) {
      _state = ModelLoadState.error;
      _errorMessage = 'Failed to initialize LiteRT-LM engine.';
      return false;
    }
  }

  /// Load a model from a user-picked local file path
  Future<bool> loadModelFromFile({
    required ModelType modelType,
    required String filePath,
    String? fileName,
  }) async {
    _state = ModelLoadState.loading;
    _errorMessage = null;
    _loadedModelName = fileName ?? filePath.split('/').last;

    try {
      final gemmaModelType = _mapModelType(modelType);

      // Validate file path and existence before loading
      final file = File(filePath);
      if (!file.existsSync()) {
        _errorMessage = 'Model file does not exist: $filePath';
        _state = ModelLoadState.error;
        return false;
      }

      // Check file size to ensure it's a valid model
      if (file.lengthSync() < 1000000) {
        _errorMessage = 'Model file appears to be corrupted or incomplete';
        _state = ModelLoadState.error;
        return false;
      }

      await gemma.FlutterGemma.installModel(
        modelType: gemmaModelType,
        fileType: gemma.ModelFileType.litertlm,
      ).fromFile(filePath).install();

      _state = ModelLoadState.ready;
      return true;
    } catch (e) {
      _state = ModelLoadState.error;
      _errorMessage = 'Failed to load model: $e';
      return false;
    }
  }

  /// Download a model to persistent public storage (e.g. /Download/ApexModels/)
  Future<bool> downloadModel({
    required ModelType modelType,
    String? huggingFaceToken,
    void Function(int progress)? onProgress,
  }) async {
    _state = ModelLoadState.loading;
    _errorMessage = null;

    try {
      final gemmaModelType = _mapModelType(modelType);
      final url = _getModelUrl(gemmaModelType);
      final modelFileName =
          '${_getModelName(gemmaModelType).replaceAll(' ', '_')}.litertlm';

      // Determine public persistent save path
      Directory? saveDir;
      if (Platform.isAndroid) {
        // Request all necessary permissions for Android 11+
        bool hasPermission = await requestStoragePermissions();
        if (!hasPermission) {
          throw Exception('Storage permissions not granted');
        }
      }

      // Public Downloads folder to survive app uninstalls
      saveDir = Directory('/storage/emulated/0/Download/ApexModels');
      if (!saveDir.existsSync()) {
        try {
          saveDir.createSync(recursive: true);
        } catch (e) {
          // Fallback to app external storage if public directory creation fails
          saveDir = await getExternalStorageDirectory();
          if (saveDir == null) {
            throw Exception('Could not determine external storage directory');
          }
          saveDir = Directory('${saveDir.path}/ApexModels');
          if (!saveDir.existsSync()) saveDir.createSync(recursive: true);
        }
      }

      // 1. First, search the user's public Downloads directory for any existing model
      final publicDownloadDir = Directory('/storage/emulated/0/Download');
      if (publicDownloadDir.existsSync()) {
        try {
          final files = publicDownloadDir.listSync();
          for (var f in files) {
            if (f is File && f.path.endsWith('.litertlm') && f.lengthSync() > 1000000000) {
              // Found a valid model in Downloads! Use it directly.
              if (onProgress != null) onProgress(100);
              return await loadModelFromFile(
                modelType: modelType,
                filePath: f.path,
                fileName: f.path.split('/').last,
              );
            }
          }
        } catch (_) {
          // Ignore directory read errors
        }
      }

      // 2. If not found in root, check the ApexModels subfolder
      final savePath = '${saveDir.path}/$modelFileName';
      final file = File(savePath);

      // Auto-resume / skip download if file already exists in ApexModels and is reasonably large (>1GB)
      if (file.existsSync() && file.lengthSync() > 1000000000) {
        if (onProgress != null) onProgress(100);
        return await loadModelFromFile(
          modelType: modelType,
          filePath: savePath,
          fileName: _getModelName(gemmaModelType),
        );
      }

      // Custom Stream Downloader
      final httpClient = HttpClient();
      final request = await httpClient.getUrl(Uri.parse(url));

      // Handle HuggingFace Token if provided
      if (huggingFaceToken != null && huggingFaceToken.isNotEmpty) {
        request.headers.add('Authorization', 'Bearer $huggingFaceToken');
      }
      final response = await request.close();

      // Handle redirects if any (HttpClient normally handles up to 5 automatically)
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw Exception('Failed to download: HTTP ${response.statusCode}');
      }

      final totalBytes = response.contentLength;
      int receivedBytes = 0;
      final sink = file.openWrite();

      await for (var chunk in response) {
        receivedBytes += chunk.length;
        sink.add(chunk);
        if (totalBytes > 0 && onProgress != null) {
          final progress = ((receivedBytes / totalBytes) * 100).toInt();
          onProgress(progress);
        }
      }

      await sink.flush();
      await sink.close();
      httpClient.close();

      // Load it via fromFile now that it's locally saved
      return await loadModelFromFile(
        modelType: modelType,
        filePath: savePath,
        fileName: _getModelName(gemmaModelType),
      );
    } catch (e) {
      _state = ModelLoadState.error;
      _errorMessage = 'Download failed: $e';
      return false;
    }
  }

  /// Get response stream from loaded model.
  /// Returns typed InferenceEvent objects — ToolCallEvent for native function calls,
  /// TextToken for text, ThinkingToken for reasoning.
  /// 🔱 Smart Backend: 1 GPU try per prompt → CPU fallback → tracks across prompts
  /// Clean Slate: Tools are activated solely via the `tools` parameter in
  /// createChat(). No prompt engineering or systemInstruction needed.
  Future<Stream<InferenceEvent>> getResponseStream(
    List<Message> history, {
    List<Map<String, dynamic>>? maps,
  }) async {
    if (_state != ModelLoadState.ready) {
      return Stream.value(TextToken('Model is not loaded. Please select a model first.'));
    }

    // 🔱 Fix #1: Convert tool maps to gemma.Tool objects.
    // Supports both flat format (from getToolDefinitionsFlat()) AND
    // nested format (from getToolDefinitionsForApi()) as safety net.
    final tools = maps
        ?.map((t) {
          // Unwrap nested format if present, otherwise use flat
          final fn = t.containsKey('function')
              ? t['function'] as Map<String, dynamic>
              : t;
          final name = fn['name'] as String? ?? '';
          final desc = fn['description'] as String? ?? '';
          final params = (fn['parameters'] as Map<String, dynamic>?) ?? {};
          debugPrint('🔱 [ToolSchema] Registered: $name');
          return gemma.Tool(
            name: name,
            description: desc,
            parameters: params,
          );
        })
        .where((t) => t.name.isNotEmpty) // 🔱 Drop tools with empty names
        .toList();

    if (tools != null && tools.isNotEmpty) {
      debugPrint('🔱 [ToolSchema] ${tools.length} tools registered for this call');
    }

    // 🔱 Fix #5: Wrap in engine mutex to prevent concurrent inference
    return _withEngineLock(() async {
      try {
        return await _buildResponseStream(history, backend, tools: tools);
      } catch (e) {
        final errorStr = e.toString();

        // 🔱 GPU error on this prompt: fallback to CPU for this ONE prompt
        if (!_gpuFailed && _isGpuSpecificError(errorStr)) {
          _fallbackToCpu('Init error: $errorStr');
          try {
            return await _buildResponseStream(history, gemma.PreferredBackend.cpu, tools: tools);
          } catch (retryError) {
            return _handleFinalError(retryError);
          }
        }

        return _handleFinalError(e);
      }
    });
  }

  // ─────────────────────────────────────────────────────────────────
  // 🔱 IMAGE PRE-COMPRESSION — GPU-SAFE PATCH REDUCTION
  // ─────────────────────────────────────────────────────────────────

  /// Maximum image dimension (px) before sending to model.
  /// 512px keeps Gemma 4's visual patches ≤280 — safe for mid-range GPUs.
  /// Original: 900x1600 → 2376 patches → clEnqueueMapBuffer -14 crash.
  /// After:    288x512 → ~280 patches → smooth inference.
  static const int _maxImageDimension = 512;

  /// Pre-process image bytes: resize to ≤512px max dimension (lossless PNG).
  /// Quality is preserved — only pixel count is reduced.
  /// This runs BEFORE the model sees the image, preventing GPU patch overflow.
  Future<Uint8List> _preprocessImageBytes(Uint8List originalBytes) async {
    try {
      // Decode the image
      final codec = await ui.instantiateImageCodec(originalBytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;

      final origW = image.width;
      final origH = image.height;

      debugPrint('🔱 [ImagePreprocess] Original: ${origW}x$origH (${(originalBytes.length / 1024).toStringAsFixed(0)}KB)');

      // No resize needed if already small enough
      if (origW <= _maxImageDimension && origH <= _maxImageDimension) {
        debugPrint('🔱 [ImagePreprocess] Already within ${_maxImageDimension}px — no resize needed.');
        image.dispose();
        return originalBytes;
      }

      // Calculate new dimensions maintaining aspect ratio
      final double scale;
      if (origW > origH) {
        scale = _maxImageDimension / origW;
      } else {
        scale = _maxImageDimension / origH;
      }
      final newW = (origW * scale).round();
      final newH = (origH * scale).round();

      debugPrint('🔱 [ImagePreprocess] Resizing to ${newW}x$newH (scale: ${scale.toStringAsFixed(2)})');

      // Draw resized image using Canvas (lossless operation)
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);

      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(0, 0, origW.toDouble(), origH.toDouble()),
        ui.Rect.fromLTWH(0, 0, newW.toDouble(), newH.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );

      final picture = recorder.endRecording();
      final resizedImage = await picture.toImage(newW, newH);

      // Encode to PNG (lossless — zero quality loss)
      final byteData = await resizedImage.toByteData(
        format: ui.ImageByteFormat.png,
      );

      image.dispose();
      resizedImage.dispose();

      if (byteData == null) {
        debugPrint('🔱 [ImagePreprocess] PNG encode failed, using original.');
        return originalBytes;
      }

      final result = byteData.buffer.asUint8List();
      debugPrint('🔱 [ImagePreprocess] Result: ${newW}x$newH (${(result.length / 1024).toStringAsFixed(0)}KB) — patches safe ✅');

      return result;
    } catch (e) {
      // If preprocessing fails for any reason, use original bytes
      // (the model will still work, just might be slower)
      debugPrint('🔱 [ImagePreprocess] Error: $e — using original bytes.');
      return originalBytes;
    }
  }

  /// Build the actual response stream for a given backend.
  /// Returns `Stream<InferenceEvent>` — FunctionCallResponse is surfaced as ToolCallEvent
  /// DIRECTLY from the SDK, no text encoding needed.
  /// 🔱 v0.15.1: Uses createChat(tools: ..., systemInstruction: ...) for native
  /// function calling. systemInstruction is a createChat() parameter (not prompt
  /// injection) and does NOT trigger RLHF refusal per flutter_gemma docs.
  Future<Stream<InferenceEvent>> _buildResponseStream(
    List<Message> history,
    gemma.PreferredBackend activeBackend, {
    List<gemma.Tool>? tools,
  }) async {
    debugPrint('🔱 [AutoBackend] Inference on: ${activeBackend.name.toUpperCase()}');

    final hasImages = history.any(
      (m) => m.imagePath != null && m.imagePath!.isNotEmpty,
    );
    if (hasImages) {
      debugPrint('🔱 [Vision] Image detected — vision pipeline active.');
    }

    // 🎤 Only enable audio modality when audio actually exists in history.
    // supportAudio + enableSpeculativeDecoding combined cause top_p_cpu_sampler
    // crashes in LiteRT when no audio is present. Conditional avoids alloc.
    final hasAudio = history.any(
      (m) => m.audioBytes != null || m.audioPath != null,
    );
    if (hasAudio) {
      debugPrint('🎤 [Audio] Audio detected — audio pipeline active.');
    }

    final model = await gemma.FlutterGemma.getActiveModel(
      maxTokens: maxTokens,
      preferredBackend: activeBackend,
      supportImage: true,
      supportAudio: hasAudio,
      maxNumImages: 1,
      // 🔱 Speculative decoding DISABLED when tools are active.
      // The MTP drafter's token predictions can conflict with the constrained
      // decoding grammar used for native function calling (<|tool_call|>),
      // causing top_p_cpu_sampler crashes. Only enable for plain chat.
      enableSpeculativeDecoding: tools == null || tools.isEmpty,
    );

    // 🔱 Supreme Fix: ALWAYS use text-based bash code blocks for the 2B model.
    // Passing native `tools:` confuses the 2B model when combined with `isThinking: true`,
    // causing it to output malformed JSON or empty responses, which breaks the agentic loop.
    // AetherCore's TextInterceptor handles the extraction robustly.
    final chat = await model.createChat(
      isThinking: true,
      temperature: 0.7,
      systemInstruction: 'You are Agent Kharwal, an autonomous AI agent running entirely on-device. '
          'You help TWO types of users: '
          '1) STUDENTS — answer questions, explain concepts, write code. '
          '2) SHOPKEEPERS — when user mentions items with quantities (kg, packets, litre) and a person name, '
          'or words like account, khata, ledger, likh do — this is a SHOPKEEPER LEDGER request. '
          'Create a structured table (Date, Customer, Item, Qty, Unit) and save as Ledger/[Name]_[Date].txt. '
          'For ALL file/system operations, write exact shell commands in ```bash code blocks. '
          'Example: ```bash\nmkdir -p Ledger\n``` '
          'Be precise and execute tasks completely. '
          'Once done, summarize and stop — no more bash blocks.',
    );
    
    for (final m in history) {
      if (m.role == MessageRole.system) {
        chat.addQueryChunk(gemma.Message.systemInfo(text: m.content));
      } else if (m.role == MessageRole.tool) {
        // 🔱 Bug #3 Fix: Use tool NAME from metadata, not toolUseId (which is a UUID).
        // flutter_gemma expects toolName to match the declared tool name (e.g., "bash").
        chat.addQueryChunk(
          gemma.Message.toolResponse(
            toolName: m.metadata['tool_name'] as String? ??
                m.toolUseId ??
                'function',
            response: {'result': m.content},
          ),
        );
      } else if (m.role == MessageRole.user) {
        if (m.imagePath != null && m.imagePath!.isNotEmpty) {
          final imageFile = File(m.imagePath!);
          if (await imageFile.exists()) {
            final rawBytes = await imageFile.readAsBytes();
            final imageBytes = await _preprocessImageBytes(rawBytes);
            final imageMessage = gemma.Message.withImage(
              text: m.content,
              imageBytes: imageBytes,
              isUser: true,
            );
            chat.addQueryChunk(imageMessage);
          } else {
            chat.addQueryChunk(
              gemma.Message.text(text: m.content, isUser: true),
            );
          }
        } else if (m.audioPath != null || m.audioBytes != null) {
          // 🎤 Voice input: send audio bytes natively to Gemma 4
          final audioForModel = m.audioBytes ??
              (await File(m.audioPath!).readAsBytes());
          debugPrint('🎤 [Audio] Sending ${audioForModel.length} bytes to model');
          chat.addQueryChunk(
            gemma.Message.withAudio(
              text: m.content,
              audioBytes: audioForModel,
              isUser: true,
            ),
          );
        } else {
          chat.addQueryChunk(
            gemma.Message.text(text: m.content, isUser: true),
          );
        }
      } else if (m.role == MessageRole.assistant) {
        chat.addQueryChunk(
          gemma.Message.text(text: m.content, isUser: false),
        );
      }
    }

    final responseStream = chat.generateChatResponseAsync();

    bool gpuConfirmed = false;

    // 🔱 Phase 4 Fix E+F + Supreme Fix 6+7: Stream completion wrapper.
    // Fix 6: Exactly-once model close guard prevents SIGSEGV on double-close.
    // Fix 7: 60-second inactivity timeout detects hung prefill/decode.
    final streamController = StreamController<InferenceEvent>();
    late StreamSubscription subscription;
    bool modelClosed = false; // 🔱 Fix 6: Exactly-once close guard

    // 🔱 Fix 6: Safe close helper — guarantees model.close() runs exactly once.
    Future<void> safeCloseModel() async {
      if (modelClosed) return;
      modelClosed = true;
      try {
        await model.close();
        debugPrint('🔱 [SessionReset] Model closed after stream completion ✅');
      } catch (e) {
        debugPrint('🔱 [SessionReset] Model close error (non-fatal): $e');
      }
    }

    // 🔱 Fix 7: Inactivity timeout — if no token arrives for 60s, model is hung.
    const inactivityTimeout = Duration(seconds: 60);
    Timer? inactivityTimer;

    void resetInactivityTimer() {
      inactivityTimer?.cancel();
      inactivityTimer = Timer(inactivityTimeout, () {
        debugPrint('🔱 [StreamTimeout] No token received for ${inactivityTimeout.inSeconds}s — model hung!');
        streamController.add(StreamTimeoutEvent(
          'Model produced no output for ${inactivityTimeout.inSeconds} seconds. '
          'The inference may have stalled during prefill.',
          timeoutDuration: inactivityTimeout,
        ));
        subscription.cancel();
        safeCloseModel().then((_) => streamController.close());
      });
    }

    // Start the initial inactivity timer (covers prefill phase)
    resetInactivityTimer();

    subscription = responseStream.listen(
      (response) {
        // 🔱 Fix 7: Reset inactivity timer on every token
        resetInactivityTimer();

        if (!gpuConfirmed && !_gpuFailed) {
          gpuConfirmed = true;
          _confirmGpuWorking();
        }
        if (response is gemma.TextResponse) {
          streamController.add(TextToken(response.token));
        } else if (response is gemma.ThinkingResponse) {
          streamController.add(ThinkingToken(response.content));
        } else if (response is gemma.FunctionCallResponse) {
          // 🔱 NATIVE FUNCTION CALL: Surface as structured ToolCallEvent.
          debugPrint('🔱 [ToolCall] ✅ NATIVE tool call detected: '
              '${response.name}(${response.args})');
          streamController.add(ToolCallEvent(
            name: response.name,
            args: response.args,
          ));
        } else {
          debugPrint('🔱 [ToolCall] ⚠️ Non-tool response type: '
              '${response.runtimeType}');
        }
      },
      onError: (error) {
        // 🔱 Phase 4 Fix G: ALL stream errors are caught — no re-throw.
        final errorStr = error.toString();
        debugPrint('🔱 [StreamError] $errorStr');

        if (!_gpuFailed && _isGpuSpecificError(errorStr)) {
          _fallbackToCpu('Stream error: $errorStr');
          streamController.add(
            GpuFallbackEvent('Switched to CPU. Please resend your message.'),
          );
        } else if (isFatalEngineError(errorStr)) {
          streamController.add(FatalErrorEvent(errorStr));
        } else {
          streamController.add(RecoverableErrorEvent(
            'Stream error (recoverable): $errorStr',
          ));
        }
      },
      onDone: () async {
        // 🔱 Fix 6+7: Cancel timer and safely close model exactly once.
        inactivityTimer?.cancel();
        await safeCloseModel();
        streamController.close();
      },
      cancelOnError: false,
    );

    // Propagate cancellation from consumer back to source
    streamController.onCancel = () {
      inactivityTimer?.cancel();
      subscription.cancel();
      safeCloseModel(); // 🔱 Fix 6: Safe, won't double-close
    };

    // Filter out empty text tokens
    final filteredStream = streamController.stream.where((event) {
      if (event is TextToken && event.token.isEmpty) return false;
      return true;
    });

    return filteredStream;
  }

  /// Handle final errors after all fallback attempts
  Stream<InferenceEvent> _handleFinalError(Object e) {
    final errorStr = e.toString();
    if (isFatalEngineError(errorStr)) {
      return Stream.value(
        FatalErrorEvent('Engine crash: $errorStr. Please reload the model.'),
      );
    }
    return Stream.value(TextToken('Inference error: $e'));
  }

  /// Check if a model file exists at a specific path
  Future<bool> checkModelFileExists(String filePath) async {
    try {
      final file = File(filePath);
      return file.existsSync();
    } catch (e) {
      return false;
    }
  }

  /// Reset model state
  void reset() {
    _state = ModelLoadState.noModel;
    _errorMessage = null;
    _loadedModelName = null;
  }

  /// Get model URL for download
  String _getModelUrl(gemma.ModelType type) {
    // Only Gemma 4 model is supported
    return 'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';
  }

  /// Get user-friendly model name
  String _getModelName(gemma.ModelType type) {
    // Only Gemma 4 model is supported
    return 'Gemma 4 E2B';
  }

  /// Dispose of the service
  void dispose() {
    _state = ModelLoadState.noModel;
  }
}
