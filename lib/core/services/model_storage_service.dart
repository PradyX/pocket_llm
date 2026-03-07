import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class DownloadMetadata {
  final int totalSize;
  final List<ChunkState> chunks;

  DownloadMetadata({required this.totalSize, required this.chunks});

  Map<String, dynamic> toJson() => {
    'totalSize': totalSize,
    'chunks': chunks.map((c) => c.toJson()).toList(),
  };

  factory DownloadMetadata.fromJson(Map<String, dynamic> json) =>
      DownloadMetadata(
        totalSize: json['totalSize'],
        chunks: (json['chunks'] as List)
            .map((c) => ChunkState.fromJson(c))
            .toList(),
      );
}

class ChunkState {
  final int start;
  final int end;
  int received;
  bool isFinished;

  ChunkState({
    required this.start,
    required this.end,
    this.received = 0,
    this.isFinished = false,
  });

  Map<String, dynamic> toJson() => {
    'start': start,
    'end': end,
    'received': received,
    'isFinished': isFinished,
  };

  factory ChunkState.fromJson(Map<String, dynamic> json) => ChunkState(
    start: json['start'],
    end: json['end'],
    received: json['received'],
    isFinished: json['isFinished'],
  );
}

class ModelStorageService {
  final Dio _dio = Dio(
    BaseOptions(
      followRedirects: true,
      headers: {'User-Agent': 'PocketLLM/1.0', 'Accept': '*/*'},
    ),
  );

  Future<String> getModelDir() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final modelDir = Directory(p.join(appDocDir.path, 'models'));
    if (!modelDir.existsSync()) {
      modelDir.createSync(recursive: true);
    }
    return modelDir.path;
  }

  Future<bool> isModelDownloaded(String fileName) async {
    final dir = await getModelDir();
    final file = File(p.join(dir, fileName));
    if (!file.existsSync()) return false;

    // Presence of metadata means chunked download is incomplete/resumable.
    final metadataFile = File('${file.path}.json');
    if (metadataFile.existsSync()) return false;

    // Validate GGUF magic bytes to avoid marking HTML/error files as models.
    if (file.lengthSync() < 4) return false;
    final raf = file.openSync(mode: FileMode.read);
    try {
      final magic = raf.readSync(4);
      if (magic.length != 4 ||
          magic[0] != 0x47 ||
          magic[1] != 0x47 ||
          magic[2] != 0x55 ||
          magic[3] != 0x46) {
        return false;
      }
    } finally {
      raf.closeSync();
    }

    return true;
  }

  Future<int> getLocalFileSize(String fileName) async {
    final dir = await getModelDir();
    final file = File(p.join(dir, fileName));
    if (!file.existsSync()) return 0;
    return file.lengthSync();
  }

  Future<int?> getRemoteFileSize(String url, {CancelToken? cancelToken}) async {
    try {
      final headRes = await _dio.head(
        url,
        cancelToken: cancelToken,
        options: Options(validateStatus: (status) => (status ?? 500) < 500),
      );
      if ((headRes.statusCode ?? 500) < 400) {
        final contentLength = int.tryParse(
          headRes.headers.value('content-length') ?? '',
        );
        if (contentLength != null && contentLength > 0) return contentLength;
      }
    } on DioException {
      // Fall through to range probe.
    }

    try {
      final probe = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'range': 'bytes=0-0'},
          validateStatus: (status) => (status ?? 500) < 500,
        ),
        cancelToken: cancelToken,
      );
      try {
        final contentRange = probe.headers.value('content-range');
        if (contentRange != null) {
          final match = RegExp(
            r'bytes\s+\d+-\d+/(\d+)',
          ).firstMatch(contentRange);
          final total = int.tryParse(match?.group(1) ?? '');
          if (total != null && total > 0) return total;
        }

        final contentLength = int.tryParse(
          probe.headers.value('content-length') ?? '',
        );
        if (contentLength != null && contentLength > 0) {
          // 200 can be full body length; 206 may only report ranged bytes.
          if ((probe.statusCode ?? 0) == 200) return contentLength;
        }
      } finally {
        await probe.data?.stream.drain<void>();
      }
    } on DioException {
      // Ignore, unknown size.
    }

    return null;
  }

  /// Downloads a model using parallel chunked streams with resumption support.
  Future<void> downloadModel(
    String url,
    String fileName, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await getModelDir();
    final savePath = p.join(dir, fileName);
    final metadataPath = '$savePath.json';
    final int chunkCount = 5;

    // 1. Get/Create Metadata
    DownloadMetadata? metadata;
    final metadataFile = File(metadataPath);

    if (await metadataFile.exists()) {
      try {
        final content = await metadataFile.readAsString();
        metadata = DownloadMetadata.fromJson(jsonDecode(content));
      } catch (e) {
        // Corrupt metadata, restart
        await metadataFile.delete();
      }
    }

    if (metadata == null) {
      int totalSize = -1;
      try {
        final headRes = await _dio.head(
          url,
          cancelToken: cancelToken,
          options: Options(validateStatus: (status) => (status ?? 500) < 500),
        );
        if ((headRes.statusCode ?? 500) < 400) {
          totalSize =
              int.tryParse(headRes.headers.value('content-length') ?? '') ?? -1;
        }
      } on DioException {
        // Some hosts reject HEAD for public files; fallback to regular download.
      }

      if (totalSize <= 0) {
        await _downloadSingleStream(
          url: url,
          savePath: savePath,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );
        return;
      }

      final chunkSize = (totalSize / chunkCount).ceil();
      final chunks = List.generate(chunkCount, (i) {
        final start = i * chunkSize;
        final end = (i + 1) * chunkSize - 1;
        return ChunkState(
          start: start,
          end: end > totalSize - 1 ? totalSize - 1 : end,
        );
      });

      metadata = DownloadMetadata(totalSize: totalSize, chunks: chunks);

      // Save initial metadata
      await metadataFile.writeAsString(jsonEncode(metadata.toJson()));

      // Prepare target file
      final file = File(savePath);
      final raf = await file.open(mode: FileMode.write);
      await raf.truncate(totalSize);
      await raf.close();
    }

    // 2. Open shared handle
    final file = File(savePath);
    final raf = await file.open(mode: FileMode.append);
    var rafClosed = false;

    // 3. Parallel Downloads with Resumption
    final List<Future<void>> chunkFutures = [];
    final totalSize = metadata.totalSize;

    // Simple async lock to synchronize file writes
    Future<void> lock = Future.value();
    Future<void> synchronizedWrite(int position, List<int> data) async {
      final currentLock = lock;
      final completer = Completer<void>();
      lock = completer.future;
      await currentLock;
      try {
        await raf.setPosition(position);
        await raf.writeFrom(data);
      } finally {
        completer.complete();
      }
    }

    // Timer to persist metadata periodically
    Timer? metadataTimer;
    metadataTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (metadata != null) {
        await metadataFile.writeAsString(jsonEncode(metadata.toJson()));
      }
    });

    for (int i = 0; i < metadata.chunks.length; i++) {
      final chunk = metadata.chunks[i];
      if (chunk.isFinished) continue;

      chunkFutures.add(
        _downloadChunk(
          url: url,
          start: chunk.start + chunk.received,
          end: chunk.end,
          cancelToken: cancelToken,
          onChunkData: (data, totalReceivedInChunk) async {
            await synchronizedWrite(chunk.start + chunk.received, data);
            chunk.received += data.length;
            if (chunk.start + chunk.received > chunk.end) {
              chunk.isFinished = true;
            }

            final totalReceived = metadata!.chunks.fold(
              0,
              (sum, c) => sum + c.received,
            );
            onProgress?.call(totalReceived, totalSize);
          },
        ),
      );
    }

    try {
      await Future.wait(chunkFutures);
      // Clean up metadata on success
      metadataTimer.cancel();
      if (await metadataFile.exists()) {
        await metadataFile.delete();
      }
    } catch (e) {
      metadataTimer.cancel();
      if (_shouldFallbackToSingleStream(e)) {
        await raf.close();
        rafClosed = true;
        if (await metadataFile.exists()) {
          await metadataFile.delete();
        }
        if (await file.exists()) {
          await file.delete();
        }
        await _downloadSingleStream(
          url: url,
          savePath: savePath,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );
        return;
      }
      rethrow;
    } finally {
      if (!rafClosed) {
        await raf.close();
      }
    }
  }

  Future<void> _downloadChunk({
    required String url,
    required int start,
    required int end,
    required Future<void> Function(List<int> data, int totalReceivedInChunk)
    onChunkData,
    CancelToken? cancelToken,
  }) async {
    // If range is invalid (already finished), skip
    if (start > end) return;

    final Response<ResponseBody> response = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: {'range': 'bytes=$start-$end'},
        validateStatus: (status) => (status ?? 500) < 400,
      ),
      cancelToken: cancelToken,
    );

    // Host ignored range request for non-zero offset; chunk strategy is invalid.
    if ((response.statusCode ?? 500) == 200 && start > 0) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        error: 'Range not supported for chunked download.',
      );
    }

    int receivedInSession = 0;
    await for (final chunk in response.data!.stream) {
      receivedInSession += chunk.length;
      await onChunkData(chunk, receivedInSession);
    }
  }

  Future<void> deleteModel(String fileName) async {
    final dir = await getModelDir();
    final file = File(p.join(dir, fileName));
    if (file.existsSync()) {
      await file.delete();
    }
    // Also delete any progress metadata if present
    final metadataFile = File('${file.path}.json');
    if (metadataFile.existsSync()) {
      await metadataFile.delete();
    }
  }

  Future<String> getLocalFilePath(String fileName) async {
    final dir = await getModelDir();
    return p.join(dir, fileName);
  }

  Future<void> _downloadSingleStream({
    required String url,
    required String savePath,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    await _dio.download(
      url,
      savePath,
      onReceiveProgress: onProgress,
      cancelToken: cancelToken,
      deleteOnError: true,
      options: Options(validateStatus: (status) => (status ?? 500) < 400),
    );
  }

  bool _shouldFallbackToSingleStream(Object error) {
    if (error is! DioException) return false;
    final status = error.response?.statusCode;
    if (status == 401 || status == 403 || status == 405 || status == 416) {
      return true;
    }
    // Range-not-supported path can come through as badResponse with 200.
    return error.type == DioExceptionType.badResponse &&
        (status == null || status == 200);
  }
}
