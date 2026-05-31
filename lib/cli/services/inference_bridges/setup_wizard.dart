import 'dart:async';
import 'dart:io';

import 'package:apex_lite/cli/services/config_manager.dart';
import 'package:apex_lite/cli/services/inference_bridges/model_fetchers.dart';

/// 🔱 Interactive terminal setup wizard
Future<List<ProviderConfig>> runSetupWizard() async {
  print(
    '\n\x1B[36;1m============================================================\x1B[0m',
  );
  print(
    '\x1B[36;1m⟨K⟩             AGENT KHARWAL SETUP WIZARD               ⟨K⟩\x1B[0m',
  );
  print(
    '\x1B[36;1m============================================================\x1B[0m',
  );
  print('Welcome! Let\'s configure your Multi-Provider Failover Pool.');
  print('This system will try each provider in priority order.');
  print(
    'If one is rate-limited or fails, it will instantly switch to the next.',
  );
  print(
    'Your configuration will be permanently saved to:\n  \x1B[33m${ConfigManager.configFilePath}\x1B[0m\n',
  );

  final pool = ConfigManager.load();
  if (pool.isNotEmpty) {
    print('\x1B[36mCurrent configured failover pool:\x1B[0m');
    displayPoolTable(pool);
    print('(Selecting a provider below will update its settings, others will be preserved)\n');
  }

  var configuring = true;

  while (configuring) {
    print('\x1B[35;1mSelect an AI Provider to configure:\x1B[0m');
    print(
      '  \x1B[32m[1] Google Gemini\x1B[0m (Recommended, free tier, strong structured agent support)',
    );
    print(
      '  \x1B[32m[2] Groq Cloud\x1B[0m (Super-fast open source cloud models like Llama/Mixtral)',
    );
    print('  \x1B[32m[N] NVIDIA API\x1B[0m (Free DeepSeek/Llama integration)');
    print('  \x1B[32m[O] OpenRouter\x1B[0m (Unified API access to hundreds of flagship AI models)');
    print(
      '  \x1B[32m[3] Local Ollama\x1B[0m (100% offline, private, zero-cost)',
    );
    print(
      '  \x1B[32m[C] Custom Provider\x1B[0m (Configure Together, DeepInfra, Mistral, self-hosted proxy)',
    );
    print('  \x1B[33m[4] Finish and save configurations & start agent\x1B[0m');
    stdout.write('\nEnter option [1-4, N, O, C]: ');

    final choice = stdin.readLineSync()?.trim();
    if (choice == '1') {
      print('\n\x1B[36m--- Configuring Google Gemini ---\x1B[0m');
      stdout.write('Enter your Gemini API Key: ');
      final key = stdin.readLineSync()?.trim() ?? '';
      if (key.isEmpty) {
        print('❌ Key cannot be empty. Returning to menu.');
        continue;
      }

      print('⏳ Verifying API key and fetching available models...');
      try {
        final models = await fetchGeminiModels(key);
        if (models.isEmpty) {
          print(
            '⚠️ Key verified but no generation models were returned. Defaulting to gemini-2.5-flash.',
          );
          models.add('gemini-2.5-flash');
        }

        print('\nAvailable Gemini Models:');
        for (int i = 0; i < models.length; i++) {
          print('  [${i + 1}] ${models[i]}');
        }
        stdout.write(
          'Select model [1-${models.length}] or press Enter for [gemini-2.5-flash]: ',
        );
        final modelChoice = stdin.readLineSync()?.trim() ?? '';
        String selectedModel = 'gemini-2.5-flash';
        if (modelChoice.isNotEmpty) {
          final idx = int.tryParse(modelChoice);
          if (idx != null && idx > 0 && idx <= models.length) {
            selectedModel = models[idx - 1];
          } else {
            selectedModel = modelChoice;
          }
        }

        final newConfig = ProviderConfig(type: 'gemini', apiKey: key, model: selectedModel);
        final idx = pool.indexWhere((p) => p.type == 'gemini');
        if (idx != -1) {
          pool[idx] = newConfig;
        } else {
          pool.add(newConfig);
        }
        print(
          '\n\x1B[32m✓ Google Gemini ($selectedModel) added to the pool!\x1B[0m\n',
        );
      } catch (e) {
        print('\n\x1B[31m❌ API key verification failed: $e\x1B[0m\n');
      }
    } else if (choice == '2') {
      print('\n\x1B[36m--- Configuring Groq Cloud ---\x1B[0m');
      stdout.write('Enter your Groq API Key: ');
      final key = stdin.readLineSync()?.trim() ?? '';
      if (key.isEmpty) {
        print('❌ Key cannot be empty. Returning to menu.');
        continue;
      }

      print('⏳ Verifying API key and fetching available models...');
      try {
        final models = await fetchGroqModels(key);
        if (models.isEmpty) {
          print(
            '⚠️ Key verified but no models were returned. Defaulting to llama-3.3-70b-versatile.',
          );
          models.add('llama-3.3-70b-versatile');
        }

        print('\nAvailable Groq Models:');
        for (int i = 0; i < models.length; i++) {
          print('  [${i + 1}] ${models[i]}');
        }
        stdout.write(
          'Select model [1-${models.length}] or press Enter for [llama-3.3-70b-versatile]: ',
        );
        final modelChoice = stdin.readLineSync()?.trim() ?? '';
        String selectedModel = 'llama-3.3-70b-versatile';
        if (modelChoice.isNotEmpty) {
          final idx = int.tryParse(modelChoice);
          if (idx != null && idx > 0 && idx <= models.length) {
            selectedModel = models[idx - 1];
          } else {
            selectedModel = modelChoice;
          }
        }

        final newConfig = ProviderConfig(type: 'groq', apiKey: key, model: selectedModel);
        final idx = pool.indexWhere((p) => p.type == 'groq');
        if (idx != -1) {
          pool[idx] = newConfig;
        } else {
          pool.add(newConfig);
        }
        print(
          '\n\x1B[32m✓ Groq Cloud ($selectedModel) added to the pool!\x1B[0m\n',
        );
      } catch (e) {
        print('\n\x1B[31m❌ API key verification failed: $e\x1B[0m\n');
      }
    } else if (choice == 'n' || choice == 'N') {
      print('\n\x1B[36m--- Configuring NVIDIA API ---\x1B[0m');
      stdout.write('Enter your NVIDIA API Key: ');
      final apiKey = stdin.readLineSync()?.trim() ?? '';
      if (apiKey.isEmpty) {
        print('\x1B[31m❌ API key cannot be empty.\x1B[0m\n');
        continue;
      }
      print('⏳ Connecting to NVIDIA and fetching models...');
      try {
        final models = await fetchNvidiaModels(apiKey);
        if (models.isEmpty) {
          models.add('deepseek-ai/deepseek-v4-flash');
        }
        print('\nAvailable NVIDIA Models:');
        for (int i = 0; i < models.length; i++) {
          print('  [${i + 1}] ${models[i]}');
        }
        stdout.write('Select model [1-${models.length}] or press Enter for [deepseek-ai/deepseek-v4-flash]: ');
        final modelChoice = stdin.readLineSync()?.trim() ?? '';
        String selectedModel = 'deepseek-ai/deepseek-v4-flash';
        if (modelChoice.isNotEmpty) {
          final idx = int.tryParse(modelChoice);
          if (idx != null && idx > 0 && idx <= models.length) {
            selectedModel = models[idx - 1];
          } else {
            selectedModel = modelChoice;
          }
        }
        final newConfig = ProviderConfig(
          type: 'nvidia',
          apiKey: apiKey,
          model: selectedModel,
        );
        final idx = pool.indexWhere((p) => p.type == 'nvidia');
        if (idx != -1) {
          pool[idx] = newConfig;
        } else {
          pool.add(newConfig);
        }
        print('\n\x1B[32m✓ NVIDIA ($selectedModel) added to the pool!\x1B[0m\n');
      } catch (e) {
        print('\n\x1B[31m❌ NVIDIA connection failed: $e\x1B[0m\n');
      }
    } else if (choice == '3') {
      print('\n\x1B[36m--- Configuring Ollama (Zero-Config Auto-Detect) ---\x1B[0m');

      // Native official Ollama Environment Detection
      final envHost = Platform.environment['OLLAMA_HOST'];
      final envKey = Platform.environment['OLLAMA_API_KEY'];

      String baseUrl = envHost?.trim() ?? 'http://localhost:11434';
      baseUrl = baseUrl.replaceAll(RegExp(r'/$'), '');
      String apiKey = envKey?.trim() ?? '';
      bool isCloud = apiKey.isNotEmpty || baseUrl.contains('ollama.com');
      List<String> models = [];
      bool autoDetected = false;

      if (envHost != null || envKey != null) {
        print('\x1B[32m✓ Natively detected Ollama environment variables:\x1B[0m');
        if (envHost != null) print('  • OLLAMA_HOST: $baseUrl');
        if (envKey != null) {
          final maskLen = apiKey.length > 4 ? apiKey.length - 4 : 0;
          print('  • OLLAMA_API_KEY: ****${apiKey.substring(maskLen)}');
        }
      }

      print('⏳ Scanning for Ollama instance on $baseUrl...');

      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
        final request = await client.getUrl(Uri.parse('$baseUrl/api/tags'));
        final response = await request.close();
        if (response.statusCode == 200) {
          autoDetected = true;
          print('\x1B[32m✓ Connected to active Ollama server at $baseUrl!\x1B[0m');
        }
      } catch (_) {
        // Not running locally or timed out
      }

      if (autoDetected) {
        print('⏳ Fetching local models...');
        try {
          models = await fetchOllamaModels(baseUrl);
        } catch (_) {}
      }

      if (!autoDetected) {
        print('\x1B[33m⚠ No running Ollama instance was detected on the default port.\x1B[0m');
        print('  [1] Custom URL or Remote Proxy (Manually configure local/cloud Ollama)');
        print('  [2] Try scanning http://localhost:11434 again');
        stdout.write('\nSelect option [1-2, default: 1]: ');
        final opt = stdin.readLineSync()?.trim() ?? '';

        if (opt == '2') {
          print('⏳ Scanning http://localhost:11434 again...');
          try {
            models = await fetchOllamaModels(baseUrl);
            autoDetected = true;
            print('\x1B[32m✓ Connected to http://localhost:11434!\x1B[0m');
          } catch (e) {
            print('\x1B[31m❌ Scan failed: $e\x1B[0m');
          }
        }

        if (!autoDetected) {
          // Advanced configuration fallback
          print('\n\x1B[36m--- Manual Ollama Configuration ---\x1B[0m');
          print('Ollama supports both local offline models and cloud-hosted reasoning models.');
          print('  \x1B[32m[1] Local Offline Models\x1B[0m (requires models pulled locally via \'ollama pull\')');
          print('  \x1B[32m[2] Ollama Cloud Models\x1B[0m (free cloud reasoning e.g. kimi-k2.5:cloud, qwen3.5:cloud)');
          stdout.write('\nSelect Ollama type [1-2, default: 1]: ');
          final typeChoice = stdin.readLineSync()?.trim() ?? '';
          isCloud = typeChoice == '2';

          if (isCloud) {
            print('\n\x1B[36m--- Ollama Cloud Model Access ---\x1B[0m');
            print('  [1] Local Ollama Proxy (default: http://localhost:11434, offloads to cloud automatically)');
            print('  [2] Remote Ollama API (https://ollama.com, direct cloud API access)');
            stdout.write('Select connection path [1-2, default: 1]: ');
            final pathChoice = stdin.readLineSync()?.trim() ?? '';

            if (pathChoice == '2') {
              baseUrl = 'https://ollama.com';
              stdout.write('Enter your Ollama.com Cloud API Key: ');
              apiKey = stdin.readLineSync()?.trim() ?? '';
              if (apiKey.isEmpty) {
                print('❌ API Key cannot be empty for direct Ollama Cloud access. Returning to menu.');
                continue;
              }
            } else {
              stdout.write('Enter Local Ollama Base URL [default: http://localhost:11434]: ');
              final enteredUrl = stdin.readLineSync()?.trim() ?? '';
              if (enteredUrl.isNotEmpty) {
                baseUrl = enteredUrl;
              }
            }
          } else {
            stdout.write('Enter Ollama Base URL [default: http://localhost:11434]: ');
            final enteredUrl = stdin.readLineSync()?.trim() ?? '';
            if (enteredUrl.isNotEmpty) {
              baseUrl = enteredUrl;
            }
            if (baseUrl.contains('ollama.com')) {
              isCloud = true;
              stdout.write('Enter your Ollama.com Cloud API Key: ');
              apiKey = stdin.readLineSync()?.trim() ?? '';
            } else {
              stdout.write('Enter Ollama Auth Token / API Key (optional, press Enter to skip): ');
              apiKey = stdin.readLineSync()?.trim() ?? '';
            }
          }

          print('⏳ Connecting to Ollama...');
          try {
            models = await fetchOllamaModels(baseUrl, apiKey: apiKey);
          } catch (e) {
            print('\n\x1B[31m❌ Connection failed: $e\x1B[0m\n');
            continue;
          }
        }
      }

      // We have models!
      if (models.isEmpty && isCloud) {
        models.addAll([
          'kimi-k2.5:cloud',
          'qwen3.5:cloud',
          'glm-5.1:cloud',
          'minimax-m2.7:cloud',
          'gpt-oss:120b-cloud',
        ]);
      }

      if (models.isEmpty) {
        print('⚠️ Connected but no models found on Ollama. Defaulting to gemma:2b.');
        models.add('gemma:2b');
      }

      print('\nAvailable Ollama Models:');
      for (int i = 0; i < models.length; i++) {
        print('  [${i + 1}] ${models[i]}');
      }

      final defaultModel = isCloud ? 'kimi-k2.5:cloud' : (models.contains('gemma:2b') ? 'gemma:2b' : models.first);
      stdout.write('Select model [1-${models.length}] or press Enter for [$defaultModel]: ');
      final modelChoice = stdin.readLineSync()?.trim() ?? '';
      String selectedModel = defaultModel;
      if (modelChoice.isNotEmpty) {
        final idx = int.tryParse(modelChoice);
        if (idx != null && idx > 0 && idx <= models.length) {
          selectedModel = models[idx - 1];
        } else {
          selectedModel = modelChoice;
        }
      }

      final newConfig = ProviderConfig(
        type: 'ollama',
        apiKey: apiKey,
        model: selectedModel,
        baseUrl: baseUrl,
      );
      final idx = pool.indexWhere((p) => p.type == 'ollama');
      if (idx != -1) {
        pool[idx] = newConfig;
      } else {
        pool.add(newConfig);
      }
      print('\n\x1B[32m✓ Ollama ($selectedModel) added to the pool!\x1B[0m\n');
    } else if (choice == 'o' || choice == 'O') {
      print('\n\x1B[36m--- Configuring OpenRouter ---\x1B[0m');
      stdout.write('Enter your OpenRouter API Key: ');
      final apiKey = stdin.readLineSync()?.trim() ?? '';
      if (apiKey.isEmpty) {
        print('\x1B[31m❌ API key cannot be empty.\x1B[0m\n');
        continue;
      }
      print('⏳ Connecting to OpenRouter and fetching models...');
      try {
        final models = await fetchOpenRouterModels();
        if (models.isEmpty) {
          models.add('~openai/gpt-latest');
        }
        print('\nAvailable OpenRouter Models:');
        for (int i = 0; i < models.length; i++) {
          print('  [${i + 1}] ${models[i]}');
        }
        stdout.write('Select model [1-${models.length}] or press Enter for [~openai/gpt-latest]: ');
        final modelChoice = stdin.readLineSync()?.trim() ?? '';
        String selectedModel = '~openai/gpt-latest';
        if (modelChoice.isNotEmpty) {
          final idx = int.tryParse(modelChoice);
          if (idx != null && idx > 0 && idx <= models.length) {
            selectedModel = models[idx - 1];
          } else {
            selectedModel = modelChoice;
          }
        }
        final newConfig = ProviderConfig(
          type: 'openrouter',
          apiKey: apiKey,
          model: selectedModel,
        );
        final idx = pool.indexWhere((p) => p.type == 'openrouter');
        if (idx != -1) {
          pool[idx] = newConfig;
        } else {
          pool.add(newConfig);
        }
        print('\n\x1B[32m✓ OpenRouter ($selectedModel) added to the pool!\x1B[0m\n');
      } catch (e) {
        print('\n\x1B[31m❌ OpenRouter connection failed: $e\x1B[0m\n');
      }
    } else if (choice == 'c' || choice == 'C') {
      print('\n\x1B[36m--- Configuring Custom OpenAI-Compatible Provider ---\x1B[0m');
      stdout.write('Enter a Unique Provider Name (e.g. together, deepinfra, local-proxy): ');
      final name = stdin.readLineSync()?.trim().toLowerCase() ?? '';
      if (name.isEmpty) {
        print('\x1B[31m❌ Provider name cannot be empty. Returning to menu.\x1B[0m\n');
        continue;
      }

      if (['gemini', 'groq', 'nvidia', 'openrouter', 'ollama'].contains(name)) {
        print('\x1B[31m❌ "$name" is a reserved system provider. Please choose another unique name.\x1B[0m\n');
        continue;
      }

      stdout.write('Enter API Base URL (e.g. https://api.together.xyz/v1): ');
      final baseUrl = stdin.readLineSync()?.trim() ?? '';
      if (baseUrl.isEmpty) {
        print('\x1B[31m❌ Base URL cannot be empty. Returning to menu.\x1B[0m\n');
        continue;
      }

      stdout.write('Enter API Key (press Enter to skip if not needed): ');
      final apiKey = stdin.readLineSync()?.trim() ?? '';

      stdout.write('Enter Model Name (e.g. meta-llama/Llama-3-70b-chat-hf): ');
      final model = stdin.readLineSync()?.trim() ?? '';
      if (model.isEmpty) {
        print('\x1B[31m❌ Model name cannot be empty. Returning to menu.\x1B[0m\n');
        continue;
      }

      final newConfig = ProviderConfig(
        type: name,
        apiKey: apiKey,
        model: model,
        baseUrl: baseUrl,
      );

      final idx = pool.indexWhere((p) => p.type == name);
      if (idx != -1) {
        pool[idx] = newConfig;
      } else {
        pool.add(newConfig);
      }
      print('\n\x1B[32m✓ Custom Provider "$name" ($model) added to the pool!\x1B[0m\n');
    } else if (choice == '4') {
      if (pool.isEmpty) {
        print(
          '\x1B[31m❌ You must configure at least one active provider before finishing!\x1B[0m\n',
        );
      } else {
        configuring = false;
      }
    } else {
      print('❌ Invalid option. Try again.\n');
    }
  }

  print('\x1B[32;1m✓ Configuration completed successfully!\x1B[0m');
  print('Saving settings...');
  ConfigManager.save(pool);
  return pool;
}

/// 🔱 Render configured pool beautifully in terminal
void displayPoolTable(List<ProviderConfig> pool) {
  print(
    '\n\x1B[36m┌──────────┬──────────┬─────────────────────────────┬────────┐\x1B[0m',
  );
  print(
    '\x1B[36m│\x1B[0m Priority \x1B[36m│\x1B[0m Provider \x1B[36m│\x1B[0m Model                       \x1B[36m│\x1B[0m Status \x1B[36m│\x1B[0m',
  );
  print(
    '\x1B[36m├──────────┼──────────┼─────────────────────────────┼────────┤\x1B[0m',
  );
  for (int i = 0; i < pool.length; i++) {
    final provider = pool[i];
    final priority = '#${i + 1}'.padRight(8);
    final type = provider.type.toUpperCase().padRight(8);
    final model = provider.model.length > 27
        ? '${provider.model.substring(0, 24)}...'
        : provider.model.padRight(27);
    final status = (i == 0 ? '✅Active' : '🛡️Backup').padRight(8);
    print(
      '\x1B[36m│\x1B[0m $priority \x1B[36m│\x1B[0m $type \x1B[36m│\x1B[0m $model \x1B[36m│\x1B[0m $status\x1B[36m│\x1B[0m',
    );
  }
  print(
    '\x1B[36m└──────────┴──────────┴─────────────────────────────┴────────┘\x1B[0m',
  );
}
