import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trimharvest_monitor/widgets/reading_card.dart';
import 'package:trimharvest_monitor/models/reading.dart';

// Test fokus: fitur "angka patokan" (threshold) -- kartu ReadingCard harus
// menampilkan badge "LEWAT BATAS" & ter-tint merah saat nilai melewati
// patokan. Ini verifikasi logika alert yang diminta pengguna.
void main() {
  testWidgets('ReadingCard shows LEWAT BATAS badge when value exceeds threshold',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: const Scaffold(
          body: ReadingCard(
            reading: Reading(id: 'fork', value: 80, unit: '%'),
            // ^ Fork 80% melebihi patokan 40% -> dianggap "terlalu basah".
            threshold: 40,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Badge peringatan harus muncul.
    expect(find.text('LEWAT BATAS'), findsOneWidget);
  });

  testWidgets('ReadingCard shows no badge when within threshold',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: const Scaffold(
          body: ReadingCard(
            reading: Reading(id: 'fork', value: 20, unit: '%'),
            // ^ Fork 20% di bawah patokan 40% -> normal.
            threshold: 40,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('LEWAT BATAS'), findsNothing);
  });

  testWidgets('ReadingCard shows no badge when threshold is null',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: const Scaffold(
          body: ReadingCard(
            reading: Reading(id: 'tds', value: 999, unit: 'ppm'),
            // ^ Tanpa patokan, nilai seberapa pun tidak memicu alert.
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('LEWAT BATAS'), findsNothing);
  });
}
