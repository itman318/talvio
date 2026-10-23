import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Host side of the emulator e2e test: saves every screenshot the test takes.
Future<void> main() => integrationDriver(
      onScreenshot: (name, bytes, [args]) async {
        final f = File('../ci-app/$name.png');
        await f.create(recursive: true);
        await f.writeAsBytes(bytes);
        return true;
      },
    );
