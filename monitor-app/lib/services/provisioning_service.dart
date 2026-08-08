import 'dart:convert';
import 'package:http/http.dart' as http;

class WifiNetwork {
  final String ssid;
  final int rssi;
  final bool secure;
  const WifiNetwork({required this.ssid, required this.rssi, required this.secure});

  factory WifiNetwork.fromJson(Map<String, dynamic> json) => WifiNetwork(
        ssid: json['ssid'] as String? ?? '',
        rssi: (json['rssi'] as num?)?.toInt() ?? -100,
        // Fallback ke -100 dBm (sinyal SANGAT LEMAH secara konvensi)
        //   kalau field rssi hilang/tidak valid -- memastikan jaringan
        //   dengan data rusak ini akan TAMPIL PALING BAWAH di daftar
        //   terurut (lihat scanNetworks() di bawah: diurutkan sinyal
        //   terkuat dulu), bukan menyebabkan crash atau muncul di posisi
        //   yang salah/acak.
        secure: json['secure'] as bool? ?? true,
        // Default AMAN kalau field tidak ada: ASUMSIKAN jaringan itu
        //   SECURE (butuh password) -- lebih baik salah asumsi
        //   "perlu password" (pengguna diminta mengetik password yang
        //   ternyata tidak perlu, sedikit merepotkan) daripada salah
        //   asumsi "terbuka" (pengguna tidak diberi kolom password
        //   padahal sebenarnya perlu, gagal konek tanpa penjelasan jelas).
      );
}

// Bicara ke gateway lewat Access Point setup-nya sendiri (lihat
// gateway-rumah/src/wifi_provision.h/.cpp & /PROTOCOL.md) -- HP pengguna
// harus sudah tersambung ke WiFi "Gateway-Setup-<device_id>" SEBELUM
// memanggil method di kelas ini. Ini SAMA SEKALI TERPISAH dari ApiClient
// (yang bicara ke server lewat internet) -- keduanya kebetulan berjalan
// berurutan dalam satu alur "Tambah Device Baru" di add_device_screen.dart.
class GatewayProvisioningService {
  static const String gatewayApBaseUrl = 'http://192.168.4.1';
  // IP TETAP -- alamat default Access Point ESP32 (lihat
  //   gateway-rumah/src/wifi_provision.cpp: WiFi.softAP()), TIDAK perlu
  //   dikonfigurasi/dicari-tahu, karena SELALU alamat ini selama HP
  //   terhubung ke AP setup gateway.
  static const Duration _timeout = Duration(seconds: 8);
  // Timeout DEFAULT untuk request ke gateway lewat AP -- koneksi
  //   WiFi lokal langsung (bukan lewat internet), jadi biasanya jauh
  //   lebih cepat dari request ke server (yang bisa saja melewati banyak
  //   hop jaringan) -- 8 detik masih memberi margin wajar.

  final http.Client _http = http.Client();
  // CATATAN: kelas ini punya `http.Client()` SENDIRI, TERPISAH dari
  //   yang dipakai ApiClient -- masuk akal karena keduanya bicara ke
  //   HOST YANG BERBEDA TOTAL (192.168.4.1 lokal vs server internet),
  //   sesuai dengan penjelasan header komentar bahwa kelas ini "SAMA
  //   SEKALI TERPISAH" dari ApiClient.

  Future<Map<String, dynamic>> getStatus() async {
    final resp = await _http.get(Uri.parse('$gatewayApBaseUrl/status')).timeout(_timeout);
    if (resp.statusCode != 200) {
      throw Exception('Gateway tidak merespons dengan benar (kode ${resp.statusCode}).');
      // CATATAN: melempar `Exception` bawaan Dart langsung (bukan
      //   `ApiException` kustom seperti di api_client.dart) -- kelas ini
      //   memang TIDAK memakai skema exception/terjemahan error yang
      //   sama seperti ApiClient (wajar, karena ini bicara ke gateway
      //   lokal dengan format respons error yang lebih sederhana, bukan
      //   ke server Node.js yang formatnya sudah dipetakan
      //   _translateError()).
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
    // Dikembalikan sebagai Map MENTAH (bukan model class khusus seperti
    //   Device/Reading) -- untuk endpoint sesederhana /status ini,
    //   membuat model class terpisah dianggap berlebihan; pemanggil
    //   (add_device_screen.dart) cukup mengakses field yang dibutuhkan
    //   langsung dari Map.
  }

  Future<List<WifiNetwork>> scanNetworks() async {
    final resp = await _http.get(Uri.parse('$gatewayApBaseUrl/scan')).timeout(
          const Duration(seconds: 15), // scan WiFi di ESP32 bisa makan beberapa detik
        );
    // Timeout LEBIH PANJANG (15 detik) daripada default `_timeout` (8
    //   detik) -- KHUSUS untuk endpoint ini, karena
    //   `WiFi.scanNetworks()` di firmware gateway memang BLOCKING &
    //   bisa memakan waktu beberapa detik sebelum gateway sempat
    //   membalas apa pun (lihat handleScan() di
    //   gateway-rumah/src/wifi_provision.cpp) -- kalau memakai timeout
    //   default 8 detik, request ini BERISIKO gagal timeout padahal
    //   gateway sebenarnya masih memproses dengan normal, hanya
    //   memerlukan waktu scan yang wajar.
    if (resp.statusCode != 200) {
      throw Exception('Gagal memindai WiFi (kode ${resp.statusCode}).');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = data['networks'] as List<dynamic>? ?? const [];
    final networks = list
        .whereType<Map<String, dynamic>>()
        .map(WifiNetwork.fromJson)
        .toList(growable: false);
    networks.sort((a, b) => b.rssi.compareTo(a.rssi)); // sinyal terkuat dulu
    // `.sort()` MEMUTASI list yang sudah dibuat `toList(growable:
    //   false)` di atas -- CATATAN TEKNIS: `growable: false` HANYA
    //   melarang menambah/menghapus ELEMEN dari list (mis. .add()/
    //   .remove() akan error), TAPI operasi seperti `.sort()` yang
    //   MENGUBAH URUTAN elemen yang SUDAH ADA (tanpa mengubah jumlahnya)
    //   tetap DIPERBOLEHKAN -- jadi baris ini valid & tidak akan error,
    //   walau sekilas terlihat kontradiktif dengan "immutability" list
    //   tersebut.
    //   Perbandingan `b.rssi.compareTo(a.rssi)` (bukan `a.compareTo(b)`)
    //   membalik urutan MENAIK jadi MENURUN -- karena RSSI adalah angka
    //   NEGATIF (mis. -50 lebih kuat dari -85), urutan "b dibanding a"
    //   ini menghasilkan SINYAL TERKUAT (angka mendekati 0) di posisi
    //   PERTAMA.
    return networks;
  }

  /// device_id/deviceSecret/serverUrl boleh null (lihat /PROTOCOL.md --
  /// kalau null, gateway mempertahankan identitas lama, hanya WiFi yang
  /// diganti).
  Future<void> configure({
    required String ssid,
    required String password,
    String? deviceId,
    String? deviceSecret,
    String? serverUrl,
    // Tiga parameter TERAKHIR bertipe NULLABLE & TIDAK `required` --
    //   mencerminkan langsung dokumentasi endpoint POST /configure di
    //   gateway-rumah/src/wifi_provision.h: field ini opsional, boleh
    //   dikosongkan kalau hanya WiFi yang mau diganti.
  }) async {
    final body = <String, dynamic>{'ssid': ssid, 'password': password};
    if (deviceId != null) body['device_id'] = deviceId;
    if (deviceSecret != null) body['device_secret'] = deviceSecret;
    if (serverUrl != null) body['server_url'] = serverUrl;
    // Field HANYA dimasukkan ke `body` kalau memang diisi (tidak
    //   null) -- kalau pemanggil TIDAK mengisi (mis. skenario "ganti
    //   WiFi saja"), field-field ini SAMA SEKALI TIDAK ADA di JSON yang
    //   dikirim, bukan dikirim sebagai `null` eksplisit -- konsisten
    //   dengan cara firmware gateway mengecek `doc["device_id"] | ""`
    //   (default ke string kosong kalau field tidak ada di JSON, lihat
    //   handleConfigure() di wifi_provision.cpp).

    final resp = await _http
        .post(
          Uri.parse('$gatewayApBaseUrl/configure'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(_timeout);

    if (resp.statusCode != 200) {
      throw Exception('Gateway menolak konfigurasi (kode ${resp.statusCode}).');
      // Dipanggil TERAKHIR dalam alur "Tambah Device Baru" -- setelah
      //   method ini sukses (tidak melempar exception), gateway SEDANG
      //   DALAM PROSES restart (lihat handleConfigure() di firmware:
      //   delay(1000) lalu ESP.restart()) untuk menyambung ke WiFi baru
      //   dengan identitas barunya -- add_device_screen.dart perlu
      //   menampilkan pesan yang sesuai (mis. "Gateway sedang restart,
      //   tunggu sebentar...") setelah panggilan ini berhasil, BUKAN
      //   berasumsi gateway langsung siap dipakai detik itu juga.
    }
  }
}
