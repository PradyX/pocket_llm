import 'dart:typed_data';

import 'package:pocket_llm/features/model_selection/data/gguf_reader.dart';

/// Builds synthetic GGUF files so tests do not depend on real model downloads.
class GgufTestBuilder {
  GgufTestBuilder({required this.version});

  final int version;
  final BytesBuilder _bytes = BytesBuilder();
  final List<GgufTestTensor> _tensors = [];
  int _kvCount = 0;

  GgufTestBuilder string(String key, String value) {
    _payload(key, GgufReader.typeString, _stringBytes(value));
    return this;
  }

  GgufTestBuilder uint32(String key, int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    _payload(key, GgufReader.typeUint32, data.buffer.asUint8List());
    return this;
  }

  GgufTestBuilder uint64(String key, int value) {
    final data = ByteData(8)..setUint64(0, value, Endian.little);
    _payload(key, GgufReader.typeUint64, data.buffer.asUint8List());
    return this;
  }

  GgufTestBuilder boolean(String key, bool value) {
    _payload(key, GgufReader.typeBool, [value ? 1 : 0]);
    return this;
  }

  GgufTestBuilder stringArray(String key, List<String> values) {
    final payload = BytesBuilder()..add(le64(values.length));
    for (final value in values) {
      payload.add(_stringBytes(value));
    }
    _payload(key, GgufReader.typeArray, payload.toBytes());
    return this;
  }

  GgufTestBuilder tensors(List<GgufTestTensor> tensors) {
    _tensors.addAll(tensors);
    return this;
  }

  List<int> build() {
    final header = BytesBuilder()
      ..add([0x47, 0x47, 0x55, 0x46])
      ..add(le32(version));
    return [
      ...header.toBytes(),
      ...le64(_tensors.length),
      ...le64(_kvCount),
      ..._bytes.toBytes(),
      ..._tensorBytes(),
    ];
  }

  void _payload(String key, int type, List<int> payload) {
    _bytes
      ..add(_stringBytes(key))
      ..add(le32(type));
    if (type == GgufReader.typeArray) {
      _bytes.add(le32(GgufReader.typeString));
    }
    _bytes.add(payload);
    _kvCount++;
  }

  List<int> _tensorBytes() {
    final out = BytesBuilder();
    for (final tensor in _tensors) {
      out
        ..add(_stringBytes(tensor.name))
        ..add(le32(tensor.dims.length));
      for (final dim in tensor.dims) {
        out.add(le64(dim));
      }
      out
        ..add(le32(tensor.tensorType))
        ..add(le64(0));
    }
    return out.toBytes();
  }

  static List<int> _stringBytes(String value) {
    final units = value.codeUnits;
    return [...le64(units.length), ...units];
  }
}

class GgufTestTensor {
  const GgufTestTensor({
    required this.name,
    required this.dims,
    required this.tensorType,
  });

  final String name;
  final List<int> dims;
  final int tensorType;
}

List<int> le32(int value) {
  final data = ByteData(4)..setUint32(0, value, Endian.little);
  return data.buffer.asUint8List();
}

List<int> le64(int value) {
  final data = ByteData(8)..setUint64(0, value, Endian.little);
  return data.buffer.asUint8List();
}
