// Renders Tavi in every pose to PNG files (CI saves them to the ci-logs branch for a visual check).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chatapp/widgets/mascot.dart';

void main() {
  testWidgets('render Tavi poses', (tester) async {
    final out = Directory(Platform.environment['MASCOT_OUT'] ?? 'build/mascot')..createSync(recursive: true);
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFFF2F3F8),
        body: RepaintBoundary(
          key: key,
          child: Container(
            color: const Color(0xFFF2F3F8),
            padding: const EdgeInsets.all(10),
            child: Wrap(spacing: 10, runSpacing: 10, children: [
              for (final p in TaviPose.values)
                Container(
                  width: 280,
                  height: 300,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    TaviMascot(pose: p, size: 240),
                    Text(p.name, style: const TextStyle(fontSize: 14, color: Colors.black)),
                  ]),
                ),
            ]),
          ),
        ),
      ),
    ));
    for (final (i, ms) in [(1, 300), (2, 700), (3, 1300)].indexed) {
      await tester.pump(Duration(milliseconds: ms.$2));
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${out.path}/tavi-$i.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
  });
}
