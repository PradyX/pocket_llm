import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/core/services/model_storage_service.dart';
import 'package:pocket_llm/features/model_selection/data/gguf_reader.dart';
import 'package:pocket_llm/features/model_selection/domain/gguf_metadata.dart';
import 'package:pocket_llm/features/model_selection/domain/llm_model.dart';
import 'package:pocket_llm/features/model_selection/presentation/model_selection_controller.dart';

/// GGUF metadata inspector for one model (roadmap Phase 2.3).
///
/// Shows storage/source information plus the parsed GGUF key-values; when no
/// snapshot was stored at import time the file is parsed on demand.
class ModelDetailsPage extends ConsumerStatefulWidget {
  const ModelDetailsPage({super.key, required this.modelId});

  final String modelId;

  @override
  ConsumerState<ModelDetailsPage> createState() => _ModelDetailsPageState();
}

class _ModelDetailsPageState extends ConsumerState<ModelDetailsPage> {
  GgufMetadata? _metadata;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMetadata());
  }

  LlmModel? _findModel() {
    for (final model in ref.read(modelSelectionControllerProvider).models) {
      if (model.id == widget.modelId) return model;
    }
    return null;
  }

  Future<void> _loadMetadata() async {
    final model = _findModel();
    if (model == null) {
      setState(() => _error = 'Model not found.');
      return;
    }
    final snapshot = model.ggufMetadata;
    if (snapshot != null) {
      setState(() => _metadata = snapshot);
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final path = await ModelStorageService().resolveModelPath(model);
      if (path == null || path.trim().isEmpty) {
        throw const GgufFormatException('Model file location is unknown.');
      }
      final metadata = await const GgufReader().info(path);
      setState(() {
        _metadata = metadata;
        _loading = false;
      });
    } catch (error) {
      setState(() {
        _loading = false;
        _error = error is GgufFormatException
            ? error.message
            : 'Could not read GGUF metadata.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final model = _findModel();
    if (model == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Model details')),
        body: const Center(child: Text('Model not found.')),
      );
    }

    final metadata = _metadata;
    return Scaffold(
      appBar: AppBar(title: Text(model.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionHeader(context, 'Model'),
          _row(context, 'Name', model.name),
          _row(context, 'Source', _sourceLabel(model)),
          _row(context, 'Parameter size', model.parameterSize),
          _row(
            context,
            'Storage',
            model.isExternal
                ? (model.externalPath ?? 'Unknown')
                : (model.localFileName ?? 'Managed file'),
          ),
          if (model.mmprojLocalFileName != null)
            _row(context, 'Vision projector', model.mmprojLocalFileName!),
          if (model.externalMmprojPath != null)
            _row(context, 'Projector path', model.externalMmprojPath!),
          _row(context, 'Prompt format', model.promptFormatId),
          _row(
            context,
            'Capabilities',
            model.capabilities.isEmpty
                ? 'None'
                : model.capabilities.map((c) => c.label).join(', '),
          ),
          _row(context, 'Description', model.description),
          if (model.downloadUrl != null)
            _row(context, 'Download URL', model.downloadUrl!),
          const SizedBox(height: 14),
          _sectionHeader(context, 'GGUF metadata'),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_error!, style: TextStyle(color: colorScheme.error)),
            ),
          if (metadata == null && !_loading && _error == null)
            Text(
              'Reading metadata...',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (metadata != null) ...[
            _row(context, 'Architecture', _or(metadata.architecture)),
            _row(context, 'Model name', _or(metadata.name)),
            _row(context, 'Quantization', metadata.quantization),
            _row(
              context,
              'Parameters',
              '${metadata.parameterSizeLabel} (${metadata.parameterCount})',
            ),
            _row(
              context,
              'Context length',
              metadata.contextLength?.toString() ?? 'Unknown',
            ),
            _row(
              context,
              'Embedding size',
              metadata.embeddingLength?.toString() ?? 'Unknown',
            ),
            _row(
              context,
              'Layers',
              metadata.blockCount?.toString() ?? 'Unknown',
            ),
            _row(
              context,
              'Tokenizer',
              '${_or(metadata.tokenizerModel ?? '')} · vocab '
                  '${metadata.vocabSize?.toString() ?? 'Unknown'}',
            ),
            _row(
              context,
              'Special tokens',
              'BOS ${metadata.bosTokenId ?? '—'} · '
                  'EOS ${metadata.eosTokenId ?? '—'} · '
                  'UNK ${metadata.unkTokenId ?? '—'}',
            ),
            _row(
              context,
              'Chat template',
              metadata.chatTemplate == null
                  ? 'Not present'
                  : 'Present (${metadata.chatTemplate!.length} chars)',
            ),
            _row(context, 'Tensors', '${metadata.tensorCount}'),
            _row(context, 'Metadata keys', '${metadata.kvCount}'),
            _row(context, 'File size', _formatBytes(metadata.fileSizeBytes)),
            _row(context, 'GGUF version', '${metadata.version}'),
            _row(
              context,
              'Vision encoder',
              metadata.hasVisionEncoder ? 'Yes' : 'No',
            ),
            if (metadata.projectorType != null)
              _row(context, 'Projector type', metadata.projectorType!),
            if (metadata.tokenizerMergesCount > 0)
              _row(
                context,
                'Tokenizer merges',
                '${metadata.tokenizerMergesCount}',
              ),
          ],
        ],
      ),
    );
  }

  String _or(String value) => value.isEmpty ? 'Unknown' : value;

  String _sourceLabel(LlmModel model) {
    final source = model.effectiveSource;
    if (source != ModelSource.imported) return source.label;
    return model.isExternal
        ? '${source.label} (kept in place)'
        : '${source.label} (copied into app)';
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: Theme.of(context).textTheme.labelMedium),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
