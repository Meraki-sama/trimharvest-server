import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/device.dart';
import '../models/reading.dart';
import 'secure_storage_service.dart';

class ApiException implements Exception {
  // `implements Exception` -- Dart tidak punya "class Exception" WAJIB
  //   diwarisi seperti bahasa lain, cukup mengimplementasikan interface
  //   marker kosong `Exception` supaya bisa dilempar dengan `throw` &
  //   ditangkap khusus lewat `on ApiException catch (e)` di kode
  //   pemanggil (mis. di UI screen yang menampilkan pesan error ini).
  final String message;
  final int? statusCode;
  ApiException(this.message, [this.statusCode]);
  // `[this.statusCode]` -- parameter OPSIONAL POSISIONAL (dalam kurung
  //   siku) -- bisa dipanggil `ApiException('pesan')` (statusCode jadi
  //   null) ATAU `ApiException('pesan', 404)`.

  @override
  String toString() => message;
  // Override `toString()` supaya kalau exception ini dicetak langsung
  //   (mis. lewat `print(e)` atau ditampilkan di SnackBar), yang muncul
  //   adalah PESAN yang sudah diterjemahkan ke Bahasa Indonesia (lihat
  //   _translateError di bawah), bukan representasi default Dart seperti
  //   "Instance of 'ApiException'".
}

// Klien HTTP tunggal ke Server Node.js -- app ini TIDAK PERNAH bicara
// langsung ke Firebase (lihat /PROTOCOL.md di root repo untuk alasan
// arsitektur ini). Semua request otentikasi pakai JWT (lihat
// /PROTOCOL.md bagian 3), dengan auto-refresh sekali kalau access token
// kedaluwarsa (401).
class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();
  // Pola singleton yang SAMA dengan SecureStorageService/ThemeController
  // -- satu klien HTTP dipakai bersama di seluruh app.

  /// Normalisasi URL server jadi ORIGIN MURNI (scheme://host[:port]),
  /// membuang path/query/fragment. Cegah dobel path saat digabung endpoint
  /// (mis. 'https://x.com/api/auth/login' -> 'https://x.com').
  static String normalizeServerUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    // Cek scheme & host saja (bukan isAbsolute -- Dart anggap URL
    //   ber-fragment/query sebagai TIDAK absolute, padahal host-nya valid).
    if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) return url.trim();
    // Uri(scheme,host,port) buang otomatis path/query/fragment, simpan
    //   origin murni; port default (80/443) tidak ditulis ulang.
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.port).toString();
  }

  final http.Client _http = http.Client();
  // `http.Client()` dari package `http` -- dipakai (bukan `http.get()`/
  //   `http.post()` fungsi statis langsung) supaya KONEKSI TCP bisa
  //   DIPAKAI ULANG antar-request (connection reuse/keep-alive) --
  //   sedikit lebih efisien daripada membuka koneksi baru tiap request.

  Future<String> _baseUrl() async {
    final raw = await SecureStorageService.instance.readServerBaseUrl();
    if (raw == null || raw.isEmpty) {
      throw ApiException('Server belum dikonfigurasi. Buka menu Pengaturan Server dulu.');
      // Pesan error yang JELAS & ACTIONABLE (memberi tahu APA yang
      //   harus dilakukan pengguna) -- bukan sekadar "error" generik.
    }
    return normalizeServerUrl(raw);
    // Normalisasi membuang path yg mungkin terbawa di secure storage,
    //   supaya gabungan '$base/api/auth/login' tidak jadi dobel path.
  }

  Map<String, dynamic> _decodeOrThrow(http.Response resp) {
    // Helper SENTRAL yang dipakai HAMPIR SEMUA method publik di bawah
    //   -- menyatukan logika "parse JSON & tentukan sukses/gagal" di
    //   SATU tempat, supaya tidak perlu duplikasi logika yang sama di
    //   setiap method (login, fetchDevices, sendCommand, dst).
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      // `catch (_)` -- tangkap exception TANPA menyimpannya ke
      //   variabel (`_` = "saya tidak butuh nilainya") -- dipakai kalau
      //   kita cuma peduli BAHWA error terjadi, bukan detail error-nya.
      throw ApiException('Respons server tidak valid (bukan JSON).', resp.statusCode);
      // Menangani kasus server mengembalikan respons yang BUKAN JSON
      //   sama sekali (mis. halaman error HTML dari reverse proxy/load
      //   balancer di depan server, atau server down total) -- tanpa
      //   pengecekan ini, `jsonDecode` akan melempar exception MENTAH
      //   yang kurang jelas pesannya bagi pengguna akhir.
    }

    if (resp.statusCode >= 200 && resp.statusCode < 300 && parsed['ok'] == true) {
      // DUA syarat sukses SEKALIGUS: (1) status HTTP di rentang 2xx
      //   (sukses secara protokol HTTP), DAN (2) field `ok` di body JSON
      //   juga `true` (sukses secara SEMANTIK aplikasi) -- konsisten
      //   dengan format respons server yang SELALU menyertakan `{ok:
      //   true/false, ...}` (lihat server/src/routes/*.js) -- pengecekan
      //   GANDA ini penting karena secara teori bisa saja status HTTP
      //   200 tapi body-nya somehow `{ok:false}` (walau dalam praktik
      //   server ini konsisten menyamakan keduanya).
      return parsed;
    }

    final errorCode = parsed['error'] as String? ?? 'unknown_error';
    throw ApiException(_translateError(errorCode), resp.statusCode);
    // Ambil KODE ERROR mentah dari server (mis.
    //   "username_atau_password_salah" -- lihat server/src/routes/auth.js),
    //   lalu TERJEMAHKAN ke pesan Bahasa Indonesia yang ramah pengguna
    //   lewat _translateError() di bawah -- app TIDAK PERNAH menampilkan
    //   kode error mentah server langsung ke pengguna akhir.
  }

  String _translateError(String code) {
    // Satu "kamus terjemahan" kode error server -> pesan yang mudah
    //   dipahami pengguna -- KONTRAK format kode error INI HARUS SINKRON
    //   dengan yang dipakai server (lihat semua `res.status(...).json({
    //   ok: false, error: '...' })` di server/src/routes/*.js &
    //   middleware/*.js) -- kalau server menambah jenis error BARU yang
    //   belum ada di switch ini, otomatis jatuh ke `default` (pesan
    //   generik dengan kode aslinya disertakan) -- TIDAK CRASH, tapi
    //   pesan kurang spesifik sampai daftar ini diperbarui juga.
    switch (code) {
      case 'username_atau_password_salah':
        return 'Username atau password salah.';
      case 'terlalu_banyak_percobaan_login_coba_lagi_nanti':
        return 'Terlalu banyak percobaan login. Coba lagi beberapa menit lagi.';
      case 'token_tidak_valid_atau_kedaluwarsa':
      case 'refresh_token_tidak_valid_atau_kedaluwarsa':
        // Dua kode error BERBEDA dari server (satu dari operatorAuth
        //   middleware, satu dari endpoint /refresh) yang DIGABUNG jadi
        //   SATU pesan yang sama bagi pengguna -- dari sudut pandang
        //   pengguna akhir, keduanya berarti hal yang sama: "harus login
        //   ulang", jadi tidak perlu dibedakan pesannya di UI walau
        //   penyebab teknisnya berbeda.
        return 'Sesi berakhir, silakan login lagi.';
      case 'device_tidak_ditemukan':
        return 'Device tidak ditemukan.';
      case 'password_lama_salah':
        return 'Password lama salah.';
      case 'password_kosong':
        return 'Password lama & baru wajib diisi.';
      case 'input_tidak_valid':
        return 'Data tidak valid (password minimal 8 karakter).';
      default:
        return 'Terjadi kesalahan ($code).';
        // Fallback yang MASIH MENYERTAKAN kode error asli (`$code`) --
        //   berguna untuk debugging/laporan bug pengguna (mis. screenshot
        //   pesan error ini bisa langsung menunjukkan kode error server
        //   yang persis, tanpa perlu akses log server).
    }
  }

  // ---------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------

  Future<void> login(String username, String password) async {
    final base = await _baseUrl();
    final resp = await _http.post(
      Uri.parse('$base/api/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );
    final data = _decodeOrThrow(resp);
    await SecureStorageService.instance.saveTokens(
      accessToken: data['accessToken'] as String,
      refreshToken: data['refreshToken'] as String,
    );
    // Login BERHASIL -> langsung simpan KEDUA token ke secure storage
    //   di sini -- pemanggil (login_screen.dart) tidak perlu tahu/
    //   menangani penyimpanan token sama sekali, cukup panggil
    //   `login()` dan tangani exception kalau gagal.
  }

  Future<bool> _tryRefresh() async {
    // Private (prefix underscore) -- hanya dipakai INTERNAL oleh
    //   _authorizedRequest() di bawah, tidak dipanggil langsung dari
    //   UI/screen mana pun (auto-refresh adalah detail implementasi
    //   yang disembunyikan dari pemanggil).
    final refreshToken = await SecureStorageService.instance.readRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) return false;
    // Tidak ada refresh token tersimpan (mis. belum pernah login sama
    //   sekali) -- gagal cepat, TIDAK mencoba request ke server yang
    //   pasti sia-sia.

    final base = await _baseUrl();
    final resp = await _http.post(
      Uri.parse('$base/api/auth/refresh'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'refreshToken': refreshToken}),
    );
    if (resp.statusCode != 200) return false;
    // CATATAN: di sini TIDAK memakai _decodeOrThrow() (yang akan
    //   MELEMPAR exception kalau gagal) -- SENGAJA memakai pengecekan
    //   manual yang mengembalikan `false` biasa, karena fungsi ini
    //   dipanggil sebagai bagian dari LOGIKA RETRY internal
    //   (_authorizedRequest di bawah) yang perlu tahu "berhasil atau
    //   tidak" sebagai boolean sederhana untuk memutuskan langkah
    //   berikutnya, bukan sebagai kegagalan fatal yang perlu
    //   menghentikan alur dengan exception.

    try {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['ok'] != true) return false;
      await SecureStorageService.instance.saveAccessToken(data['accessToken'] as String);
      return true;
    } catch (_) {
      return false;
      // Kalau body respons GAGAL di-parse sebagai JSON, dianggap
      //   refresh gagal (bukan exception fatal) -- konsisten dengan
      //   filosofi "fungsi ini return bool, tidak pernah throw".
    }
  }

  Future<bool> isLoggedIn() async {
    final token = await SecureStorageService.instance.readAccessToken();
    return token != null && token.isNotEmpty;
    // CATATAN: ini HANYA mengecek "APAKAH ADA token tersimpan", TIDAK
    //   memvalidasi apakah token itu MASIH VALID/belum kedaluwarsa
    //   (validasi sungguhan baru terjadi saat token ini benar-benar
    //   dipakai di request nyata & server menolaknya dengan 401) --
    //   dipakai main.dart/dashboard untuk memutuskan layar AWAL yang
    //   ditampilkan (langsung ke dashboard vs ke layar login), BUKAN
    //   sebagai jaminan sesi masih aktif.
  }

  /// Mengecek apakah token yang tersimpan MASIH VALID di server (bukan
  /// cuma "ada di storage"). Dipakai AppGate saat app dibuka: kalau token
  /// ada TAPI sudah kedaluwarsa/server menolak (401), lempar ke layar login
  /// dengan bersih, bukan stuck di dashboard yang cuma menampilkan error
  /// "Tidak bisa terhubung". Kalau GAGAL KARENA JARINGAN (bukan 401),
  /// kembalikan `true` (anggap masih login) supaya app tidak salah lempar
  /// ke login cuma gara-gara WiFi/DNA sedang flaky -- dashboard yang akan
  /// menangani retry jaringan lewat polling berkala.
  Future<bool> isTokenStillValid() async {
    final token = await SecureStorageService.instance.readAccessToken();
    if (token == null || token.isEmpty) return false;
    try {
      final resp = await _authorizedRequest('GET', '/api/devices');
      // 200/2xx -> token valid. 401 -> token invalid, panggil refresh sekali
      // (sudah ditangani di _authorizedRequest) lalu cek lagi.
      if (resp.statusCode == 200) return true;
      if (resp.statusCode == 401) {
        // Coba refresh sekali; kalau berhasil, token baru valid.
        final refreshed = await _tryRefresh();
        if (refreshed) return true;
        await logout(); // token & refresh sama-sama invalid -> bersihkan
        return false;
      }
      // Selain 200/401 (mis. 500, timeout, DNS gagal): anggap masih login,
      // jangan salah lempar ke login gara-gara jaringan sedang bermasalah.
      return true;
    } catch (_) {
      // Error jaringan (DNS gagal, tidak ada internet, dll) -> jangan lempar
      // ke login, biarkan dashboard yang retry.
      return true;
    }
  }

  Future<void> logout() async {
    await SecureStorageService.instance.clearTokens();
  }

  Future<http.Response> _authorizedRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool isRetry = false,
    // Parameter INTERNAL (bukan untuk dipanggil manual dari luar
    //   dengan `true`) -- dipakai fungsi ini SENDIRI saat memanggil
    //   dirinya secara REKURSIF (lihat di bawah) untuk mencegah LOOP TAK
    //   TERBATAS: tanpa flag ini, kalau refresh token BERHASIL tapi
    //   access token BARU yang didapat SOMEHOW tetap ditolak server
    //   (401 lagi), fungsi ini akan terus mencoba refresh berulang-ulang
    //   tanpa henti.
  }) async {
    final base = await _baseUrl();
    final token = await SecureStorageService.instance.readAccessToken();
    if (token == null || token.isEmpty) {
      throw ApiException('Belum login.', 401);
      // Gagal cepat kalau memang tidak ada token sama sekali -- tidak
      //   ada gunanya mencoba request yang pasti ditolak server.
    }

    final uri = Uri.parse('$base$path');
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
      // Format header yang PERSIS sesuai yang diharapkan
      //   server/src/middleware/operatorAuth.js (regex `^Bearer (.+)$`).
    };

    http.Response resp;
    switch (method) {
      case 'GET':
        resp = await _http.get(uri, headers: headers);
        break;
      case 'POST':
        resp = await _http.post(uri, headers: headers, body: jsonEncode(body ?? {}));
        // `body ?? {}` -- kalau pemanggil tidak menyertakan body sama
        //   sekali (mis. POST /rekey yang tidak butuh body apa pun),
        //   kirim object JSON kosong `{}`, bukan `null` mentah (server
        //   Express dengan express.json() menangani body kosong dengan
        //   baik, tapi mengirim JSON valid `{}` lebih konsisten &
        //   predictable).
        break;
      case 'DELETE':
        resp = await _http.delete(uri, headers: headers);
        // DELETE tidak butuh body -- dipakai untuk hapus device
        //   (lihat deleteDevice() di bawah), method Express-nya sendiri
        //   juga tidak membaca `req.body` apa pun untuk endpoint ini.
        break;
      default:
        throw ArgumentError('Metode HTTP tidak didukung: $method');
        // `ArgumentError` (bukan `ApiException`) -- ini KESALAHAN
        //   PROGRAMMER (memanggil method ini dengan string method yang
        //   tidak didukung), BUKAN kegagalan komunikasi dengan server --
        //   dibedakan jenis exception-nya supaya jelas di mana letak
        //   masalahnya kalau ini benar-benar terjadi (seharusnya
        //   ketahuan saat development, bukan di produksi).
    }

    if (resp.statusCode == 401 && !isRetry) {
      // INTI dari mekanisme "auto-refresh sekali" yang disebut di
      //   komentar header kelas ini: request GAGAL karena token
      //   kedaluwarsa (401) DAN ini BUKAN percobaan ulang (belum pernah
      //   di-retry sebelumnya untuk request yang sama).
      final refreshed = await _tryRefresh();
      if (refreshed) {
        return _authorizedRequest(method, path, body: body, isRetry: true);
        // PANGGIL ULANG fungsi ini SENDIRI (rekursi) dengan `isRetry:
        //   true` -- kali ini memakai access token BARU yang baru saja
        //   disimpan oleh _tryRefresh() di atas. Kalau request KEDUA ini
        //   MASIH gagal 401, kondisi `!isRetry` di baris ini akan false
        //   (karena isRetry sudah true), sehingga TIDAK mencoba refresh
        //   lagi -- mencegah loop tak terbatas, respons 401 kedua ini
        //   akan diteruskan apa adanya ke pemanggil (yang lalu
        //   akan diproses _decodeOrThrow menjadi ApiException "sesi
        //   berakhir").
      }
    }

    return resp;
    // Kalau BUKAN 401, ATAU sudah retry, ATAU refresh gagal -- respons
    //   (apapun isinya) dikembalikan APA ADANYA ke pemanggil, yang akan
    //   memprosesnya lewat _decodeOrThrow().
  }

  // ---------------------------------------------------------------------
  // Devices
  // ---------------------------------------------------------------------

  Future<List<Device>> fetchDevices() async {
    final resp = await _authorizedRequest('GET', '/api/devices');
    final data = _decodeOrThrow(resp);
    final list = data['devices'] as List<dynamic>? ?? const [];
    return list.whereType<Map<String, dynamic>>().map(Device.fromJson).toList(growable: false);
    // Pola parsing list yang KONSISTEN dengan ReadingSnapshot.fromJson
    //   di models/reading.dart: default list kosong, filter tipe yang
    //   valid, map ke model, hasil immutable.
  }

  /// Mendaftarkan device baru di server. Balikan device_id+device_secret
  /// HANYA MUNCUL SEKALI di sini -- lihat /PROTOCOL.md bagian 3.
  Future<({String deviceId, String deviceSecret})> provisionDevice({String label = ''}) async {
    // `({String deviceId, String deviceSecret})` adalah RECORD TYPE --
    //   fitur Dart 3+ untuk mengembalikan BEBERAPA nilai bernama
    //   SEKALIGUS dari satu fungsi, TANPA perlu mendefinisikan class
    //   khusus (mis. "ProvisionResult") hanya untuk sepasang nilai ini.
    //   Dipanggil di add_device_screen.dart sebagai
    //   `result.deviceId`/`result.deviceSecret`.
    final resp = await _authorizedRequest('POST', '/api/devices', body: {'label': label});
    final data = _decodeOrThrow(resp);
    return (deviceId: data['device_id'] as String, deviceSecret: data['device_secret'] as String);
  }

  Future<List<ReadingSnapshot>> fetchReadings(String deviceId, {int limit = 200}) async {
    final resp = await _authorizedRequest('GET', '/api/devices/$deviceId/readings?limit=$limit');
    final data = _decodeOrThrow(resp);
    final list = data['readings'] as List<dynamic>? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(ReadingSnapshot.fromJson)
        .toList(growable: false);
    // `limit` default 200 -- di bawah batas atas 500 yang dipaksakan
    //   server (lihat server/src/routes/devices.js Math.min(...,500)),
    //   dipilih sebagai jumlah data histori yang cukup untuk grafik tanpa
    //   membebani device_detail_screen.dart dengan terlalu banyak titik
    //   data sekaligus.
  }

  Future<void> sendCommand(String deviceId, Map<String, dynamic> command) async {
    final resp = await _authorizedRequest('POST', '/api/devices/$deviceId/commands', body: command);
    _decodeOrThrow(resp);
    // Hasil `_decodeOrThrow` TIDAK disimpan/dikembalikan -- fungsi ini
    //   cuma peduli APAKAH request berhasil (kalau gagal, _decodeOrThrow
    //   sudah melempar ApiException) -- respons sukses server untuk
    //   endpoint ini cuma `{ok:true}` tanpa data tambahan yang berguna
    //   bagi pemanggil.
  }

  /// Rotasi device_secret. Nilai baru HANYA MUNCUL SEKALI di sini.
  Future<String> rekeyDevice(String deviceId) async {
    final resp = await _authorizedRequest('POST', '/api/devices/$deviceId/rekey');
    final data = _decodeOrThrow(resp);
    return data['device_secret'] as String;
  }

  /// Mengganti password operator yang sedang login. Wajib password lama
  /// (verifikasi) + password baru (server validasi minimal 8 karakter).
  Future<void> changePassword(String currentPassword, String newPassword) async {
    final resp = await _authorizedRequest('POST', '/api/auth/change-password', body: {
      'currentPassword': currentPassword,
      'newPassword': newPassword,
    });
    final data = _decodeOrThrow(resp);
    // Kalau gagal (password lama salah / terlalu pendek), _decodeOrThrow
    //   sudah melempar ApiException dengan pesan Bahasa Indonesia.

    // PENTING: server kini MENCABUT semua sesi lama saat password diganti
    // (menaikkan operators.token_version), lalu mengirim sepasang token BARU
    // khusus untuk perangkat yang melakukan penggantian ini. Token itu WAJIB
    // disimpan -- kalau tidak, token lama di HP ini ikut tercabut dan
    // pengguna langsung terlempar ke layar login tepat setelah berhasil
    // mengganti password (terasa seperti aplikasi error, padahal sukses).
    final newAccess = data['accessToken'];
    final newRefresh = data['refreshToken'];
    if (newAccess is String && newRefresh is String) {
      await SecureStorageService.instance.saveTokens(
        accessToken: newAccess,
        refreshToken: newRefresh,
      );
    }
    // Dijaga dengan pengecekan tipe supaya app versi ini tetap bekerja
    //   melawan server versi LAMA yang hanya membalas {ok:true} tanpa token
    //   (tidak crash, cuma tidak ada yang perlu diperbarui).
  }

  /// Menghapus device secara PERMANEN (dokumen device + seluruh histori
  /// readings-nya di server, lihat server/src/routes/devices.js DELETE
  /// /:id). TIDAK ADA cara membatalkan/mengembalikan setelah ini berhasil
  /// -- pemanggil (device_detail_screen.dart) WAJIB menampilkan dialog
  /// konfirmasi dulu sebelum memanggil method ini, konsisten dengan
  /// `rekeyDevice` di atas yang juga tidak bisa dibatalkan.
  Future<void> deleteDevice(String deviceId) async {
    final resp = await _authorizedRequest('DELETE', '/api/devices/$deviceId');
    _decodeOrThrow(resp);
    // Sama seperti `sendCommand` -- respons sukses cuma `{ok:true}` tanpa
    //   data tambahan yang perlu dikembalikan ke pemanggil.
  }
}
