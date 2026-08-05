// ============================================================================
// middleware/errorHandler.js — Error handler terpusat Express.
// SEMUA route memakai pola `catch (err) { return next(err); }` untuk error
// tak terduga (lihat routes/*.js), supaya errornya selalu tercatat di log
// server dengan format konsisten dan TIDAK PERNAH membocorkan detail
// internal (stack trace, pesan error database, dst) ke klien (gateway/app).
// ============================================================================

// eslint-disable-next-line no-unused-vars
// ^ Komentar khusus untuk linter ESLint: parameter `next` di bawah memang
//   TIDAK DIPAKAI di dalam function ini, tapi TETAP HARUS ada di signature-
//   nya -- Express mengenali suatu middleware sebagai "error handler"
//   SECARA KHUSUS lewat jumlah parameternya (harus PERSIS 4: err, req, res,
//   next), bukan lewat cara lain. Kalau `next` dihapus, Express akan
//   menganggap ini middleware biasa (bukan error handler) dan tidak akan
//   pernah memanggilnya saat ada error.
function errorHandler(err, req, res, next) {
  const logger = require('../lib/logger');
  logger.error({ err: err.message, stack: err.stack }, `[error] ${req.method} ${req.originalUrl}`);
  // ^ Catat error LENGKAP (termasuk stack trace) ke log server (stdout/
  //   stderr, biasanya ditangkap oleh platform hosting seperti Railway/
  //   Render) -- ini yang dipakai developer/operator untuk debugging,
  //   BUKAN yang dikirim balik ke klien.
  if (res.headersSent) return;
  // ^ Kalau response SUDAH mulai dikirim sebelum error ini terjadi (jarang,
  //   tapi bisa terjadi pada kasus streaming/response parsial), memanggil
  //   res.status().json() lagi akan melempar error BARU ("Cannot set
  //   headers after they are sent") -- dicegah dengan early return di sini.
  res.status(500).json({ ok: false, error: 'internal_server_error' });
  // ^ Klien (gateway ESP32 / app Flutter) hanya menerima pesan generik ini,
  //   TANPA detail apa pun tentang error aslinya -- prinsip keamanan: jangan
  //   membocorkan informasi internal (struktur database, versi library,
  //   query yang gagal, dst) lewat pesan error ke pihak luar.
}

module.exports = errorHandler;
