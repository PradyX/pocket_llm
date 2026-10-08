import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_llm/features/model_selection/domain/gguf_metadata.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';

void main() {
  GgufMetadata metadata({String? template}) => GgufMetadata(
    architecture: 'llama',
    name: 'test',
    version: 3,
    kvCount: 20,
    tensorCount: 100,
    fileSizeBytes: 1024,
    parameterCount: 1000000,
    quantization: 'Q4_K_M',
    chatTemplate: template,
  );

  LlmModel model({
    List<ModelCapability> capabilities = const [],
    String? template,
  }) => LlmModel(
    id: 'model-1',
    name: 'Test model',
    parameterSize: '1B',
    description: 'a model',
    capabilities: capabilities,
    promptFormatId: 'chatml',
    ggufMetadata: template == null ? null : metadata(template: template),
  );

  group('chat template tool protocol', () {
    test('is read from the template the model ships with', () {
      for (final template in [
        '{%- if tools %}{{- "\\n\\n# Tools" }}{%- endif %}', // Hermes/Qwen
        '{{ messages }}{{ "<tool_call>" }}', // Qwen3
        '{{ bos_token }}<|python_tag|>', // Llama 3.1+
        '[AVAILABLE_TOOLS] {{ tools }}', // Mistral
        '{% if tools %}{{ tool_choice }}{% endif %}',
      ]) {
        expect(
          metadata(template: template).supportsToolCalling,
          isTrue,
          reason: template,
        );
      }
    });

    test('is false when the template has no tool protocol', () {
      for (final template in [
        null,
        '',
        '{% for message in messages %}{{ message["role"] }}: '
            '{{ message["content"] }}{% endfor %}',
      ]) {
        expect(
          metadata(template: template).supportsToolCalling,
          isFalse,
          reason: '$template',
        );
      }
    });
  });

  group('LlmModel.supportsToolCalling', () {
    test('trusts the catalog capability', () {
      expect(
        model(capabilities: const [ModelCapability.tools]).supportsToolCalling,
        isTrue,
      );
    });

    test('trusts the installed model’s own template', () {
      expect(
        model(
          template: '{%- if tools %}{{ tools }}{%- endif %}',
        ).supportsToolCalling,
        isTrue,
      );
    });

    test('is false when neither the catalog nor the template says so', () {
      expect(model().supportsToolCalling, isFalse);
      expect(model(template: '{{ messages }}').supportsToolCalling, isFalse);
      // A vision model is not a tool model: capabilities are independent.
      expect(
        model(
          capabilities: const [ModelCapability.vision],
          template: '{{ messages }}',
        ).supportsToolCalling,
        isFalse,
      );
    });
  });
}
