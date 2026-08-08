import 'package:flutter_test/flutter_test.dart';
import 'package:apex_lite/core/infrastructure/services/apex_streaming_thought_scrubber.dart';
import 'package:apex_lite/cli/services/provider_health_registry.dart';

void main() {
  group('ApexStreamingThoughtScrubber - Stateful Split Tag Scrubbing', () {
    test('Should scrub thought tags cleanly when streamed in standard text', () {
      final scrubber = ApexStreamingThoughtScrubber();
      
      final out1 = scrubber.feed('Hello ');
      final out2 = scrubber.feed('<think>Analyzing database structures...</think>');
      final out3 = scrubber.feed('World!');
      
      expect(out1, equals('Hello '));
      expect(out2, isEmpty);
      expect(out3, equals('World!'));
      expect(scrubber.flush(), isEmpty);
    });

    test('Should suppress thought and context tags split across chunk boundaries', () {
      final scrubber = ApexStreamingThoughtScrubber();

      // Chunk 1: Ends with partial tag "<thi"
      final out1 = scrubber.feed('Hello <thi');
      expect(out1, equals('Hello ')); // "<thi" is held back in lookahead buffer

      // Chunk 2: Completes open tag and starts reasoning
      final out2 = scrubber.feed('nk> Let\'s read the filesystem </thi');
      expect(out2, isEmpty); // Swallowed reasoning, held back partial close tag "</thi"

      // Chunk 3: Completes close tag and emits regular text
      final out3 = scrubber.feed('nk> World!');
      expect(out3, equals('World!'));
      expect(scrubber.flush(), isEmpty);
    });

    test('Should handle memory-context tags split across boundaries', () {
      final scrubber = ApexStreamingThoughtScrubber();

      final out1 = scrubber.feed('Start <memo');
      expect(out1, equals('Start '));

      final out2 = scrubber.feed('ry-context> Disposed summary </memory-con');
      expect(out2, isEmpty);

      final out3 = scrubber.feed('text> End');
      expect(out3, equals('End'));
      expect(scrubber.flush(), isEmpty);
    });

    test('Should flush held back content if it does not form a tag prefix', () {
      final scrubber = ApexStreamingThoughtScrubber();

      final out1 = scrubber.feed('Hello <abc');
      expect(out1, equals('Hello <abc')); // "<abc" is not a partial prefix of any registered tags, emitted instantly!
    });
  });

  group('ProviderHealthRegistry - Expanded Error Classification', () {
    test('Should classify content safety policy blocks correctly', () {
      final classification = ProviderHealthRegistry.classifyError(
        'gemini',
        'GoogleGenerativeAIException: Request violates our usage policies or content safety guidelines.',
      );

      expect(classification.type, equals(FailureType.policyBlocked));
      expect(classification.reason, equals('Content Policy Blocked'));
    });

    test('Should classify context length overflows correctly', () {
      final classification = ProviderHealthRegistry.classifyError(
        'groq',
        'BadRequestException: Maximum context length of 128000 tokens exceeded.',
      );

      expect(classification.type, equals(FailureType.contextOverflow));
      expect(classification.reason, equals('Context Length Exceeded'));
    });
  });
}
