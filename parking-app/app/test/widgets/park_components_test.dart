import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parking_app/design_system/design_system.dart';
import 'package:parking_app/widgets/widgets.dart';

void main() {
  testWidgets('la recherche est étiquetée, effaçable et tactile', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final controller = TextEditingController(text: '10 rue de Rivoli');
    addTearDown(controller.dispose);

    await _pumpAtSize(
      tester,
      size: const Size(390, 844),
      child: ParkMapOverlayShell(
        child: ParkSearchShell(controller: controller),
      ),
    );

    expect(find.text('Destination'), findsOneWidget);
    expect(find.byTooltip('Effacer la destination'), findsOneWidget);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));

    await tester.tap(find.byTooltip('Effacer la destination'));
    await tester.pump();
    expect(controller.text, isEmpty);
    semantics.dispose();
  });

  testWidgets('les indicateurs de confiance et de fraîcheur sont explicites', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pumpAtSize(
      tester,
      size: const Size(390, 844),
      child: const Wrap(
        spacing: ParkRadarSpacing.xs,
        runSpacing: ParkRadarSpacing.xs,
        children: [
          ParkConfidenceChip(
            level: ParkConfidenceLevel.high,
            detail: 'modèle calibré',
          ),
          ParkFreshnessChip(
            level: ParkFreshnessLevel.delayed,
            detail: 'mise à jour il y a 8 min',
          ),
        ],
      ),
    );

    expect(
      find.bySemanticsLabel('Confiance élevée, modèle calibré'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Données retardées, mise à jour il y a 8 min'),
      findsOneWidget,
    );
    expect(find.textContaining('Confiance élevée'), findsOneWidget);
    expect(find.textContaining('Données retardées'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('la bannière reste utilisable avec le texte agrandi', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var retried = false;

    await _pumpAtSize(
      tester,
      size: const Size(320, 568),
      textScale: 2,
      child: ParkStatusBanner(
        tone: ParkStatusTone.warning,
        title: 'Données temporairement retardées',
        message: 'La dernière estimation fiable reste affichée.',
        actionLabel: 'Réessayer',
        onAction: () => retried = true,
      ),
    );

    expect(find.text('Réessayer'), findsOneWidget);
    await tester.tap(find.text('Réessayer'));
    expect(retried, isTrue);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });

  testWidgets('le panneau passe du bas au côté selon le viewport', (
    tester,
  ) async {
    await _pumpAtSize(
      tester,
      size: const Size(390, 844),
      child: const SizedBox.expand(
        child: ParkResponsiveMapPanel(child: Text('Contenu du panneau')),
      ),
    );
    expect(find.byKey(const ValueKey('park-map-panel-bottom')), findsOneWidget);
    expect(find.byKey(const ValueKey('park-map-panel-side')), findsNothing);

    await _pumpAtSize(
      tester,
      size: const Size(1200, 800),
      child: const SizedBox.expand(
        child: ParkResponsiveMapPanel(child: Text('Contenu du panneau')),
      ),
    );
    expect(find.byKey(const ValueKey('park-map-panel-side')), findsOneWidget);
    expect(find.byKey(const ValueKey('park-map-panel-bottom')), findsNothing);
  });
}

Future<void> _pumpAtSize(
  WidgetTester tester, {
  required Size size,
  required Widget child,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: ParkRadarTheme.light,
      home: Builder(
        builder: (context) {
          final mediaQuery = MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale));
          return MediaQuery(
            data: mediaQuery,
            child: Scaffold(
              body: Align(alignment: Alignment.topCenter, child: child),
            ),
          );
        },
      ),
    ),
  );
  await tester.pump();
}
