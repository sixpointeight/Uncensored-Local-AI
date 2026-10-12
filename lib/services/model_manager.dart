import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../models/ai_model_info.dart';
import '../models/download_state.dart';
import 'wakelock_service.dart';

/// Manages model catalog, downloads, and local file discovery.
class ModelManager extends GetxService {
  final catalog = <AiModelInfo>[].obs;
  final downloadedModels = <String>[].obs; // filenames on-disk (list for reactivity)
  
  // ── Download tracking (single reactive object) ─────────────
  final activeDownloads = <String, DownloadState>{}.obs;
  final tick = 0.obs; // force UI refresh counter

  http.Client? _httpClient;
  late String _modelsDir;

  Future<ModelManager> init() async {
    _modelsDir = await _getModelsDir();
    await _loadCatalog();
    await scanDownloaded();
    return this;
  }

  /// Resolve models directory.
  Future<String> _getModelsDir() async {
    // Only check USB path on desktop platforms
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      try {
        final execDir = Platform.resolvedExecutable;
        final usbShared = p.normalize(p.join(p.dirname(p.dirname(execDir)), 'Shared', 'models'));
        if (await Directory(usbShared).exists()) {
          return usbShared;
        }
      } catch (_) {
        // Ignore errors resolving executable path
      }
    }

    // Fall back to app documents
    final appDir = await getApplicationDocumentsDirectory();
    final modelsDir = p.normalize(p.join(appDir.path, 'PortableAI', 'models'));
    await Directory(modelsDir).create(recursive: true);
    return modelsDir;
  }

  String get modelsDir => _modelsDir;

  /// Force all Obx listeners to rebuild.
  void _notifyUI() {
    tick.value++;
  }

  /// Load the embedded model catalog from assets + persisted custom models.
  Future<void> _loadCatalog() async {
    try {
      final jsonStr = await rootBundle.loadString('assets/models_catalog.json');
      final list = jsonDecode(jsonStr) as List;
      catalog.value =
          list.map((j) => AiModelInfo.fromJson(j as Map<String, dynamic>)).toList();
    } catch (e) {
      // Catalog couldn't load — will be empty
    }

    // Load persisted custom models
    try {
      final box = Hive.box('models_meta');
      final customList = box.get('custom_models', defaultValue: <dynamic>[]) as List;
      for (final raw in customList) {
        final model = AiModelInfo.fromJson(Map<String, dynamic>.from(raw as Map));
        // Don't add duplicates
        if (!catalog.any((m) => m.id == model.id)) {
          catalog.add(model);
        }
      }
    } catch (_) {}
  }

  /// Scan the models directory for downloaded .gguf files.
  Future<void> scanDownloaded() async {
    final dir = Directory(_modelsDir);
    if (!await dir.exists()) return;

    final files = await dir
        .list()
        .where((f) => f is File && f.path.toLowerCase().endsWith('.gguf'))
        .map((f) => p.basename(f.path))
        .toList();

    downloadedModels.value = files;
  }

  String getModelPath(AiModelInfo model) => p.normalize(p.join(_modelsDir, model.filename));
  String getModelPathByFilename(String filename) => p.normalize(p.join(_modelsDir, filename));
  bool isModelDownloaded(AiModelInfo model) => downloadedModels.contains(model.filename);

  /// Is this model currently downloading?
  bool isDownloading(String filename) {
    return activeDownloads.containsKey(filename) &&
        activeDownloads[filename]!.isActive;
  }

  /// Get the download state for a model (or null).
  DownloadState? getDownloadState(String filename) {
    return activeDownloads[filename];
  }

  /// Download a model with real-time speed tracking.
  /// Enables wake lock + foreground service to keep download alive.
  Future<void> downloadModel(AiModelInfo model) async {
    if (isDownloading(model.filename)) return;

    // Enable wake lock + foreground service for download (fire and forget so UI updates instantly)
    WakelockService? wakelockService;
    try {
      wakelockService = Get.find<WakelockService>();
      wakelockService.enableForDownload(modelName: model.name);
    } catch (e) {
      debugPrint('WakelockService not available: $e');
    }

    // Initialize download state instantly
    activeDownloads[model.filename] = DownloadState(
      filename: model.filename,
      totalBytes: model.sizeGb * 1024 * 1024 * 1024,
    );
    _notifyUI();

    final filePath = getModelPath(model);
    final partFile = File('$filePath.part');

    try {
      _httpClient = http.Client();
      final request = http.Request('GET', Uri.parse(model.url));

      // Support resume
      int existingBytes = 0;
      if (await partFile.exists()) {
        existingBytes = await partFile.length();
        request.headers['Range'] = 'bytes=$existingBytes-';
      }

      final response = await _httpClient!.send(request);
      final contentLength = response.contentLength ?? 0;
      final totalBytes = (existingBytes + contentLength).toDouble();

      // Update total from actual HTTP response
      final state = activeDownloads[model.filename]!;
      state.totalBytes = totalBytes > 0 ? totalBytes : state.totalBytes;
      state.receivedBytes = existingBytes.toDouble();

      final sink = partFile.openWrite(
          mode: existingBytes > 0 ? FileMode.append : FileMode.write);

      int receivedBytes = existingBytes;
      final stopwatch = Stopwatch()..start();
      int lastSpeedCheck = 0;
      int lastSpeedBytes = existingBytes;

      await for (final chunk in response.stream) {
        // Check if cancelled
        if (state.isCancelled) break;

        sink.add(chunk);
        receivedBytes += chunk.length;
        state.receivedBytes = receivedBytes.toDouble();

        // Calculate speed every 500ms
        if (stopwatch.elapsedMilliseconds - lastSpeedCheck > 500) {
          final elapsed = (stopwatch.elapsedMilliseconds - lastSpeedCheck) / 1000;
          final bytesDelta = receivedBytes - lastSpeedBytes;
          state.speedBytesPerSec = bytesDelta / elapsed;
          lastSpeedCheck = stopwatch.elapsedMilliseconds;
          lastSpeedBytes = receivedBytes;
          _notifyUI(); // trigger rebuild

          // Update foreground notification with progress
          if (wakelockService != null && state.totalBytes > 0) {
            final progress = state.receivedBytes / state.totalBytes;
            final speedMb = (state.speedBytesPerSec / (1024 * 1024)).toStringAsFixed(1);
            wakelockService.updateDownloadProgress(
              modelName: model.name,
              progress: progress,
              speedText: '$speedMb MB/s',
            );
          }
        }
      }

      await sink.flush();
      await sink.close();

      if (!state.isCancelled) {
        // Rename .part to final
        await partFile.rename(filePath);
        if (!downloadedModels.contains(model.filename)) {
          downloadedModels.add(model.filename);
        }
      }

      state.isActive = false;
      activeDownloads.remove(model.filename);
      _notifyUI();
    } catch (e) {
      activeDownloads[model.filename]?.isActive = false;
      activeDownloads.remove(model.filename);
      _notifyUI();
      rethrow;
    } finally {
      _httpClient?.close();
      _httpClient = null;

      // Disable wake lock if no other downloads are active
      if (activeDownloads.isEmpty) {
        try {
          await wakelockService?.disable();
        } catch (_) {}
      }
    }
  }

  /// Cancel an active download.
  void cancelDownload(String filename) {
    if (activeDownloads.containsKey(filename)) {
      activeDownloads[filename]!.isCancelled = true;
      activeDownloads[filename]!.isActive = false;
    }
    _httpClient?.close();
    _httpClient = null;
    activeDownloads.remove(filename);
    _notifyUI();
  }

  /// Delete a downloaded model.
  Future<void> deleteModel(String filename) async {
    final file = File(p.join(_modelsDir, filename));
    if (await file.exists()) {
      await file.delete();
    }
    downloadedModels.remove(filename);
  }

  /// Move a model file from cache to the models directory (instant on most file systems).
  Future<void> moveModel(String sourcePath, String filename) async {
    final destPath = p.join(_modelsDir, filename);
    if (sourcePath == destPath) return;

    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) return;

    // Try to move the file instantly (rename)
    try {
      await sourceFile.rename(destPath);
    } catch (e) {
      // Fallback to copy if rename fails (e.g. across different partitions)
      await sourceFile.copy(destPath);
      await sourceFile.delete();
    }

    if (!downloadedModels.contains(filename)) {
      downloadedModels.add(filename);
    }
  }

  /// Import a model directly from a stream (useful to bypass FilePicker caching on Android/iOS).
  Future<void> importModelFromStream({
    required String filename,
    required Stream<List<int>> stream,
    required int totalBytes,
    Function(double)? onProgress,
    bool Function()? checkCancelled,
  }) async {
    final destPath = p.join(_modelsDir, filename);
    final destFile = File(destPath);
    
    final sink = destFile.openWrite();
    int copiedBytes = 0;
    bool wasCancelled = false;

    try {
      final mappedStream = stream.map((chunk) {
        if (checkCancelled?.call() == true) {
          throw const FormatException('CANCELLED');
        }
        copiedBytes += chunk.length;
        if (totalBytes > 0) {
          onProgress?.call(copiedBytes / totalBytes);
        }
        return chunk;
      });
      await sink.addStream(mappedStream);
    } on FormatException catch (e) {
      if (e.message == 'CANCELLED') {
        wasCancelled = true;
      } else {
        rethrow;
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (wasCancelled) {
      if (await destFile.exists()) {
        await destFile.delete();
      }
      return;
    }

    if (!downloadedModels.contains(filename)) {
      downloadedModels.add(filename);
    }
  }

  /// Import a model file from external path with progress tracking.
  Future<void> importModel(String sourcePath, {Function(double)? onProgress, bool Function()? checkCancelled}) async {
    final filename = p.basename(sourcePath);
    final destPath = p.join(_modelsDir, filename);

    if (sourcePath != destPath) {
      final sourceFile = File(sourcePath);
      final destFile = File(destPath);
      
      final totalBytes = await sourceFile.length();
      if (totalBytes == 0) return;

      final sourceStream = sourceFile.openRead();
      final sink = destFile.openWrite();

      int copiedBytes = 0;
      bool wasCancelled = false;

      try {
        final mappedStream = sourceStream.map((chunk) {
          if (checkCancelled?.call() == true) {
            throw const FormatException('CANCELLED');
          }
          copiedBytes += chunk.length;
          onProgress?.call(copiedBytes / totalBytes);
          return chunk;
        });
        await sink.addStream(mappedStream);
      } on FormatException catch (e) {
        if (e.message == 'CANCELLED') {
          wasCancelled = true;
        } else {
          rethrow;
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      if (wasCancelled) {
        if (await destFile.exists()) {
          await destFile.delete();
        }
        return;
      }
    }

    if (!downloadedModels.contains(filename)) {
      downloadedModels.add(filename);
    }
  }

  /// Add custom model to catalog and persist it.
  void addCustomModel(AiModelInfo model) {
    catalog.add(model);
    _persistCustomModels();
  }

  /// Remove a custom model from catalog and persistence.
  void removeCustomModel(String id) {
    catalog.removeWhere((m) => m.id == id);
    _persistCustomModels();
  }

  /// Save all custom models to Hive.
  void _persistCustomModels() {
    final box = Hive.box('models_meta');
    final customList = catalog
        .where((m) => m.isCustom)
        .map((m) => m.toJson())
        .toList();
    box.put('custom_models', customList);
  }

  @override
  void onClose() {
    _httpClient?.close();
    super.onClose();
  }
}
