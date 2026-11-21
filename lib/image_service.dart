// Image preparation + Cloudinary AI upscale.
// Dart port of the extension's resizeImageToJpg100 /
// upscaleResizeAndSaveBlob / upscaleViaCloudinary, using the pure-Dart
// `image` package so Android (Kotlin) and Windows behave identically.
import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'models.dart';
import 'studio_constants.dart';

class PreparedImage {
  final Uint8List bytes;
  final int width;
  final int height;
  final int qualityPct;
  final bool upscaledViaCloudinary;
  final String? hdUrl;
  const PreparedImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.qualityPct,
    this.upscaledViaCloudinary = false,
    this.hdUrl,
  });
  double get megapixels => (width * height) / 1000000;
  bool get zedgeCompliant =>
      width >= kMinZedgeWidth &&
      height >= kMinZedgeHeight &&
      width * height < kMaxZedgeMegapixels &&
      bytes.length <= kMaxZedgeBytes;
}

class CloudinaryConfig {
  String cloudName;
  String apiKey;
  String uploadPreset;
  String signUrl;
  String archiveUrl;
  CloudinaryConfig({
    this.cloudName = 'dtz0urit6',
    this.apiKey = '985946268373735',
    this.uploadPreset = 'cloudinary-tools',
    this.signUrl =
        'https://cloudinary-tools.netlify.app/.netlify/functions/sign-upload-params',
    this.archiveUrl =
        'https://cloudinary-tools.netlify.app/.netlify/functions/archive',
  });

  /// Signed upload needs the API key. The key from the original
  /// extension (background.js, CLOUDINARY_API_KEY) is embedded as the
  /// default — same as the extension — so AI upscale works out of the
  /// box. It can be overridden in Settings to use a different
  /// Cloudinary account. If a saved key is cleared, the local
  /// progressive resize is used (same fallback the extension uses when
  /// Cloudinary fails).
  bool get isConfigured => cloudName.isNotEmpty && apiKey.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'cloudName': cloudName,
    'apiKey': apiKey,
    'uploadPreset': uploadPreset,
    'signUrl': signUrl,
    'archiveUrl': archiveUrl,
  };
  factory CloudinaryConfig.fromJson(Map<String, dynamic> j) => CloudinaryConfig(
    cloudName: j['cloudName']?.toString() ?? 'dtz0urit6',
    apiKey: (j['apiKey']?.toString().isNotEmpty ?? false)
        ? j['apiKey'].toString()
        : '985946268373735',
    uploadPreset: j['uploadPreset']?.toString() ?? 'cloudinary-tools',
    signUrl:
        j['signUrl']?.toString() ??
        'https://cloudinary-tools.netlify.app/.netlify/functions/sign-upload-params',
    archiveUrl:
        j['archiveUrl']?.toString() ??
        'https://cloudinary-tools.netlify.app/.netlify/functions/archive',
  );
}

class ImageService {
  ImageService(
      {StatusSink? onStatus, CloudinaryConfig? cloudinary, http.Client? client})
      : onStatus = onStatus ?? ((_) {}),
        cloudinary = cloudinary ?? CloudinaryConfig(),
        _client = client ?? http.Client();

  final StatusSink onStatus;
  CloudinaryConfig cloudinary;
  final http.Client _client;

  /// v75: same timeout rule as GeminiApi — a frozen network must
  /// fail loudly, never hang the generation forever while the
  /// foreground notification claims it is still running.
  Future<http.Response> _post(Uri url,
      {required Map<String, String> headers,
      required Object? body,
      Duration? timeout}) {
    final t = timeout ?? const Duration(minutes: 3);
    return _client.post(url, headers: headers, body: body).timeout(t,
        onTimeout: () => throw TimeoutException(
            'Network request timed out after ${t.inMinutes} min — network thamte pare. Phone lock hole generation thamle battery setting / Phone Master check koro.'));
  }

  Future<http.Response> _get(Uri url,
      {required Map<String, String> headers, Duration? timeout}) {
    final t = timeout ?? const Duration(minutes: 3);
    return _client.get(url, headers: headers).timeout(t,
        onTimeout: () => throw TimeoutException(
            'Network request timed out after ${t.inMinutes} min — network thamte pare. Phone lock hole generation thamle battery setting / Phone Master check koro.'));
  }

  Future<http.StreamedResponse> _send(http.BaseRequest req,
      {Duration? timeout}) {
    final t = timeout ?? const Duration(minutes: 10);
    return _client.send(req).timeout(t,
        onTimeout: () => throw TimeoutException(
            'Upload timed out after ${t.inMinutes} min — network thamte pare. Phone lock hole generation thamle battery setting / Phone Master check koro.'));
  }

  void _status(String state, int step, String message) =>
      onStatus(StatusEvent(state, step, message));

  /// Center-crop to the target aspect, then resize to exactly
  /// targetWidth x targetHeight and encode JPG, stepping quality down
  /// from 100 until the file fits the Zedge <=8 MB rule.
  ///
  /// Runs in a background isolate (compute): the pure-Dart decode +
  /// cubic resize + JPG encodes of a multi-megapixel picture take
  /// many seconds on a phone CPU, and doing them on the UI isolate
  /// froze the whole app — Android kept showing "isn't responding /
  /// Close app" while a set was preparing (v28 fix).
  Future<PreparedImage> resizeToJpg(
    Uint8List sourceBytes,
    int targetWidth,
    int targetHeight, {
    bool upscaledViaCloudinary = false,
    String? hdUrl,
  }) => compute(_resizeToJpgJob, (
    sourceBytes,
    targetWidth,
    targetHeight,
    upscaledViaCloudinary,
    hdUrl,
  ));

  /// Extension: upscaleViaCloudinary — sign, upload, then poll the
  /// e_upscale delivery URL / archive endpoint. 2 cycles, then throws so
  /// the caller falls back to local resize (extension behaviour).
  Future<({Uint8List bytes, String upscaleUrl})> upscaleViaCloudinary(
    Uint8List imageBytes,
    String uploadFilename,
    String label,
    int stepNum,
  ) async {
    Object? lastError;
    for (var cycle = 1; cycle <= 2; cycle++) {
      try {
        final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        Uint8List blobToUpload = imageBytes;
        if (cycle > 1) {
          // Normalise through a plain JPG re-encode, like the extension
          // (in an isolate — a full decode + encode on the UI isolate
          // froze the app, v28).
          blobToUpload =
              await compute(_reencodeJpg96Job, imageBytes) ?? imageBytes;
        }

        _status(
          'upscaling',
          stepNum,
          'Cloudinary AI Upscale ($label) [1/3]: Signing upload parameters${cycle > 1 ? ' (retry)' : ''}...',
        );
        final signResp = await _post(
          Uri.parse(cloudinary.signUrl),
          headers: {'Content-Type': 'application/json', 'Accept': '*/*'},
          body: jsonEncode({
            'paramsToSign': {
              'timestamp': timestamp,
              'upload_preset': cloudinary.uploadPreset,
              'source': 'ml',
            },
          }),
        );
        if (signResp.statusCode != 200) {
          throw Exception(
            'Cloudinary signature request failed (HTTP ${signResp.statusCode})',
          );
        }
        final signJson = jsonDecode(signResp.body) as Map<String, dynamic>;
        final signature = signJson['signature']?.toString() ?? '';
        if (signature.isEmpty) {
          throw Exception(
            'Cloudinary sign-upload-params did not return a valid signature.',
          );
        }

        _status(
          'upscaling',
          stepNum,
          'Cloudinary AI Upscale ($label) [2/3]: Uploading image to Cloudinary...',
        );
        final req = http.MultipartRequest(
          'POST',
          Uri.parse(
            'https://api.cloudinary.com/v1_1/${cloudinary.cloudName}/auto/upload',
          ),
        );
        req.fields['upload_preset'] = cloudinary.uploadPreset;
        req.fields['source'] = 'ml';
        req.fields['signature'] = signature;
        req.fields['timestamp'] = '$timestamp';
        req.fields['api_key'] = cloudinary.apiKey;
        req.files.add(
          http.MultipartFile.fromBytes(
            'file',
            blobToUpload,
            filename: uploadFilename,
          ),
        );
        req.headers['Accept'] =
            'application/json, text/javascript, */*; q=0.01';
        req.headers['X-Requested-With'] = 'XMLHttpRequest';
        final uploadStream = await _send(req);
        final uploadBody = await uploadStream.stream.bytesToString();
        if (uploadStream.statusCode != 200) {
          throw Exception(
            'Cloudinary upload failed (HTTP ${uploadStream.statusCode}): ${uploadBody.length > 120 ? uploadBody.substring(0, 120) : uploadBody}',
          );
        }
        final uploadJson = jsonDecode(uploadBody) as Map<String, dynamic>;
        final publicId = uploadJson['public_id']?.toString() ?? '';
        final version = uploadJson['version'];
        if (publicId.isEmpty) {
          throw Exception('Cloudinary upload response missing public_id.');
        }
        final upscaleUrl =
            'https://res.cloudinary.com/${cloudinary.cloudName}/image/upload/f_jpg,w_512,e_upscale,q_auto/$publicId.jpg';
        final versionedUrl = version != null
            ? 'https://res.cloudinary.com/${cloudinary.cloudName}/image/upload/f_jpg,w_512,e_upscale,q_auto/v$version/$publicId.jpg'
            : upscaleUrl;
        final shortName = publicId.split('/').last;

        _status(
          'upscaling',
          stepNum,
          'Cloudinary AI Upscale ($label) [3/3]: Triggering AI super-resolution...',
        );
        try {
          final initGet = await _get(
            Uri.parse(upscaleUrl),
            headers: {
              'Accept':
                  'image/jxl,image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
            },
          );
          if (initGet.statusCode == 200 &&
              _isValidImageBuffer(initGet.bodyBytes)) {
            return (bytes: initGet.bodyBytes, upscaleUrl: upscaleUrl);
          }
        } catch (_) {}

        await Future.delayed(const Duration(milliseconds: 4500));
        var resourceExpired404 = false;
        for (var attempt = 1; attempt <= 10; attempt++) {
          _status(
            'upscaling',
            stepNum,
            'Cloudinary AI Upscale ($label): Waiting for super-resolution ($attempt/10)...',
          );
          try {
            final target = attempt.isOdd ? upscaleUrl : versionedUrl;
            final imagesParam = jsonEncode([
              {'url': target, 'name': shortName, 'type': 'jpg'},
            ]);
            final archiveResp = await _get(
              Uri.parse(
                '${cloudinary.archiveUrl}?images=${Uri.encodeComponent(imagesParam)}',
              ),
              headers: {'Accept': '*/*'},
            );
            if (archiveResp.statusCode == 200 &&
                archiveResp.bodyBytes.length >= 4096) {
              final unzipped = await compute(
                _extractFirstImageFromZipJob,
                archiveResp.bodyBytes,
              );
              if (unzipped != null) {
                return (bytes: unzipped, upscaleUrl: upscaleUrl);
              }
            }
          } catch (_) {}

          try {
            final pollUrl = attempt.isOdd
                ? '$versionedUrl?_cb=${DateTime.now().millisecondsSinceEpoch}_$attempt'
                : '$upscaleUrl?_cb=${DateTime.now().millisecondsSinceEpoch}_$attempt';
            final pollResp = await _get(
              Uri.parse(pollUrl),
              headers: {
                'Accept':
                    'image/jxl,image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
              },
            );
            if (pollResp.statusCode == 200 &&
                _isValidImageBuffer(pollResp.bodyBytes)) {
              return (bytes: pollResp.bodyBytes, upscaleUrl: upscaleUrl);
            }
            if (pollResp.statusCode == 404) {
              final cldErr = (pollResp.headers['x-cld-error'] ?? '')
                  .toLowerCase();
              if (cldErr.contains('not found') || attempt >= 3) {
                resourceExpired404 = true;
                break;
              }
            }
          } catch (_) {}
          if (resourceExpired404) break;
          await Future.delayed(const Duration(seconds: 3));
        }
        lastError = Exception(
          resourceExpired404
              ? 'Temporary Cloudinary asset expired after 35s on cycle $cycle'
              : 'Timed out waiting for Cloudinary AI upscale ($label) on cycle $cycle',
        );
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ??
        Exception('Timed out waiting for Cloudinary AI upscale ($label).');
  }

  /// Extension: upscaleResizeAndSaveBlob (minus browser downloads — the
  /// caller saves the returned bytes to a real file).
  Future<PreparedImage> prepareImage({
    required Uint8List sourceBytes,
    required String uploadFilename,
    required int targetWidth,
    required int targetHeight,
    required String label,
    required int stepNum,
    String? hdUrl,
    bool upscaleEnabled = true,
  }) async {
    var blobToResize = sourceBytes;
    var upscaleUrl = hdUrl;
    var viaCloudinary = false;

    if (upscaleEnabled && cloudinary.isConfigured) {
      try {
        final up = await upscaleViaCloudinary(
          sourceBytes,
          uploadFilename,
          label,
          stepNum,
        );
        blobToResize = up.bytes;
        upscaleUrl = up.upscaleUrl;
        viaCloudinary = true;
      } catch (e) {
        _status(
          'upscaling',
          stepNum,
          'Cloudinary notice on $label ($e). Using local HD resize to ${targetWidth}x$targetHeight JPG...',
        );
        blobToResize = sourceBytes;
      }
    }
    _status(
      'resizing',
      stepNum,
      'Preparing $label (${targetWidth}x$targetHeight JPG, <=8MB verified)...',
    );
    return resizeToJpg(
      blobToResize,
      targetWidth,
      targetHeight,
      upscaledViaCloudinary: viaCloudinary,
      hdUrl: upscaleUrl,
    );
  }
}

/// The resize itself — top-level so it can run in a compute isolate.
PreparedImage _resizeToJpgJob((Uint8List, int, int, bool, String?) job) {
  final sourceBytes = job.$1;
  final targetWidth = job.$2;
  final targetHeight = job.$3;
  final upscaledViaCloudinary = job.$4;
  final hdUrl = job.$5;
  {
    var image = img.decodeImage(sourceBytes);
    if (image == null) {
      throw Exception(
        'Could not decode source image (${sourceBytes.length} bytes).',
      );
    }
    final srcAspect = image.width / image.height;
    final targetAspect = targetWidth / targetHeight;
    if ((srcAspect - targetAspect).abs() / targetAspect > 0.002) {
      int cropX = 0, cropY = 0, cropW = image.width, cropH = image.height;
      if (srcAspect > targetAspect) {
        cropW = (image.height * targetAspect).round().clamp(1, image.width);
        cropX = ((image.width - cropW) / 2).round();
      } else {
        cropH = (image.width / targetAspect).round().clamp(1, image.height);
        cropY = ((image.height - cropH) / 2).round();
      }
      image = img.copyCrop(
        image,
        x: cropX,
        y: cropY,
        width: cropW,
        height: cropH,
      );
    }
    final resized = img.copyResize(
      image,
      width: targetWidth,
      height: targetHeight,
      interpolation: img.Interpolation.cubic,
    );
    var quality = 100;
    var bytes = Uint8List.fromList(img.encodeJpg(resized, quality: quality));
    for (final q in [96, 92, 88, 84, 80]) {
      if (bytes.length <= kSafeZedgeTargetBytes) break;
      quality = q;
      bytes = Uint8List.fromList(img.encodeJpg(resized, quality: q));
    }
    return PreparedImage(
      bytes: bytes,
      width: targetWidth,
      height: targetHeight,
      qualityPct: quality,
      upscaledViaCloudinary: upscaledViaCloudinary,
      hdUrl: hdUrl,
    );
  }
}

/// Magic-byte image check (JPEG / PNG / WEBP headers) — the cheap
/// validity test used everywhere; a full decode just to check a
/// download is far too slow on the UI isolate.
bool _isValidImageBuffer(Uint8List b) {
  if (b.length < 2048) return false;
  if (b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) return true;
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47) {
    return true;
  }
  if (b.length > 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return true;
  }
  return false;
}

/// Pull the first valid image out of a zip — top-level so it can run
/// in a compute isolate (unzipping on the UI isolate also janked).
Uint8List? _extractFirstImageFromZipJob(Uint8List zipBytes) {
  try {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    for (final file in archive) {
      if (!file.isFile) continue;
      final content = file.content as List<int>;
      final bytes = Uint8List.fromList(content);
      if (_isValidImageBuffer(bytes)) return bytes;
    }
  } catch (_) {}
  return null;
}

/// Plain JPG re-encode (Cloudinary cycle-2 normalisation) — isolate
/// job; null when the bytes do not decode.
Uint8List? _reencodeJpg96Job(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  return Uint8List.fromList(img.encodeJpg(decoded, quality: 96));
}
