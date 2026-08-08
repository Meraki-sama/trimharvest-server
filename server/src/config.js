// config.js — Memuat & memvalidasi env (.env) di satu tempat; gagal start (fail-fast) kalau ada variabel wajib kosong/placeholder.

require('dotenv').config();
// Baca .env ke process.env; kalau tidak ada (production), env dari OS tetap dipakai.

function requireEnv(name) {
  // Ambil env var wajib; lempar error kalau kosong (Node keluar saat require).
  const value = process.env[name];
  // process.env berisi semua env var sebagai string.

  if (!value || value.trim() === '') {
    // Tangkap undefined, null, maupun string spasi-saja.
    throw new Error(
      `Konfigurasi wajib "${name}" belum diisi di .env. Lihat .env.example.`
    );
    // Error di sini menghentikan require('./config') → server gagal start dengan pesan jelas.
  }
  return value; // Nilai kembalian (masih bertipe string).
}

function requireEnvNotPlaceholder(name, placeholder) {
  // Sama seperti di atas, tapi juga tolak nilai placeholder contoh agar secret tak ter-deploy publik.
  const value = requireEnv(name); // Tetap wajib diisi.
  if (value === placeholder) {
    // Copy-paste .env.example tanpa diubah akan ketahuan di sini.
    throw new Error(
      `Konfigurasi "${name}" di .env masih nilai contoh ("${placeholder}") -- ganti dulu dengan nilai acak sungguhan.`
    );
  }
  return value;
}

const config = {
  // Satu sumber kebenaran konfigurasi; semua modul require('./config'), tak ada yang baca process.env langsung.

  port: parseInt(process.env.PORT || '8080', 10),
  // Default 8080 (banyak PaaS inject port sendiri); parseInt → Number, bukan string.

  databaseUrl: requireEnv('DATABASE_URL'),
  // Connection string Postgres; wajib, server tak bisa terhubung tanpa ini.

  jwtAccessSecret: requireEnvNotPlaceholder(
    'JWT_ACCESS_SECRET',
    'GANTI-DENGAN-STRING-ACAK-PANJANG'
  ),
  // Kunci tanda tangan access token; wajib & bukan placeholder.

  jwtRefreshSecret: requireEnvNotPlaceholder(
    'JWT_REFRESH_SECRET',
    'GANTI-DENGAN-STRING-ACAK-PANJANG-BERBEDA'
  ),
  // Kunci refresh token SENGaja beda dari access → kebocoran satu tak memvalidkan yang lain.

  jwtAccessTtl: process.env.JWT_ACCESS_TTL || '15m',
  // Masa berlaku access token (default 15m), format library 'ms'.

  jwtRefreshTtl: process.env.JWT_REFRESH_TTL || '30d',
  // Refresh token tahan lama (30 hari); hanya untuk minta access token baru, bukan akses langung.

  requestTimestampWindowMs: parseInt(
    process.env.REQUEST_TIMESTAMP_WINDOW_MS || '120000',
    10
  ),
  // Toleransi waktu request HMAC gateway (default 120 s) untuk menolak replay lintas waktu.

  readingsTtlDays: parseInt(process.env.READINGS_TTL_DAYS || '90', 10),
  // Retensi data sensor (default 90 hari); 0 = simpan selamanya (tidak disarankan untuk produksi).

  allowedOrigins: process.env.ALLOWED_ORIGINS || '',
  // Origin browser yang diizinkan (koma). Kosong → web asing ditolak, app mobile (tanpa Origin) lolos.
};

if (config.jwtAccessSecret === config.jwtRefreshSecret) {
  // Jaga agar kedua secret tak sengaja sama (celah desain keamanan).
  throw new Error(
    'JWT_ACCESS_SECRET dan JWT_REFRESH_SECRET tidak boleh sama -- ganti salah satunya di .env.'
  );
}

module.exports = config;
// Export config tervalidasi; semua modul require ini, jamin validasi selalu jalan duluan.
