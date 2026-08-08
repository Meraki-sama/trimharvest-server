import 'reading.dart';
import 'alert.dart';

// =============================================================================
// Evaluasi threshold "standar industri" pertanian.
//
// Semua ambang batas di sini mengikuti standar umum budidaya tanaman
// (hidroponik & tanah) -- lihat referensi di bawah. Tujuannya: app otomatis
// memberi peringatan (badge/banner/notifikasi) kalau keadaan tanaman
// menyimpang dari rentang sehat, TANPA perlu pengguna menatap grafik.
//
// Referensi (dirangkum, bukan mengikat satu sumber):
//   * Kelembaban tanah (moisture) ideal ~40-80% (tanaman umum). Di bawah
//     30% = mulai kering (warn), <15% = kritis. Di atas 80% = terlalu
//     basah/becek (warn, risiko busuk akar), >90% = kritis.
//   * Nutrisi/pupuk (TDS dalam ppm; EC ~0.8-2.5 mS/cm ≈ 400-1500 ppm untuk
//     sayur/tanaman umum). <400 ppm = pupuk kurang (warn). >1500 ppm =
//     terlalu pekat (warn), >2000 ppm = kritis (keracunan nutrisi).
//   * Hama/gerakan: sensor PIR (`motion`=1) = ada gerakan di area tanaman
//     -> peringatan "Hama/gerakan terdeteksi" (level warning, bukan
//     critical, karena butuh konfirmasi visual).
//
// Catatan desain: evaluator ini MURNI fungsi dari List<Reading> (data
// generik), TIDAK bergantung pada id sensor spesifik selain konvensi unit
// yang sudah dipakai firmware (%, ppm, bool). Jadi AMAN terhadap penambahan
// sensor baru di masa depan.
// =============================================================================

// Ambang batas kelembaban tanah (%, dari sensor fork & capacitive).
const double _moistureWarnLow = 30.0; // di bawah ini = warning kering
const double _moistureCritLow = 15.0; // di bawah ini = critical kering
const double _moistureWarnHigh = 80.0; // di atas ini = warning basah
const double _moistureCritHigh = 90.0; // di atas ini = critical becek

// Ambang batas nutrisi/pupuk (TDS, ppm).
const double _tdsWarnLow = 400.0; // di bawah ini = pupuk kurang
const double _tdsWarnHigh = 1500.0; // di atas ini = terlalu pekat
const double _tdsCritHigh = 2000.0; // di atas ini = kritis (keracunan)

List<Alert> evaluateReadings(List<Reading> readings) {
  // Fungsi utama: terima snapshot readings, kembalikan LIST alert
  //   (bisa kosong kalau semua normal). Dipanggil dari dashboard &
  //   device_detail tiap dapat data baru.
  final alerts = <Alert>[];

  // --- Kelembaban tanah: ambil dari sensor % (fork atau cap, mana saja
  //     yang ada; kalau keduanya ada, evaluasi masing-masing). ---
  for (final r in readings) {
    if (r.unit != '%') continue;
    if (r.value is! num) continue;
    final v = (r.value as num).toDouble();
    // Sensor fork & cap keduanya % -- beri label sesuai id biar pesan
    // jelas (mis. "Kelembaban tanah (Fork)").
    final label = r.id.toLowerCase().contains('cap')
        ? 'Kelembaban tanah (Kapasitif)'
        : (r.id.toLowerCase().contains('fork')
            ? 'Kelembaban tanah (Fork)'
            : 'Kelembaban tanah');
    _evalMoisture(alerts, r.id, label, v);
  }

  // --- Nutrisi/pupuk: TDS (ppm). ---
  final tds = readings.where((r) => r.id.toLowerCase() == 'tds').firstOrNull;
  if (tds != null && tds.value is num) {
    _evalTds(alerts, (tds.value as num).toDouble());
  }

  // --- Hama/gerakan: PIR (motion=1). ---
  final motion =
      readings.where((r) => r.id.toLowerCase() == 'motion').firstOrNull;
  if (motion != null && motion.value is num && (motion.value as num) != 0) {
    alerts.add(const Alert(
      id: 'motion',
      level: AlertLevel.warning,
      title: 'Hama / Gerakan Terdeteksi',
      message:
          'Sensor gerak mendeteksi aktivitas di area tanaman. Periksa kemungkinan hama atau hewan pengganggu.',
      iconName: 'bug',
    ));
  }

  return alerts;
}

void _evalMoisture(
    List<Alert> alerts, String id, String label, double v) {
  if (v < _moistureCritLow) {
    alerts.add(Alert(
      id: '${id}_crit_low',
      level: AlertLevel.critical,
      title: 'Tanah Sangat Kering',
      message:
          '$label $v% (standar 40-80%). Tanah kritis kering — siram segera atau tanaman berisiko layu permanen.',
      iconName: 'water_drop',
    ));
  } else if (v < _moistureWarnLow) {
    alerts.add(Alert(
      id: '${id}_low',
      level: AlertLevel.warning,
      title: 'Tanah Terlalu Kering',
      message:
          '$label $v% (standar 40-80%). Kelembaban rendah — sebaiknya siram atau cek sistem irigasi.',
      iconName: 'water_drop',
    ));
  } else if (v > _moistureCritHigh) {
    alerts.add(Alert(
      id: '${id}_crit_high',
      level: AlertLevel.critical,
      title: 'Tanah Sangat Basah / Becek',
      message:
          '$label $v% (standar 40-80%). Berisiko busuk akar — kurangi penyiraman & pastikan drainase baik.',
      iconName: 'water_drop',
    ));
  } else if (v > _moistureWarnHigh) {
    alerts.add(Alert(
      id: '${id}_high',
      level: AlertLevel.warning,
      title: 'Tanah Terlalu Basah',
      message:
          '$label $v% (standar 40-80%). Kelembaban tinggi — kurangi penyiraman untuk hindari busuk akar.',
      iconName: 'water_drop',
    ));
  }
}

void _evalTds(List<Alert> alerts, double v) {
  if (v < _tdsWarnLow) {
    alerts.add(Alert(
      id: 'tds_low',
      level: AlertLevel.warning,
      title: 'Pupuk Kurang (Nutrisi Rendah)',
      message:
          'TDS $v ppm (standar 400-1500 ppm). Nutrisi kurang — tambahkan pupuk sesuai dosis tanaman.',
      iconName: 'science',
    ));
  } else if (v > _tdsCritHigh) {
    alerts.add(Alert(
      id: 'tds_crit_high',
      level: AlertLevel.critical,
      title: 'Pupuk Sangat Pekat (Keracunan Nutrisi)',
      message:
          'TDS $v ppm (standar 400-1500 ppm). Terlalu pekat — encerkan dengan air bersih segera.',
      iconName: 'science',
    ));
  } else if (v > _tdsWarnHigh) {
    alerts.add(Alert(
      id: 'tds_high',
      level: AlertLevel.warning,
      title: 'Pupuk Terlalu Pekat',
      message:
          'TDS $v ppm (standar 400-1500 ppm). Nutrisi berlebih — encerkan sedikit dengan air bersih.',
      iconName: 'science',
    ));
  }
}
