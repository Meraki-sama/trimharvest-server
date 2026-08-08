// Model peringatan (alert) hasil evaluasi threshold "standar industri".
// Dipakai baik untuk badge di kartu sensor, banner di dashboard, maupun
// notifikasi lokal di status bar HP -- lihat /PROTOCOL.md bagian 4 (UI
// dinamis) & thresholds.dart.
enum AlertLevel { info, warning, critical }

// Tiga tingkat urgensi, konsisten dengan warna: info=hijau/netral,
//   warning=amber, critical=merah. Dipakai UI untuk menentukan warna
//   badge/banner tanpa perlu tahu detail sensor.

class Alert {
  final String id;
  // ID STABIL (mis. "fork_low", "tds_high", "motion") -- dipakai
  //   anti-spam notifikasi (NotificationService) supaya alert YANG SAMA
  //   tidak memunculkan notif berulang-ulang tiap poll 3 detik.
  final AlertLevel level;
  final String title;
  // Judul singkat, mis. "Tanah Terlalu Kering".
  final String message;
  // Penjelasan + saran, mis. "Kelembaban tanah 22% (standar 40-80%).
  //   Siram segera atau cek irigasi."
  final String iconName;
  // Nama ikon generik (string, bukan IconData) supaya model ini tetap
  //   murni data (bisa di-serialize / diuji tanpa konteks Flutter). UI
  //   memetakan ke Icons.* yang sesuai.

  const Alert({
    required this.id,
    required this.level,
    required this.title,
    required this.message,
    this.iconName = 'warning',
  });

  // Untuk deduplikasi/perbandingan sederhana.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Alert && other.id == id && other.level == level;

  @override
  int get hashCode => id.hashCode ^ level.hashCode;
}
