import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Satu-satunya tempat di app ini yang menyentuh flutter_secure_storage --
// lihat /PROTOCOL.md bagian 3: token akses/refresh & URL server disimpan
// aman di penyimpanan native (Keychain di iOS, Keystore-backed EncryptedSharedPreferences
// di Android), BUKAN shared_preferences biasa yang tidak terenkripsi.
class SecureStorageService {
  SecureStorageService._();
  // Constructor PRIVAT (nama diawali underscore) -- TIDAK BISA dipanggil
  //   dari luar file/library ini, memaksa SEMUA kode lain memakai
  //   `SecureStorageService.instance` di bawah, BUKAN membuat instance
  //   baru sendiri.
  static final SecureStorageService instance = SecureStorageService._();
  // Pola SINGLETON: HANYA ADA SATU instance kelas ini di seluruh
  //   aplikasi, dibuat SEKALI (lazy, saat pertama kali diakses) & dipakai
  //   bersama oleh semua bagian app -- masuk akal untuk akses
  //   penyimpanan aman (tidak ada alasan punya banyak instance yang
  //   semuanya menunjuk ke storage native yang SAMA).

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    // Opsi KHUSUS ANDROID: memaksa memakai `EncryptedSharedPreferences`
    //   (API resmi Android Jetpack Security, didukung Android Keystore
    //   hardware-backed di banyak device) -- tanpa opsi ini, plugin bisa
    //   memilih fallback yang keamanannya lebih lemah di beberapa versi
    //   Android lama. Di iOS, flutter_secure_storage OTOMATIS memakai
    //   Keychain (tidak butuh opsi tambahan seperti ini).
  );

  static const _keyAccessToken = 'access_token';
  static const _keyRefreshToken = 'refresh_token';
  static const _keyServerBaseUrl = 'server_base_url';
  // Konstanta nama key -- disentralisasi di sini (bukan string literal
  //   berulang di banyak tempat) supaya kalau nama key perlu diubah,
  //   cukup diubah di SATU tempat, & mengurangi risiko salah ketik nama
  //   key antar pemanggilan.

  Future<void> saveTokens({required String accessToken, required String refreshToken}) async {
    await _storage.write(key: _keyAccessToken, value: accessToken);
    await _storage.write(key: _keyRefreshToken, value: refreshToken);
    // Dipanggil SETELAH login berhasil (lihat login_screen.dart) --
    //   menyimpan SEPASANG token sekaligus.
  }

  Future<void> saveAccessToken(String accessToken) async {
    await _storage.write(key: _keyAccessToken, value: accessToken);
    // Method TERPISAH untuk menyimpan HANYA access token -- dipakai
    //   saat access token DIPERBARUI lewat endpoint /api/auth/refresh
    //   (yang HANYA menerbitkan access token baru, TIDAK refresh token
    //   baru, lihat server/src/routes/auth.js), jadi tidak perlu
    //   menyentuh refresh token yang tersimpan sama sekali.
  }

  Future<String?> readAccessToken() => _storage.read(key: _keyAccessToken);
  Future<String?> readRefreshToken() => _storage.read(key: _keyRefreshToken);
  // Sintaks "arrow function" (`=>`) untuk method satu baris -- gula
  //   sintaksis Dart, setara dengan `{ return _storage.read(...); }`.
  //   Mengembalikan `Future<String?>` -- null kalau key belum pernah
  //   diisi/tidak ada (mis. pengguna belum pernah login).

  Future<void> clearTokens() async {
    await _storage.delete(key: _keyAccessToken);
    await _storage.delete(key: _keyRefreshToken);
    // Dipanggil saat LOGOUT -- menghapus KEDUA token sekaligus dari
    //   penyimpanan aman, memastikan tidak ada sisa kredensial yang
    //   masih bisa dipakai setelah pengguna logout.
  }

  Future<void> saveServerBaseUrl(String url) => _storage.write(key: _keyServerBaseUrl, value: url);
  Future<String?> readServerBaseUrl() => _storage.read(key: _keyServerBaseUrl);
  // URL server JUGA disimpan lewat secure storage (bukan
  //   shared_preferences biasa seperti tema di theme_controller.dart) --
  //   walau URL server BUKAN rahasia dalam arti kriptografis, konsisten
  //   disimpan di sini karena SATU KESATUAN dengan sesi login (kalau app
  //   di-reset/uninstall, sebaiknya URL server & token ikut hilang
  //   bersamaan, bukan tema yang boleh tetap tersimpan terpisah).

  // --- Threshold (angka patokan) per sensor, disimpan lokal ---
  // Kunci dibuat pemanggil (format "$deviceId::$readingId") supaya tiap
  // sensor tiap device punya patokan sendiri.
  Future<void> saveThreshold(String key, double value) =>
      _storage.write(key: 'threshold_$key', value: value.toString());
  Future<double?> readThreshold(String key) async {
    final raw = await _storage.read(key: 'threshold_$key');
    if (raw == null) return null;
    return double.tryParse(raw);
  }

  Future<void> removeThreshold(String key) => _storage.delete(key: 'threshold_$key');
}
