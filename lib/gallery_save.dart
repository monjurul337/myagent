// v169 — "Save to Gallery": copies a finished animation MP4 into the
// phone's public Movies/Zedge Studio folder through the native
// MediaStore bridge (MainActivity, channel com.geminihd.studio/media),
// so the Gallery / Photos app lists it. Android only.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class GallerySave {
  static const MethodChannel _channel =
      MethodChannel('com.geminihd.studio/media');

  static bool get supported {
    try {
      return !kIsWeb && Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// Returns true when the file is now in the Gallery; throws a
  /// readable message on failure.
  static Future<bool> saveVideo(String path, String name) async {
    try {
      return await _channel
              .invokeMethod<bool>('saveVideo', {'path': path, 'name': name}) ??
          false;
    } on PlatformException catch (e) {
      throw e.message ?? e.code;
    }
  }
}
