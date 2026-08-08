// Model GENERIK untuk satu titik data sensor -- SENGAJA tidak ada model
// per-jenis-sensor (mis. "TdsReading", "ForkReading") di seluruh app ini.
// Lihat /PROTOCOL.md bagian 4 ("UI Dinamis / JSON-Driven") untuk alasannya:
// menambah sensor baru di firmware tidak butuh update app sama sekali,
// SELAMA app cuma bergantung pada field generik ini (id, value, unit).
class Reading {
  final String id;    // mis. "tds", "fork", "batt_pct" -- nama bebas dari firmware.
  final num? value; // null = sensor sedang tidak valid (lihat /PROTOCOL.md 1.1)
  final String unit;   // mis. "ppm", "%", "V" -- dipakai UI untuk memformat tampilan.

  const Reading({required this.id, required this.value, required this.unit});

  factory Reading.fromJson(Map<String, dynamic> json) {
    final rawValue = json['value'];
    return Reading(
      id: json['id'] as String? ?? '',
      value: rawValue is num ? rawValue : null,
      // PENTING: `value is num` (pengecekan TIPE, bukan cast paksa) --
      //   menangani KEDUA kemungkinan yang sah dari JSON: field ini bisa
      //   berupa ANGKA sungguhan (int/double) ATAU `null` secara eksplisit
      //   (dikirim firmware saat sensor sedang tidak valid, mis. TDS
      //   saturasi -- lihat readTDSSensor() di node-sawah/src/sensors.cpp
      //   & konversinya jadi JSON null di main.cpp). Kalau `rawValue`
      //   ternyata null ATAU tipe lain yang tidak terduga, `value` di
      //   sini otomatis jadi null (bukan crash), dan UI (reading_card.dart)
      //   bertanggung jawab menampilkan indikator "data tidak valid" untuk
      //   kasus ini.
      unit: json['unit'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'value': value, 'unit': unit};
  // Kebalikan dari fromJson -- CATATAN: method ini ADA di model tapi
  //   (berdasarkan pemakaian di seluruh app) kemungkinan besar TIDAK
  //   dipakai secara aktif di alur normal (app ini lebih banyak MEMBACA
  //   Reading dari server daripada MENGIRIMNYA kembali) -- disediakan
  //   sebagai kelengkapan model / kemudahan debugging (mis. print objek
  //   ini sebagai JSON), bukan bagian kritis dari alur data.
}

// Satu snapshot data (satu kali kirim dari node, diteruskan gateway ke
// server) -- dipakai baik untuk "last_reading" di daftar device maupun
// tiap entri histori.
class ReadingSnapshot {
  final DateTime ts;
  final String type; // "sensor" | "heartbeat"
  final String? nodeMsgType; // "core" | "calib" | null (heartbeat)
  final List<Reading> readings;
  // Satu snapshot BISA berisi BANYAK Reading sekaligus (mis. satu paket
  //   "core" berisi tds, fork, cap, batt_v, batt_pct, motion sekaligus --
  //   lihat sendCoreReadings() di node-sawah/src/main.cpp) -- itulah
  //   kenapa field ini berupa `List<Reading>`, bukan Reading tunggal.

  const ReadingSnapshot({
    required this.ts,
    required this.type,
    required this.nodeMsgType,
    required this.readings,
  });

  factory ReadingSnapshot.fromJson(Map<String, dynamic> json) {
    final rawReadings = json['readings'] as List<dynamic>? ?? const [];
    // Default ke LIST KOSONG (bukan null) kalau field "readings" tidak
    //   ada -- membuat kode pemanggil (widget yang menampilkan
    //   snapshot.readings) tidak perlu cek null-check tambahan, cukup
    //   asumsikan selalu berupa List (yang mungkin kosong).
    return ReadingSnapshot(
      ts: DateTime.tryParse(json['ts'] as String? ?? '') ?? DateTime.now(),
      // Fallback ke `DateTime.now()` kalau timestamp gagal di-parse --
      //   PERHATIKAN ini SEDIKIT BERBEDA dari pola di device.dart
      //   (_tryParse yang fallback ke `null`) -- di sini `ts` memang
      //   BUKAN field nullable (`DateTime ts`, bukan `DateTime? ts`),
      //   jadi HARUS selalu punya nilai valid, dan `DateTime.now()`
      //   dipilih sebagai fallback yang "masuk akal" (menampilkan
      //   snapshot ini seolah baru saja terjadi) daripada memaksa field
      //   ini jadi nullable di seluruh app hanya untuk kasus data rusak
      //   yang seharusnya jarang terjadi.
      type: json['type'] as String? ?? 'sensor',
      nodeMsgType: json['node_msg_type'] as String?,
      readings: rawReadings
          .whereType<Map<String, dynamic>>()
          // `.whereType<T>()` -- method Dart yang MENYARING elemen
          //   list agar HANYA elemen yang cocok dengan tipe `T` yang
          //   diteruskan (elemen dengan tipe lain otomatis DIBUANG diam-
          //   diam, bukan error) -- proteksi tambahan kalau salah satu
          //   elemen di array "readings" somehow bukan object JSON yang
          //   valid.
          .map(Reading.fromJson)
          .toList(growable: false),
          // `growable: false` -- hasil List TIDAK BISA ditambah/dikurangi
          //   elemennya lagi setelah dibuat (immutable secara ukuran) --
          //   konsisten dengan filosofi seluruh model ini (Device,
          //   Reading, ReadingSnapshot semuanya immutable), sedikit lebih
          //   efisien memori juga dibanding List yang growable secara
          //   default.
    );
  }

  Reading? byId(String id) {
    // Helper pencarian: cari SATU Reading tertentu dari daftar
    //   `readings` berdasarkan `id`-nya (mis. `snapshot.byId('tds')`
    //   untuk mengambil hanya data TDS dari snapshot yang berisi banyak
    //   sensor) -- dipakai widget yang perlu menampilkan sensor SPESIFIK
    //   (mis. calibration_screen.dart yang HANYA peduli pada beberapa
    //   sensor tertentu, bukan menampilkan semuanya generik seperti
    //   dashboard).
    for (final r in readings) {
      if (r.id == id) return r;
    }
    return null;
    // Return null (bukan melempar exception) kalau id yang dicari
    //   TIDAK DITEMUKAN -- pemanggil WAJIB menangani kasus null ini
    //   (mis. sensor tersebut belum pernah dikirim dalam snapshot ini),
    //   konsisten dengan gaya "null-safety" eksplisit di seluruh
    //   codebase Dart ini.
  }
}
