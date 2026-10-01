import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_llm/core/services/attachment_image_service.dart';
import 'package:pocket_llm/storage/secure_storage.dart';

/// How attached images are prepared before they are stored with a message.
///
/// The defaults favour privacy and memory: a photo is downscaled to a size a
/// phone-class model can afford and re-encoded without EXIF/GPS. Turning both
/// switches off stores the picked files byte-for-byte.
class AttachmentSettingsState {
  const AttachmentSettingsState({
    this.optimizeImages = true,
    this.stripMetadata = true,
    this.maxImageEdge = AttachmentImageOptions.defaultMaxEdge,
  });

  /// Downscale to [maxImageEdge] and re-encode.
  final bool optimizeImages;

  /// Re-encode without metadata even when not downscaling.
  final bool stripMetadata;

  final int maxImageEdge;

  AttachmentImageOptions get imageOptions => AttachmentImageOptions(
    optimize: optimizeImages,
    stripMetadata: stripMetadata,
    maxEdge: maxImageEdge,
  ).normalized();

  /// True when the original bytes are attached untouched.
  bool get keepsOriginalImages => !optimizeImages && !stripMetadata;

  AttachmentSettingsState copyWith({
    bool? optimizeImages,
    bool? stripMetadata,
    int? maxImageEdge,
  }) {
    return AttachmentSettingsState(
      optimizeImages: optimizeImages ?? this.optimizeImages,
      stripMetadata: stripMetadata ?? this.stripMetadata,
      maxImageEdge: maxImageEdge ?? this.maxImageEdge,
    );
  }
}

final attachmentSettingsProvider =
    StateNotifierProvider<AttachmentSettingsNotifier, AttachmentSettingsState>(
      (ref) => AttachmentSettingsNotifier(),
    );

class AttachmentSettingsNotifier
    extends StateNotifier<AttachmentSettingsState> {
  static const _settingsKey = 'attachment_settings';

  AttachmentSettingsNotifier() : super(const AttachmentSettingsState()) {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final data = await SecureStorage.instance.read(_settingsKey);
      if (data == null) return;

      final optimize = data['optimizeImages'];
      final strip = data['stripMetadata'];
      final maxEdge = data['maxImageEdge'];

      state = state.copyWith(
        optimizeImages: optimize is bool ? optimize : null,
        stripMetadata: strip is bool ? strip : null,
        maxImageEdge: maxEdge is num
            ? maxEdge.toInt().clamp(
                AttachmentImageOptions.minMaxEdge,
                AttachmentImageOptions.maxMaxEdge,
              )
            : null,
      );
    } catch (_) {
      // Keep defaults if storage read fails.
    }
  }

  Future<void> setOptimizeImages(bool enabled) async {
    state = state.copyWith(optimizeImages: enabled);
    await _persist();
  }

  Future<void> setStripMetadata(bool enabled) async {
    state = state.copyWith(stripMetadata: enabled);
    await _persist();
  }

  Future<void> setMaxImageEdge(int value) async {
    state = state.copyWith(
      maxImageEdge: value.clamp(
        AttachmentImageOptions.minMaxEdge,
        AttachmentImageOptions.maxMaxEdge,
      ),
    );
    await _persist();
  }

  Future<void> _persist() async {
    await SecureStorage.instance.write(
      key: _settingsKey,
      value: {
        'optimizeImages': state.optimizeImages,
        'stripMetadata': state.stripMetadata,
        'maxImageEdge': state.maxImageEdge,
      },
    );
  }
}
