// v158 — cover frame for a finished animation video, sent to
// the panel as the queue record's thumbUrl so the panel shows a
// preview instead of an empty card (QueueItem.previewUrl returns
// thumbUrl for video types). Mirrors the panel's own video upload,
// which captures a cover frame and uploads it beside the MP4.
//
// The capture runs through the video_thumbnail plugin
// (MediaMetadataRetriever on Android). The plugin has NO Windows /
// macOS / web implementation, so on desktop this returns null
// without ever calling the channel and the video uploads without
// a cover. It never throws: any failure means "no cover", never
// "no upload" — the caller logs a Banglish note and carries on.
//
// Cover size (user order 2026-11-22: "Cover size kintu
// 1620x2880"): the frame is captured at the video's FULL native
// resolution — maxWidth/maxHeight stay 0, which the plugin
// documents (and its Android source confirms) means "same
// resolution as the original video", so a 1620x2880 clip yields
// a 1620x2880 cover. There is deliberately no size parameter on
// the capture seam, so no caller can downscale it by accident.
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:video_thumbnail/video_thumbnail.dart';

/// The capture seam: (video path, timeMs) -> JPEG bytes, or null
/// when no frame could be captured. Injected into StudioEngine
/// so tests can fake it (the real plugin needs a real video file
/// on a real Android device).
typedef VideoCoverCapture = Future<Uint8List?> Function(
  String videoPath, {
  int timeMs,
});

/// Captures one frame at [timeMs] into the video, at full native
/// resolution, as a JPEG. Returns null on desktop (no plugin
/// implementation there) and on any failure.
Future<Uint8List?> captureVideoCover(
  String videoPath, {
  int timeMs = 1000,
}) async {
  if (!Platform.isAndroid && !Platform.isIOS) return null;
  try {
    final bytes = await VideoThumbnail.thumbnailData(
      video: videoPath,
      imageFormat: ImageFormat.JPEG,
      // 0 = native resolution (1620x2880 for a 1620x2880 clip).
      // Never pass a maxWidth/maxHeight here.
      maxWidth: 0,
      maxHeight: 0,
      timeMs: timeMs,
      quality: 85,
    );
    if (bytes == null || bytes.isEmpty) return null;
    return bytes;
  } catch (_) {
    return null;
  }
}
