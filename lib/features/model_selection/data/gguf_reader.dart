import 'dart:io';
import 'dart:typed_data';

import 'package:pocket_llm/features/model_selection/domain/gguf_metadata.dart';

/// Thrown when a file cannot be interpreted as a GGUF model.
class GgufFormatException implements Exception {
  const GgufFormatException([this.message = 'Invalid GGUF file.']);

  final String message;

  @override
  String toString() => 'GgufFormatException: $message';
}

/// Thrown when the file ends before the GGUF headers could be fully read.
class GgufTruncatedException extends GgufFormatException {
  const GgufTruncatedException([
    super.message =
        'The file ended before the GGUF metadata could be read. '
        'The download may be incomplete or the file may be corrupt.',
  ]);
}

/// Thrown for files that do not carry the GGUF magic bytes.
class GgufNotAModelException extends GgufFormatException {
  const GgufNotAModelException([
    super.message =
        'The file is not a GGUF model (missing GGUF magic bytes). '
        'Select a .gguf file.',
  ]);
}

/// Reads GGUF metadata without loading model weights into memory.
///
/// The implementation follows the v2/v3 layout used by llama.cpp: a fixed
/// header, key-value pairs, then tensor information. Only the bytes needed
/// for those sections are read from disk, so even multi-gigabyte files are
/// inspected in seconds.
class GgufReader {
  const GgufReader();

  static const int supportedMinVersion = 2;
  static const int supportedMaxVersion = 3;

  static const int typeUint8 = 0;
  static const int typeInt8 = 1;
  static const int typeUint16 = 2;
  static const int typeInt16 = 3;
  static const int typeUint32 = 4;
  static const int typeInt32 = 5;
  static const int typeFloat32 = 6;
  static const int typeBool = 7;
  static const int typeString = 8;
  static const int typeArray = 9;
  static const int typeUint64 = 10;
  static const int typeInt64 = 11;
  static const int typeFloat64 = 12;

  /// Largest read issued in a single system call.
  static const int _readChunkBytes = 1024 * 1024;

  /// Largest string accepted while parsing headers.
  static const int _maxStringLength = 16 * 1024 * 1024;

  /// Largest array element count accepted.
  static const int _maxArrayElements = 1000000;

  /// Hard stop for header parsing so hostile inputs fail fast.
  static const int _maxFileScanBytes = 512 * 1024 * 1024;

  /// How many metadata values are interpreted as displayable fields.
  static const int metadataKvLimit = 64;

  /// Validates the file and reads full metadata (key-values plus tensor
  /// information, used to derive parameter count and quantization).
  Future<GgufMetadata> info(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw GgufFormatException('Model file not found: $path');
    }
    final fileSizeBytes = await file.length();
    if (fileSizeBytes < 24) {
      throw const GgufTruncatedException();
    }
    return readMetadata(path, fileSizeBytes: fileSizeBytes);
  }

  /// Reads metadata at [path]. Callers that already know the file size pass
  /// it through [fileSizeBytes] to avoid a second stat call.
  Future<GgufMetadata> readMetadata(
    String path, {
    required int fileSizeBytes,
  }) async {
    final raf = await File(path).open(mode: FileMode.read);
    try {
      final header = await _readHeader(raf);
      final outcome = await _readMetadataKvs(raf, header);
      final tensors = await _readTensorInfos(raf, outcome.position, header);
      return _interpretMetadata(
        header: header,
        fileSizeBytes: fileSizeBytes,
        scalars: outcome.scalars,
        stringValues: outcome.stringValues,
        vocabSize: outcome.vocabSize,
        mergesCount: outcome.mergesCount,
        tensors: tensors,
      );
    } finally {
      await raf.close();
    }
  }

  Future<_GgufHeader> _readHeader(RandomAccessFile raf) async {
    const magic = [0x47, 0x47, 0x55, 0x46];
    final magicBytes = await _readBytes(raf, 0, 4);
    for (var i = 0; i < magic.length; i++) {
      if (magicBytes[i] != magic[i]) {
        throw const GgufNotAModelException();
      }
    }

    final version = await _readUint32(raf, 4);
    if (version == 0 || version == 1) {
      throw const GgufFormatException(
        'GGUF v1 is no longer supported. Use a GGUF v2 or newer file.',
      );
    }
    if (version == 0xFFFFFFFF ||
        (version & 0x0000FFFF) == 0 ||
        version > supportedMaxVersion) {
      throw _unsupportedVersion(version);
    }

    final tensorCount = await _readUint64(raf, 8);
    final kvCount = await _readUint64(raf, 16);
    if (tensorCount > 1000000) {
      throw GgufFormatException(
        'GGUF file declares $tensorCount tensors, which is not plausible.',
      );
    }
    if (kvCount > 1000000) {
      throw GgufFormatException(
        'GGUF file declares $kvCount metadata pairs, '
        'which is not plausible.',
      );
    }

    return _GgufHeader(
      version: version,
      tensorCount: tensorCount,
      kvCount: kvCount,
    );
  }

  GgufFormatException _unsupportedVersion(int version) {
    if (version < supportedMinVersion) {
      return GgufFormatException(
        'Unsupported GGUF version $version. '
        'Only versions $supportedMinVersion and $supportedMaxVersion '
        'are supported.',
      );
    }
    return GgufFormatException(
      'This GGUF file uses version $version, newer than the supported '
      'version $supportedMaxVersion. Update Pocket LLM and try again.',
    );
  }

  void _validateArrayCount(String key, int count) {
    if (count < 0 || count > _maxArrayElements) {
      throw GgufFormatException(
        'GGUF metadata key "$key" declares $count array elements, '
        'which is not plausible.',
      );
    }
  }

  /// Advances past a numeric array without reading its payload.
  int _skipFixedArray(int position, String key, int elementType, int count) {
    final payloadBytes = count * _numericTypeSize(elementType);
    final next = position + payloadBytes;
    if (next < position || next > _maxFileScanBytes) {
      throw GgufFormatException(
        'GGUF metadata key "$key" points outside readable headers.',
      );
    }
    return next;
  }

  /// Walks a string array (headers plus payload) without decoding entries.
  Future<int> _walkStringArray(
    RandomAccessFile raf,
    int position,
    int count,
  ) async {
    var cursor = position;
    for (var i = 0; i < count; i++) {
      final length = await _readUint64(raf, cursor);
      cursor += 8;
      if (length < 0 || length > _maxStringLength) {
        throw GgufFormatException(
          'GGUF string array entry $i exceeds the supported length.',
        );
      }
      cursor += length;
      if (cursor > _maxFileScanBytes) {
        throw const GgufTruncatedException();
      }
    }
    return cursor;
  }

  Future<_KvParseOutcome> _readMetadataKvs(
    RandomAccessFile raf,
    _GgufHeader header,
  ) async {
    final scalars = <String, Object>{};
    final stringValues = <String, String>{};
    int? vocabSize;
    int? mergesCount;
    var position = 24;
    var storedCount = 0;

    for (var i = 0; i < header.kvCount; i++) {
      final exceedsLimit = storedCount >= metadataKvLimit;
      final keyOutcome = await _readString(raf, position);
      final key = keyOutcome.value;
      position = keyOutcome.position;
      if (key.isEmpty) {
        throw const GgufFormatException('GGUF metadata contains an empty key.');
      }

      final valueType = await _readUint32(raf, position);
      position += 4;

      if (valueType == typeArray) {
        final elementType = await _readUint32(raf, position);
        position += 4;
        if (elementType == typeArray) {
          throw GgufFormatException(
            'GGUF metadata key "$key" is a nested array, '
            'which is not supported.',
          );
        }
        final elementCount = await _readUint64(raf, position);
        position += 8;
        _validateArrayCount(key, elementCount);
        if (elementType == typeString) {
          position = await _walkStringArray(raf, position, elementCount);
        } else if (!_isNumericScalarType(elementType)) {
          throw GgufFormatException(
            'GGUF metadata key "$key" has unsupported array element '
            'type $elementType.',
          );
        } else {
          position = _skipFixedArray(position, key, elementType, elementCount);
        }
        if (key == 'tokenizer.ggml.tokens') {
          vocabSize = vocabSize == null || elementCount > vocabSize
              ? elementCount
              : vocabSize;
        } else if (key == 'tokenizer.ggml.merges') {
          mergesCount = mergesCount == null || elementCount > mergesCount
              ? elementCount
              : mergesCount;
        }
        if (!exceedsLimit) storedCount++;
      } else if (_isScalarValueType(valueType)) {
        final outcome = await _readScalarValue(raf, valueType, position);
        position = outcome.position;
        if (!exceedsLimit) {
          scalars[key] = outcome.value;
          if (outcome.value is String) {
            stringValues[key] = outcome.value as String;
          }
          storedCount++;
        }
      } else {
        throw GgufFormatException(
          'GGUF metadata key "$key" has unsupported value type $valueType.',
        );
      }
    }

    return _KvParseOutcome(
      scalars: scalars,
      stringValues: stringValues,
      vocabSize: vocabSize,
      mergesCount: mergesCount,
      position: position,
    );
  }

  Future<_ScalarOutcome> _readScalarValue(
    RandomAccessFile raf,
    int valueType,
    int position,
  ) async {
    switch (valueType) {
      case typeUint8:
        final bytes = await _readBytes(raf, position, 1);
        return _ScalarOutcome(bytes[0], position + 1);
      case typeInt8:
        final bytes = await _readBytes(raf, position, 1);
        final value = bytes[0] > 127 ? bytes[0] - 256 : bytes[0];
        return _ScalarOutcome(value, position + 1);
      case typeUint16:
        final bytes = await _readBytes(raf, position, 2);
        final view = ByteData.sublistView(bytes);
        return _ScalarOutcome(view.getUint16(0, Endian.little), position + 2);
      case typeInt16:
        final bytes = await _readBytes(raf, position, 2);
        final view = ByteData.sublistView(bytes);
        return _ScalarOutcome(view.getInt16(0, Endian.little), position + 2);
      case typeUint32:
        final bytes = await _readBytes(raf, position, 4);
        final view = ByteData.sublistView(bytes);
        return _ScalarOutcome(view.getUint32(0, Endian.little), position + 4);
      case typeInt32:
        final bytes = await _readBytes(raf, position, 4);
        final view = ByteData.sublistView(bytes);
        return _ScalarOutcome(view.getInt32(0, Endian.little), position + 4);
      case typeFloat32:
        final bytes = await _readBytes(raf, position, 4);
        final view = ByteData.sublistView(bytes);
        return _ScalarOutcome(view.getFloat32(0, Endian.little), position + 4);
      case typeBool:
        final bytes = await _readBytes(raf, position, 1);
        if (bytes[0] != 0 && bytes[0] != 1) {
          throw const GgufFormatException('Invalid GGUF boolean value.');
        }
        return _ScalarOutcome(bytes[0] == 1, position + 1);
      case typeString:
        final outcome = await _readString(raf, position);
        return _ScalarOutcome(outcome.value, outcome.position);
      case typeUint64:
        final bytes = await _readBytes(raf, position, 8);
        final view = ByteData.sublistView(bytes);
        return _ScalarOutcome(view.getUint64(0, Endian.little), position + 8);
      case typeInt64:
        final bytes = await _readBytes(raf, position, 8);
        final view = ByteData.sublistView(bytes);
        return _ScalarOutcome(view.getInt64(0, Endian.little), position + 8);
      default:
        final bytes = await _readBytes(raf, position, 8);
        final view = ByteData.sublistView(bytes);
        return _ScalarOutcome(view.getFloat64(0, Endian.little), position + 8);
    }
  }

  Future<_StringOutcome> _readString(RandomAccessFile raf, int position) async {
    final length = await _readUint64(raf, position);
    var cursor = position + 8;
    if (length < 0 || length > _maxStringLength) {
      throw const GgufFormatException('GGUF string is too long to read.');
    }
    if (length == 0) {
      return _StringOutcome('', cursor);
    }
    final bytes = await _readBytes(raf, cursor, length);
    cursor += length;
    if (cursor > _maxFileScanBytes) {
      throw const GgufTruncatedException();
    }
    try {
      return _StringOutcome(String.fromCharCodes(bytes), cursor);
    } catch (_) {
      throw const GgufFormatException('GGUF string is not valid text.');
    }
  }

  Future<Uint8List> _readBytes(
    RandomAccessFile raf,
    int position,
    int length,
  ) async {
    if (length <= 0 || position < 0) {
      throw const GgufTruncatedException();
    }
    if (position + length > _maxFileScanBytes) {
      throw const GgufTruncatedException();
    }
    final buffer = Uint8List(length);
    var filled = 0;
    while (filled < length) {
      final remaining = length - filled;
      final request = remaining > _readChunkBytes ? _readChunkBytes : remaining;
      await raf.setPosition(position + filled);
      final chunk = await raf.read(request);
      if (chunk.isEmpty) {
        throw const GgufTruncatedException();
      }
      buffer.setRange(filled, filled + chunk.length, chunk);
      filled += chunk.length;
    }
    return buffer;
  }

  Future<int> _readUint32(RandomAccessFile raf, int position) async {
    final bytes = await _readBytes(raf, position, 4);
    return ByteData.sublistView(bytes).getUint32(0, Endian.little);
  }

  Future<int> _readUint64(RandomAccessFile raf, int position) async {
    final bytes = await _readBytes(raf, position, 8);
    return ByteData.sublistView(bytes).getUint64(0, Endian.little);
  }

  bool _isScalarValueType(int type) {
    return type == typeUint8 ||
        type == typeInt8 ||
        type == typeUint16 ||
        type == typeInt16 ||
        type == typeUint32 ||
        type == typeInt32 ||
        type == typeFloat32 ||
        type == typeBool ||
        type == typeString ||
        type == typeUint64 ||
        type == typeInt64 ||
        type == typeFloat64;
  }

  bool _isNumericScalarType(int type) {
    return type == typeUint8 ||
        type == typeInt8 ||
        type == typeUint16 ||
        type == typeInt16 ||
        type == typeUint32 ||
        type == typeInt32 ||
        type == typeFloat32 ||
        type == typeBool ||
        type == typeUint64 ||
        type == typeInt64 ||
        type == typeFloat64;
  }

  int _numericTypeSize(int type) {
    switch (type) {
      case typeUint8:
      case typeInt8:
      case typeBool:
        return 1;
      case typeUint16:
      case typeInt16:
        return 2;
      case typeUint32:
      case typeInt32:
      case typeFloat32:
        return 4;
      case typeUint64:
      case typeInt64:
      case typeFloat64:
        return 8;
      default:
        return 0;
    }
  }

  Future<List<_RawTensorInfo>> _readTensorInfos(
    RandomAccessFile raf,
    int position,
    _GgufHeader header,
  ) async {
    final tensors = <_RawTensorInfo>[];
    var cursor = position;
    for (var i = 0; i < header.tensorCount; i++) {
      final nameOutcome = await _readString(raf, cursor);
      cursor = nameOutcome.position;

      final dimCount = await _readUint32(raf, cursor);
      cursor += 4;
      if (dimCount < 0 || dimCount > 4) {
        throw GgufFormatException(
          'GGUF tensor "$nameOutcome.value" declares $dimCount dimensions.',
        );
      }
      final dims = <int>[];
      for (var d = 0; d < dimCount; d++) {
        final dim = await _readUint64(raf, cursor);
        cursor += 8;
        if (dim < 0) {
          throw GgufFormatException(
            'GGUF tensor "${nameOutcome.value}" has a negative dimension.',
          );
        }
        dims.add(dim);
      }

      final tensorType = await _readUint32(raf, cursor);
      cursor += 4;
      // The tensor data offset is not needed for metadata inspection.
      await _readUint64(raf, cursor);
      cursor += 8;

      tensors.add(
        _RawTensorInfo(
          name: nameOutcome.value,
          dims: dims,
          tensorType: tensorType,
        ),
      );
      if (cursor > _maxFileScanBytes) {
        throw const GgufTruncatedException();
      }
    }
    return tensors;
  }

  GgufMetadata _interpretMetadata({
    required _GgufHeader header,
    required int fileSizeBytes,
    required Map<String, Object> scalars,
    required Map<String, String> stringValues,
    required int? vocabSize,
    required int? mergesCount,
    required List<_RawTensorInfo> tensors,
  }) {
    final architecture = _scalarString(scalars, 'general.architecture');
    final name = _scalarString(scalars, 'general.name');

    final contextLength = architecture.isEmpty
        ? null
        : _scalarInt(scalars, '$architecture.context_length');
    final embeddingLength = architecture.isEmpty
        ? null
        : _scalarInt(scalars, '$architecture.embedding_length');
    final blockCount = architecture.isEmpty
        ? null
        : _scalarInt(scalars, '$architecture.block_count');

    final numericScalars = <String, num>{};
    final stringExtras = <String, String>{};
    for (final entry in scalars.entries) {
      final value = entry.value;
      if (value is num) {
        numericScalars[entry.key] = value;
      } else if (value is String) {
        stringExtras[entry.key] = value;
      }
    }

    return GgufMetadata(
      architecture: architecture,
      name: name,
      version: header.version,
      kvCount: header.kvCount,
      tensorCount: header.tensorCount,
      fileSizeBytes: fileSizeBytes,
      parameterCount: _parameterCount(tensors),
      quantization: _quantizationLabel(
        scalars['general.quantization_version'],
        tensors,
      ),
      contextLength: contextLength,
      embeddingLength: embeddingLength,
      blockCount: blockCount,
      vocabSize: vocabSize ?? _scalarInt(scalars, 'tokenizer.ggml.vocab_size'),
      tokenizerModel: _optionalString(
        stringValues['tokenizer.ggml.model'] ??
            stringValues['tokenizer.ggml.pre'],
      ),
      chatTemplate: _optionalString(stringValues['tokenizer.chat_template']),
      bosTokenId: _scalarInt(scalars, 'tokenizer.ggml.bos_token_id'),
      eosTokenId: _scalarInt(scalars, 'tokenizer.ggml.eos_token_id'),
      unkTokenId: _scalarInt(scalars, 'tokenizer.ggml.unknown_token_id'),
      tokenizerMergesCount: mergesCount ?? 0,
      hasVisionEncoder:
          _scalarBool(scalars, 'clip.has_vision_encoder') ?? false,
      projectorType: _optionalString(
        stringValues['clip.projector_type'] ??
            stringValues['clip.vision.projection_type'],
      ),
      numericScalars: numericScalars,
      stringExtras: stringExtras,
    );
  }

  int _parameterCount(List<_RawTensorInfo> tensors) {
    var totalElements = BigInt.zero;
    for (final tensor in tensors) {
      var elements = BigInt.one;
      for (final dim in tensor.dims) {
        elements *= BigInt.from(dim);
      }
      totalElements += elements;
    }
    final maxInt = BigInt.from(1) << 62;
    if (totalElements > maxInt) {
      return maxInt.toInt();
    }
    return totalElements.toInt();
  }

  String _quantizationLabel(
    Object? quantizationVersion,
    List<_RawTensorInfo> tensors,
  ) {
    final counts = <int, int>{};
    for (final tensor in tensors) {
      if (tensor.dims.isEmpty) continue;
      counts[tensor.tensorType] = (counts[tensor.tensorType] ?? 0) + 1;
    }
    if (counts.isEmpty) {
      return quantizationVersion is num
          ? 'Q${quantizationVersion.toInt()}'
          : 'Unknown';
    }

    var dominantType = counts.entries.first.key;
    var dominantCount = counts.entries.first.value;
    for (final entry in counts.entries) {
      if (entry.value > dominantCount) {
        dominantType = entry.key;
        dominantCount = entry.value;
      }
    }
    final tensorLabel = _ggmlTypeLabel(dominantType);
    if (tensorLabel != null) return tensorLabel;
    return quantizationVersion is num
        ? 'Q${quantizationVersion.toInt()}'
        : 'Type $dominantType';
  }

  String? _optionalString(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String _scalarString(Map<String, Object> scalars, String key) {
    final value = scalars[key];
    return value is String ? value : '';
  }

  int? _scalarInt(Map<String, Object> scalars, String key) {
    final value = scalars[key];
    if (value is int) return value;
    if (value is double) return value.round();
    return null;
  }

  bool? _scalarBool(Map<String, Object> scalars, String key) {
    final value = scalars[key];
    if (value is bool) return value;
    if (value is num) return value != 0;
    return null;
  }

  static const _ggmlTypeLabels = <int, String>{
    0: 'F32',
    1: 'F16',
    2: 'Q4_0',
    3: 'Q4_1',
    6: 'Q5_0',
    7: 'Q5_1',
    8: 'Q8_0',
    9: 'Q8_1',
    10: 'Q2_K',
    11: 'Q3_K',
    12: 'Q4_K',
    13: 'Q5_K',
    14: 'Q6_K',
    15: 'Q8_K',
    16: 'IQ2_XXS',
    17: 'IQ2_XS',
    18: 'IQ3_XXS',
    19: 'IQ1_S',
    20: 'IQ4_NL',
    21: 'IQ3_S',
    22: 'IQ2_S',
    23: 'IQ4_XS',
    24: 'I8',
    25: 'I16',
    26: 'I32',
    27: 'I64',
    28: 'F64',
    29: 'IQ1_M',
    30: 'BF16',
    34: 'TQ1_0',
    35: 'TQ2_0',
    39: 'MXFP4',
    40: 'NVFP4',
    41: 'Q1_0',
    42: 'Q2_0',
  };

  String? _ggmlTypeLabel(int type) => _ggmlTypeLabels[type];
}

class _GgufHeader {
  const _GgufHeader({
    required this.version,
    required this.tensorCount,
    required this.kvCount,
  });

  final int version;
  final int tensorCount;
  final int kvCount;
}

class _KvParseOutcome {
  const _KvParseOutcome({
    required this.scalars,
    required this.stringValues,
    required this.vocabSize,
    required this.mergesCount,
    required this.position,
  });

  final Map<String, Object> scalars;
  final Map<String, String> stringValues;
  final int? vocabSize;
  final int? mergesCount;
  final int position;
}

class _ScalarOutcome {
  const _ScalarOutcome(this.value, this.position);

  final Object value;
  final int position;
}

class _StringOutcome {
  const _StringOutcome(this.value, this.position);

  final String value;
  final int position;
}

class _RawTensorInfo {
  const _RawTensorInfo({
    required this.name,
    required this.dims,
    required this.tensorType,
  });

  final String name;
  final List<int> dims;
  final int tensorType;
}
