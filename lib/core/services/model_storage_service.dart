import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class ModelStorageService {
  final Dio _dio = Dio();

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
    return file.existsSync();
  }

  Future<void> downloadModel(
    String url,
    String fileName, {
    void Function(int received, int total)? onProgress,
  }) async {
    final dir = await getModelDir();
    final savePath = p.join(dir, fileName);

    await _dio.download(url, savePath, onReceiveProgress: onProgress);
  }

  Future<void> deleteModel(String fileName) async {
    final dir = await getModelDir();
    final file = File(p.join(dir, fileName));
    if (file.existsSync()) {
      await file.delete();
    }
  }

  Future<String> getLocalFilePath(String fileName) async {
    final dir = await getModelDir();
    return p.join(dir, fileName);
  }
}
