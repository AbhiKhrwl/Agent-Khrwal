import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../domain/entities/message.dart';
import '../../domain/entities/inference_event.dart';
import '../../../cli/services/config_manager.dart';
import '../../../cli/services/provider_health_registry.dart';
import '../services/local_inference_service.dart';
import '../heartbeat/aether_core.dart';
import '../../../cli/services/inference_bridges/gemini_bridge.dart';
import '../../../cli/services/inference_bridges/groq_bridge.dart';
import '../../../cli/services/inference_bridges/nvidia_bridge.dart';
import '../../../cli/services/inference_bridges/openrouter_bridge.dart';
import '../../../cli/services/inference_bridges/ollama_bridge.dart';
import '../../../cli/services/inference_bridges/custom_bridge.dart';
import '../services/plan_mode_coordinator.dart';
import '../heartbeat/history_compactor.dart';
import 'background_task_service.dart';
import '../../domain/interfaces/i_tool.dart';
import '../router/agent_router.dart';

/// 🔱 Hybrid Inference Coordinator
///
/// Orchestrates inference across Local, Cloud-Only, and adaptive Hybrid modes.
/// Supports multi-provider waterfall routing, active provider health tracking,
/// error classification, and real-time status heartbeats.
class HybridInferenceCoordinator {
  final LocalInferenceService localInference;
  final ProviderHealthRegistry healthRegistry = ProviderHealthRegistry.instance;
  final AetherCore core;

  final _statusController = StreamController<String>.broadcast();
  
  /// Real-time stream of coordinator statuses (compaction, failovers, provider health)
  Stream<String> get statusStream => _statusController.stream;

  HybridInferenceCoordinator({
    required this.localInference,
    required this.core,
  });

  void _sendStatus(String msg) {
    debugPrint('🔱 [HybridCoordinator] $msg');
    _statusController.add(msg);
  }

  /// Get response stream based on selected execution mode
  Future<Stream<InferenceEvent>> getResponseStream(
    List<Message> history, {
    List<ITool>? tools,
  }) async {
    // 🔱 OS WakeLock: Activate Foreground Service in a non-blocking asynchronous call
    BackgroundTaskService.start();

    final executionMode = ConfigManager.loadExecutionMode();
    _sendStatus('Active Execution Mode: ${executionMode.name.toUpperCase()}');

    Stream<InferenceEvent> baseStream;
    
    // 🔱 Dynamic Threshold Scaling for Progressive Tool Disclosure
    // Restrict local/gemma model to core + bridge tools (low threshold = 2000 tokens)
    // so it doesn't get overwhelmed, but still has access to ALL tools dynamically!
    if (executionMode == ExecutionMode.local || executionMode == ExecutionMode.hybrid) {
      AgentRouter.progressiveDisclosureThreshold = 2000;
    } else {
      AgentRouter.progressiveDisclosureThreshold = 10000;
    }
    
    // Retrieve active tools list dynamically
    final activeTools = core.router.getActiveTools();
    final flatTools = _convertToFlatDefinitions(activeTools);

    switch (executionMode) {
      case ExecutionMode.local:
        if (localInference.state != ModelLoadState.ready) {
          await BackgroundTaskService.stop();
          return Stream.value(TextToken('Local model is not loaded. Please select/download a model first in local mode.'));
        }
        _updateCoreContextLimits('local', localInference.loadedModelName ?? 'gemma4');
        _sendStatus('Executing local inference (Gemma 4)...');
        baseStream = await localInference.getResponseStream(history, maps: flatTools);
        break;

      case ExecutionMode.cloud:
        baseStream = await _buildCloudWaterfallStream(history, tools: tools);
        break;

      case ExecutionMode.hybrid:
        // Try local first IF model is loaded and ready
        if (localInference.state == ModelLoadState.ready) {
          _sendStatus('Attempting local inference on-device...');
          _updateCoreContextLimits('local', localInference.loadedModelName ?? 'gemma4');
          try {
            final localStream = await localInference.getResponseStream(history, maps: flatTools);
            
            // Check if the stream first element throws error or returns a failure event
            final localController = StreamController<InferenceEvent>();
            late StreamSubscription sub;
            bool localErrorHappened = false;
            bool firstTokenStreamed = false;

            sub = localStream.listen(
              (event) {
                if (event is FatalErrorEvent) {
                  localErrorHappened = true;
                  _sendStatus('Local engine crash detected! Rescuing to Cloud Waterfall pool...');
                  sub.cancel();
                  _buildCloudWaterfallStream(history, tools: tools).then((cloudStream) {
                    localController.addStream(cloudStream).then((_) => localController.close());
                  });
                } else {
                  if (!firstTokenStreamed && event is TextToken && event.token.isNotEmpty) {
                    firstTokenStreamed = true;
                    _sendStatus('Local model streaming tokens... ✅');
                  }
                  localController.add(event);
                }
              },
              onError: (err) {
                localErrorHappened = true;
                _sendStatus('Local stream error: $err. Rescuing to Cloud Waterfall pool...');
                sub.cancel();
                _buildCloudWaterfallStream(history, tools: tools).then((cloudStream) {
                  localController.addStream(cloudStream).then((_) => localController.close());
                });
              },
              onDone: () {
                if (!localErrorHappened) {
                  localController.close();
                }
              },
              cancelOnError: false,
            );

            localController.onCancel = () {
              sub.cancel();
            };

            baseStream = localController.stream;
          } catch (e) {
            _sendStatus('Local initialization failed: $e. Seamlessly falling back to Cloud waterfall...');
            baseStream = await _buildCloudWaterfallStream(history, tools: tools);
          }
        } else {
          _sendStatus('Local model not loaded. Seamlessly falling back to Cloud waterfall...');
          baseStream = await _buildCloudWaterfallStream(history, tools: tools);
        }
        break;
    }

    // Wrap the returned stream so that Foreground Service stops immediately when inference completes
    final controller = StreamController<InferenceEvent>();
    late StreamSubscription<InferenceEvent> sub;
    bool hasStopped = false;

    Future<void> stopServiceOnce() async {
      if (!hasStopped) {
        hasStopped = true;
        await BackgroundTaskService.stop();
      }
    }

    sub = baseStream.listen(
      (event) {
        controller.add(event);
      },
      onError: (err) {
        controller.addError(err);
        stopServiceOnce();
      },
      onDone: () {
        controller.close();
        stopServiceOnce();
      },
      cancelOnError: false,
    );

    controller.onCancel = () {
      sub.cancel();
      stopServiceOnce();
    };

    return controller.stream;
  }

  /// Builds a waterfall cascade stream across configured cloud providers
  Future<Stream<InferenceEvent>> _buildCloudWaterfallStream(
    List<Message> history, {
    List<ITool>? tools,
  }) async {
    final activePool = ConfigManager.load();
    if (activePool.isEmpty) {
      _sendStatus('⚠️ No cloud providers configured in settings!');
      return Stream.value(TextToken('No cloud providers configured. Please open settings and configure a cloud API key (e.g. Gemini, Groq).'));
    }

    final totalChars = history.fold<int>(0, (sum, msg) => sum + msg.content.length);
    final exceeds200k = (totalChars / 4) > 200000;

    // Filter available pool (healthy and cooled-down)
    final sortedPool = healthRegistry.getAvailablePool<ProviderConfig>(
      activePool,
      (config) => config.type,
    );

    if (sortedPool.isEmpty) {
      _sendStatus('❌ All cloud providers are currently exhausted or on cooldown.');
      return Stream.value(TextToken('All configured cloud providers are on cooldown. Please wait or check your API keys.'));
    }

    String? lastError;
    final hasHealthy = activePool.any(
      (p) => healthRegistry.isAvailable(p.type) && 
             !healthRegistry.getRecord(p.type).isPermanentlyDisabled
    );

    _sendStatus('Connecting to cloud provider...');

    for (int i = 0; i < sortedPool.length; i++) {
      final provider = sortedPool[i];

      // Skip providers on cooldown if healthy alternatives exist
      if (hasHealthy && !healthRegistry.isAvailable(provider.type)) {
        final record = healthRegistry.getRecord(provider.type);
        _sendStatus('Skipping ${provider.type.toUpperCase()} (cooldown: ${record.statusLabel})');
        continue;
      }

      final modelsToTry = PlanModeCoordinator.instance.getRuntimeModelList(
        mainLoopModel: provider.model,
        exceeds200kTokens: exceeds200k,
        providerType: provider.type,
      );

      // 🔱 Dynamic Threshold Scaling for Progressive Tool Disclosure
      // If the cloud provider is a local Ollama or Custom endpoint, trigger Progressive Tool Disclosure (threshold = 2000 tokens)
      // to keep schemas lightweight while maintaining full power. Otherwise, allow the full 10k token schema natively.
      if (provider.type == 'ollama' || provider.type.startsWith('custom')) {
        AgentRouter.progressiveDisclosureThreshold = 2000;
      } else {
        AgentRouter.progressiveDisclosureThreshold = 10000;
      }
      
      final activeToolsList = tools ?? core.router.getActiveTools();

      for (final targetModel in modelsToTry) {
        try {
          _updateCoreContextLimits(provider.type, targetModel, userConfigLimit: provider.contextLimit);
          _sendStatus('${provider.type.toUpperCase()} ➔ $targetModel');

          Stream<InferenceEvent>? stream;

          if (provider.type == 'gemini') {
            stream = await callDirectGeminiModel(
              history,
              provider.apiKey,
              targetModel,
              tools: activeToolsList,
            );
          } else if (provider.type == 'groq') {
            stream = await callDirectGroqModel(
              history,
              provider.apiKey,
              targetModel,
              tools: activeToolsList,
              onStatus: (status) => _sendStatus(status),
            );
          } else if (provider.type == 'nvidia') {
            stream = await callDirectNvidiaModel(
              history,
              provider.apiKey,
              targetModel,
              tools: activeToolsList,
              onStatus: (status) => _sendStatus(status),
            );
          } else if (provider.type == 'openrouter') {
            stream = await callDirectOpenRouterModel(
              history,
              provider.apiKey,
              targetModel,
              tools: activeToolsList,
              onStatus: (status) => _sendStatus(status),
            );
          } else if (provider.type == 'ollama') {
            stream = await callLocalOllamaModel(
              history,
              provider.baseUrl,
              targetModel,
              tools: activeToolsList,
              apiKey: provider.apiKey,
              think: false,
            );
          } else {
            stream = await callGenericOpenAIModel(
              history,
              provider.baseUrl,
              provider.apiKey,
              targetModel,
              tools: activeToolsList,
              onStatus: (status) => _sendStatus(status),
            );
          }

          _sendStatus('Connected successfully ✅');
          return _wrapStreamWithHealthTracking(stream, provider.type, targetModel);
        } catch (e) {
          _sendStatus('${provider.type.toUpperCase()} failed: $e. Recovering...');
          lastError = e.toString();

          final classification = ProviderHealthRegistry.classifyError(provider.type, e);

          healthRegistry.recordFailure(
            provider.type,
            targetModel,
            classification.type,
            e.toString(),
            cooldown: classification.cooldown,
          );

          if (classification.type == FailureType.contextOverflow) {
            _sendStatus('Compacting memory due to context overflow...');
            final compactor = AetherHistoryCompactor();
            
            // Dummy stream controller to hook compaction statuses
            final dummyController = StreamController<Map<String, dynamic>>()..stream.listen((event) {
              if (event['type'] == 'status') {
                _sendStatus('Compaction: ${event['data']}');
              }
            });

            final compacted = await compactor.compactHistory(
              history,
              (tempHistory) => getResponseStream(tempHistory, tools: tools),
              eventController: dummyController,
            );

            await dummyController.close();

            if (compacted) {
              _sendStatus('Compaction complete. Retrying request...');
              return await getResponseStream(history, tools: tools);
            }
          }
          
          // Try next candidate model
          continue;
        }
      }
    }

    _sendStatus('All cloud providers exhausted or failed ❌');
    return Stream.value(TextToken('Supreme Waterfall failover exhausted all cloud candidates. Last error: $lastError'));
  }

  /// Wraps a stream with provider health monitoring
  Stream<InferenceEvent> _wrapStreamWithHealthTracking(
    Stream<InferenceEvent> stream,
    String providerType,
    String modelName,
  ) {
    final controller = StreamController<InferenceEvent>();
    late StreamSubscription sub;
    bool hasProducedTokens = false;

    sub = stream.listen(
      (event) {
        if (!hasProducedTokens && (event is TextToken || event is ThinkingToken || event is ToolCallEvent)) {
          hasProducedTokens = true;
          healthRegistry.recordSuccess(providerType, modelName);
        }
        controller.add(event);
      },
      onError: (err) {
        final classification = ProviderHealthRegistry.classifyError(providerType, err);
        healthRegistry.recordFailure(
          providerType,
          modelName,
          classification.type,
          err.toString(),
          cooldown: classification.cooldown,
        );
        _sendStatus('${providerType.toUpperCase()} stream error: $err');
        controller.addError(err);
      },
      onDone: () {
        controller.close();
      },
      cancelOnError: false,
    );

    controller.onCancel = () {
      sub.cancel();
    };

    return controller.stream;
  }

  /// Converts a list of ITool elements to flat Map representation expected by local inference
  List<Map<String, dynamic>>? _convertToFlatDefinitions(List<ITool>? activeTools) {
    if (activeTools == null) return null;
    return activeTools.map((tool) {
      final properties = <String, dynamic>{};
      final required = <String>[];

      final schema = tool.parameterSchema;
      if (schema.containsKey('properties')) {
        final props = Map<String, dynamic>.from(schema['properties'] as Map);
        for (final key in props.keys) {
          final p = Map<String, dynamic>.from(props[key] as Map);
          properties[key] = {
            'type': p['type'] ?? 'string',
            'description': p['description'] ?? '',
          };
        }
      }
      if (schema.containsKey('required')) {
        required.addAll(List<String>.from(schema['required'] as Iterable));
      }

      return {
        'name': tool.name,
        'description': tool.description,
        'parameters': {
          'type': 'object',
          'properties': properties,
          'required': required,
        }
      };
    }).toList();
  }

  /// 🔱 Dynamic Context Control Dispatcher
  /// Computes context window ceilings dynamically based on providerType, modelName, and custom limits.
  /// Enforces RAM protection ceiling for local models to prevent system force-kills.
  void _updateCoreContextLimits(String providerType, String modelName, {int? userConfigLimit}) {
    // 1. Determine if local model (on-device execution)
    final isLocal = providerType == 'local' || providerType == 'ollama' || providerType.startsWith('custom_local');
    core.isLocalMode = isLocal;

    // 2. Compute dynamic context window limit based on name/type
    if (userConfigLimit != null) {
      core.activeContextLimit = userConfigLimit;
    } else {
      final modelLower = modelName.toLowerCase();
      if (modelLower.contains('1m') || modelLower.contains('2m') || modelLower.contains('gemini')) {
        core.activeContextLimit = 1000000;
      } else if (modelLower.contains('128k') ||
                 modelLower.contains('llama-3.1') ||
                 modelLower.contains('llama-3.3') ||
                 modelLower.contains('nemotron') ||
                 modelLower.contains('qwen')) {
        core.activeContextLimit = 131072;
      } else if (modelLower.contains('32k') || modelLower.contains('gemma')) {
        core.activeContextLimit = 32768;
      } else if (modelLower.contains('8k')) {
        core.activeContextLimit = 8192;
      } else {
        // Fallback baseline defaults (safeguards)
        core.activeContextLimit = isLocal ? 8192 : 32768;
      }
    }

    // 🔱 Extreme Local RAM Safety Gate
    // LiteRT-LM allocations above 8K context are unsafe on mid-tier mobile RAM. Force ceiling.
    if (isLocal && core.activeContextLimit > 8192) {
      core.activeContextLimit = 8192;
    }

    _sendStatus('🔱 Context Limits Synchronized — Model: $modelName, Ceiling: ${core.activeContextLimit}, Local mode: ${core.isLocalMode}');
  }
}
