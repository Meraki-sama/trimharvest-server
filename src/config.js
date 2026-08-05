// ============================================================================
// config.js — Pemuat & validator konfigurasi environment (.env)
// ----------------------------------------------------------------------------
// TUJUAN: memuat SEMUA environment variable di SATU tempat, lalu memvalidasi-
// nya SEBELUM server mulai menerima request. Kalau ada variabel wajib yang
// belum diisi, proses Node akan langsung "throw" saat file ini di-require
// (yaitu saat index.js start), sehingga server GAGAL START dengan pesan error
// yang jelas -- bukan gagal belakangan secara membingungkan saat ada request
// pertama masuk (mis. error null-pointer di tengah request nyasar ke user).
//
// Pola ini disebut "fail fast" -- prinsip rekayasa perangkat lunak yang baik
// untuk konfigurasi kritikal seperti secret key.
// ============================================================================

require('dotenv').config();
// ^ Membaca file .env di root folder server/ dan menyalin isinya ke
//   process.env (variabel environment proses Node ini). Kalau file .env
//   tidak ada (mis. di production yang env-nya di-inject platform hosting),
//   baris ini tidak error -- dotenv diam saja dan process.env yang sudah ada
//   dari OS/platform tetap dipakai.

function requireEnv(name) {
  // Helper: ambil satu env var WAJIB. `name` = nama variabelnya, mis. "PORT".
  const value = process.env[name];
  // ^ process.env adalah object biasa berisi semua environment variable
  //   sebagai string (walau isinya angka, tetap string "3000" misalnya).

  if (!value || value.trim() === '') {
    // Cek dobel: `!value` menangkap undefined/null/string kosong,
    // `value.trim() === ''` menangkap kasus isinya cuma spasi kosong.
    throw new Error(
      `Konfigurasi wajib "${name}" belum diisi di .env. Lihat .env.example.`
    );
    // ^ Melempar error di sini akan menghentikan `require('./config')` di
    //   index.js, sehingga `node src/index.js` langsung keluar dengan stack
    //   trace yang menyebutkan variabel mana yang kurang -- developer/operator
    //   langsung tahu apa yang harus diperbaiki tanpa harus menebak.
  }
  return value; // Kalau lolos validasi, kembalikan nilainya (masih string).
}

function requireEnvNotPlaceholder(name, placeholder) {
  // Helper tambahan KHUSUS untuk secret (JWT_ACCESS_SECRET dkk): selain wajib
  // diisi (pakai requireEnv di atas), nilainya juga TIDAK BOLEH sama dengan
  // nilai contoh/placeholder yang ada di .env.example -- ini mencegah
  // developer lupa mengganti placeholder dan tanpa sadar men-deploy server
  // dengan secret yang PUBLIK (ada di repo git, semua orang tahu nilainya).
  const value = requireEnv(name); // Tetap wajib diisi seperti biasa dulu.
  if (value === placeholder) {
    // Perbandingan string exact -- kalau developer copy-paste .env.example
    // ke .env tanpa mengubah nilainya sama sekali, ini akan ketahuan.
    throw new Error(
      `Konfigurasi "${name}" di .env masih nilai contoh ("${placeholder}") -- ganti dulu dengan nilai acak sungguhan.`
    );
  }
  return value;
}

const config = {
  // Object tunggal yang akan di-export -- SATU sumber kebenaran untuk semua
  // konfigurasi di seluruh codebase server (tidak ada file lain yang baca
  // process.env langsung, semua lewat require('./config') ini).

  port: parseInt(process.env.PORT || '8080', 10),
  // ^ PORT boleh tidak diisi (default 8080) karena di banyak platform hosting
  //   (Cloud Run, Railway, dst) port di-inject otomatis lewat env var lain
  //   atau memang fleksibel -- beda dengan secret yang WAJIB ada.
  //   `parseInt(x, 10)` = ubah string ke integer basis 10 (desimal), supaya
  //   config.port benar-benar Number, bukan string "8080".

  databaseUrl: requireEnv('DATABASE_URL'),
  // ^ Connection string PostgreSQL (Railway inject otomatis dari Postgres
  //   add-on, atau isi di .env lokal). WAJIB diisi karena tanpa ini server
  //   tidak bisa terhubung ke database sama sekali.

  jwtAccessSecret: requireEnvNotPlaceholder(
    'JWT_ACCESS_SECRET',
    'GANTI-DENGAN-STRING-ACAK-PANJANG'
  ),
  // ^ Kunci rahasia untuk menandatangani access token (JWT) operator app.
  //   Dicek dobel: wajib ada DAN bukan placeholder contoh.

  jwtRefreshSecret: requireEnvNotPlaceholder(
    'JWT_REFRESH_SECRET',
    'GANTI-DENGAN-STRING-ACAK-PANJANG-BERBEDA'
  ),
  // ^ Kunci rahasia terpisah untuk refresh token -- SENGAJA beda dari
  //   access secret supaya kebocoran satu token type tidak otomatis
  //   membocorkan kemampuan memalsukan token type lainnya.

  jwtAccessTtl: process.env.JWT_ACCESS_TTL || '15m',
  // ^ Masa berlaku access token, default 15 menit kalau tidak diisi di .env.
  //   Format string ini mengikuti library `ms` yang dipakai oleh
  //   jsonwebtoken (mis. "15m", "1h", "30d").

  jwtRefreshTtl: process.env.JWT_REFRESH_TTL || '30d',
  // ^ Masa berlaku refresh token, jauh lebih panjang (30 hari) karena token
  //   ini cuma dipakai untuk MEMINTA access token baru, bukan untuk akses
  //   langsung ke data -- lihat routes/auth.js POST /refresh.

  requestTimestampWindowMs: parseInt(
    process.env.REQUEST_TIMESTAMP_WINDOW_MS || '120000',
    10
  ),
  // ^ Toleransi selisih waktu (dalam milidetik) untuk request bertanda
  //   tangan HMAC dari gateway ESP32 -- default 120000 ms = 120 detik.
  //   Dipakai di middleware/deviceAuth.js untuk menolak request yang
  //   timestamp-nya terlalu jauh dari waktu server sekarang (mencegah
  //   serangan replay lintas waktu).

  readingsTtlDays: parseInt(process.env.READINGS_TTL_DAYS || '90', 10),
  // ^ Masa retensi data sensor (hari) sebelum otomatis dihapus. Default 90
  //   hari cukup untuk grafik tren sawah/rumah tanpa membuat tabel
  //   `readings` membengkak tak terbatas (tiap ingest = 1 baris baru).
  //   Lihat catatan di routes/ingest.js: field `expireAt` (TIMESTAMPTZ)
  //   ditulis per baris, TAPI penghapusan otomatis BELUM dijalankan oleh
  //   job cleanup apa pun di migrasi ini -- data hanya ditandai, tidak
  //   dihapus otomatis. Atur 0 (nol) kalau mau menyimpan selamanya
  //   (TIDAK merekomendasikan untuk produksi jangka panjang karena biaya
  //   & latensi query naik).

  allowedOrigins: process.env.ALLOWED_ORIGINS || '',
  // ^ Daftar origin browser yang diizinkan akses API (dipisah koma), untuk
  //   CORS. Contoh: "https://app.trimharvest.id,https://web.trimharvest.id".
  //   Kosong = izinkan semua (hanya untuk development); PRODUCTION WAJIB
  //   diisi supaya API tidak bisa dipanggil dari web origin asing. App
  //   Flutter mobile (tanpa header Origin) tetap lolos karena CORS hanya
  //   berlaku di browser.
};

if (config.jwtAccessSecret === config.jwtRefreshSecret) {
  // Validasi TAMBAHAN di luar requireEnvNotPlaceholder: walau dua-duanya
  // sudah bukan placeholder masing-masing, developer masih bisa saja
  // (tidak sengaja) mengisi NILAI YANG SAMA untuk keduanya -- itu tetap
  // salah secara desain keamanan (lihat komentar jwtRefreshSecret di atas),
  // jadi dicek eksplisit di sini sebagai lapisan validasi kedua.
  throw new Error(
    'JWT_ACCESS_SECRET dan JWT_REFRESH_SECRET tidak boleh sama -- ganti salah satunya di .env.'
  );
}

module.exports = config;
// ^ Export object config yang sudah divalidasi -- semua file lain di server
//   ini (index.js, middleware/*, routes/*) memanggil require('../config')
//   atau require('./config') untuk mengakses nilai-nilai ini, TIDAK PERNAH
//   membaca process.env langsung -- ini menjamin validasi di atas SELALU
//   dijalankan lebih dulu sebelum nilai konfigurasi dipakai di mana pun.
