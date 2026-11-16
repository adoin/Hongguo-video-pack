import 'package:flutter/services.dart';

List<DeviceOrientation> fullscreenOrientations(double? aspect) {
  if (aspect == null ||
      !aspect.isFinite ||
      aspect <= 0 ||
      (aspect - 1).abs() < .05) {
    return const [];
  }
  return aspect < 1
      ? const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]
      : const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ];
}
