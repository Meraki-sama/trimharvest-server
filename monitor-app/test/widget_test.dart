// Widget test dasar untuk TrimHarvestApp (menggantikan file template
// bawaan "flutter create" yang lama -- lihat catatan git/riwayat proyek:
// versi sebelumnya masih menguji class "MyApp" & fitur counter contoh
// yang sudah tidak ada sama sekali di aplikasi ini, sehingga TIDAK BISA
// di-compile).
//
// Test ini SENGAJA dibuat MINIMAL ("smoke test" -- sekadar memastikan
// aplikasi bisa dirender tanpa crash), bukan pengujian menyeluruh:
// AppGate (lib/main.dart) membaca flutter_secure_storage & shared_preferences
// lewat platform channel asli, yang TIDAK tersedia di lingkungan widget
// test tanpa dependency injection/mock tambahan -- pengujian LEBIH DALAM
// (mis. menguji AppGate berpindah ke ServerSetupScreen/LoginScreen/
// DashboardScreen sesuai kondisi) butuh me-mock ApiClient &
// SecureStorageService terlebih dulu (mis. lewat package `mocktail` atau
// menambahkan constructor injeksi dependency ke kedua kelas tersebut) --
// di luar cakupan smoke test dasar ini.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:trimharvest_monitor/main.dart';

void main() {
  testWidgets('TrimHarvestApp merender tanpa crash dan menampilkan '
      'indikator loading di frame pertama', (WidgetTester tester) async {
    // Bangun widget root aplikasi & render SATU frame.
    await tester.pumpWidget(const TrimHarvestApp());
    // ^ Kelas yang benar adalah `TrimHarvestApp` (lihat lib/main.dart),
    //   bukan "MyApp" seperti template lama.

    // AppGate (lib/main.dart) SELALU mulai dari _GateStatus.loading
    // secara SINKRON sebelum _resolveStatus() (yang butuh baca storage
    // secara async) sempat selesai -- jadi frame PERTAMA ini seharusnya
    // menampilkan CircularProgressIndicator, terlepas dari hasil
    // pembacaan storage itu sendiri.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Pastikan TIDAK ADA elemen sisa dari template counter lama --
    // menegaskan test ini benar-benar sudah diperbarui, bukan sisa lama
    // yang kebetulan masih "lolos" karena widget generiknya mirip.
    expect(find.byIcon(Icons.add), findsNothing);
  });
}
