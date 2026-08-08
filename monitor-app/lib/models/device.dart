import 'reading.dart';

// Model data untuk SATU device (gateway) yang ditampilkan di dashboard --
// merepresentasikan satu entri dari response GET /api/devices (lihat
// server/src/routes/devices.js).
class Device {
  final String deviceId;
  final String label;
  final DateTime? createdAt;
  final DateTime? lastSeenAt;
  final ReadingSnapshot? lastReading;
  // Semua field bertipe `final` -- objek Device bersifat IMMUTABLE
  //   (tidak bisa diubah setelah dibuat). Ini pola umum & disarankan di
  //   Flutter/Dart untuk model data: kalau data device berubah (mis. ada
  //   reading baru), app membuat objek Device BARU (lewat fromJson lagi),
  //   bukan memutasi objek lama -- membuat alur data lebih predictable &
  //   mudah dilacak (konsisten dengan pola State Management Flutter pada
  //   umumnya, mis. dipakai bersama setState/Provider/dst).

  final bool nodePowerSave;
  // True kalau node sedang mode hemat (lihat node-sawah/src/main.cpp
  //   powerSaveMode, diumumkan lewat field `psv` di body sensor). App
  //   menampilkan badge "HEMAT" (baterai) di kartu device.
  final bool gatewayPowerSave;
  // True kalau gateway sedang mode hemat (lihat gateway-rumah/src/
  //   main.cpp powerSaveMode, diumumkan lewat field `gpsv` di heartbeat).
  //   App menampilkan badge "HEMAT GW".

  const Device({
    required this.deviceId,
    required this.label,
    required this.createdAt,
    required this.lastSeenAt,
    required this.lastReading,
    this.nodePowerSave = false,
    this.gatewayPowerSave = false,
  });
  // Constructor `const` -- semua parameter WAJIB diisi (`required`),
  //   tidak ada default value tersembunyi, memaksa pemanggil eksplisit
  //   soal apa yang diisi (termasuk eksplisit `null` untuk field yang
  //   nullable seperti createdAt).

  factory Device.fromJson(Map<String, dynamic> json) {
    // `factory` constructor -- dipakai untuk constructor yang LOGIKANYA
    //   lebih dari sekadar "assign parameter ke field" (di sini ada
    //   parsing/transformasi data JSON mentah), Dart mensyaratkan
    //   `factory` untuk pola constructor seperti ini.
    final lastReadingJson = json['last_reading'] as Map<String, dynamic>?;
    // Cast dengan `as Map<String, dynamic>?` (nullable) -- kalau field
    //   "last_reading" di JSON memang `null` (device belum pernah kirim
    //   data, lihat routes/devices.js), variabel ini akan bernilai null,
    //   BUKAN error runtime.
    return Device(
      deviceId: json['device_id'] as String? ?? '',
      // Pola `as String? ?? ''` berulang di SELURUH factory ini:
      //   ambil field sebagai tipe nullable, kalau null/tidak ada,
      //   fallback ke default aman (string kosong) -- mencegah CRASH
      //   RUNTIME kalau server mengembalikan JSON yang field-nya
      //   hilang/berbeda dari yang diharapkan (defensif terhadap
      //   perubahan API tak terduga, jauh lebih baik daripada `as
      //   String` tanpa `?` yang akan melempar exception fatal kalau
      //   field-nya ternyata null).
      label: json['label'] as String? ?? (json['device_id'] as String? ?? '-'),
      // Fallback BERTINGKAT: kalau "label" kosong, pakai "device_id";
      //   kalau device_id JUGA entah bagaimana kosong, baru pakai "-" --
      //   menjamin field `label` yang ditampilkan di UI TIDAK PERNAH
      //   benar-benar kosong/null.
      createdAt: _tryParse(json['created_at']),
      lastSeenAt: _tryParse(json['last_seen_at']),
      lastReading: lastReadingJson != null ? ReadingSnapshot.fromJson(lastReadingJson) : null,
      nodePowerSave: json['node_power_save'] as bool? ?? false,
      gatewayPowerSave: json['gateway_power_save'] as bool? ?? false,
    );
  }

  static DateTime? _tryParse(dynamic value) {
    // Helper privat (prefix underscore = private ke file ini dalam
    //   konvensi Dart) untuk parsing tanggal ISO 8601 dari JSON dengan
    //   AMAN -- server mengirim timestamp sebagai string ISO (lihat
    //   routes/ingest.js: `new Date().toISOString()`).
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value);
      // `DateTime.tryParse` (bukan `DateTime.parse`) -- mengembalikan
      //   `null` kalau string TIDAK bisa di-parse sebagai tanggal valid,
      //   BUKAN melempar exception -- konsisten dengan pola defensif
      //   "jangan pernah crash karena data server tidak sesuai harapan"
      //   di seluruh factory ini.
    }
    return null;
  }

  // Dianggap "online" kalau pernah lapor dalam 5 menit terakhir.
  // (heartbeat node bisa 15-120 detik tergantung interval; 300 detik =
  // toleran terhadap beberapa laporan yang telat/hilang tanpa langsung
  // dianggap offline. Sebelumnya 90 detik terlalu ketat -- device yang
  // melaporkan tiap ~60-120 detik sempat menampilkan OFFLINE di dashboard
  // padahal di layar detail datanya masih hidup.)
  bool get isOnline {
    // Dideklarasikan sebagai GETTER (bukan method biasa dengan `()`
    //   kosong) -- dipanggil di widget/tampilan sebagai `device.isOnline`
    //   (terasa seperti properti/atribut, bukan pemanggilan fungsi),
    //   walau di baliknya ada LOGIKA PERHITUNGAN (bukan cuma membaca
    //   field mentah) -- pola idiomatik Dart untuk properti "turunan"
    //   yang murah dihitung.
    if (lastSeenAt == null) return false;
    // Device yang BELUM PERNAH lapor sama sekali (lastSeenAt null,
    //   device baru diprovisioning tapi belum pernah ingest) dianggap
    //   OFFLINE secara default -- keputusan desain yang masuk akal
    //   (tidak ada bukti kontak, jadi tidak diasumsikan online).
    return DateTime.now().difference(lastSeenAt!).inSeconds < 300;
    // CATATAN: nilai ini DIHITUNG ULANG SETIAP KALI getter ini diakses
    //   (memanggil DateTime.now() setiap saat), TIDAK di-cache -- artinya
    //   `device.isOnline` bisa berubah dari true jadi false SEIRING
    //   WAKTU BERJALAN walau objek Device itu sendiri (dan lastSeenAt-nya)
    //   TIDAK PERNAH diubah -- widget yang menampilkan status online
    //   perlu di-refresh/rebuild secara berkala (mis. lewat Timer di
    //   dashboard_screen.dart) supaya status ini terlihat "hidup"/update
    //   otomatis di UI, bukan cuma berubah saat ada data BARU dari
    //   server.
  }
}
