// middleware/errorHandler.js — Error handler terpusat. Semua route pakai next(err) untuk error tak terduga, agar tercatat rapi & tak pernah bocorkan detail internal ke klien.
// eslint-disable-next-line no-unused-vars
function errorHandler(err, req, res, next) {
  const logger = require('../lib/logger');
  logger.error({ err: err.message, stack: err.stack }, `[error] ${req.method} ${req.originalUrl}`);
  // Catat error lengkap (termasuk stack) ke log server untuk debugging, BUKAN ke klien.
  if (res.headersSent) return;
  // Kalau response sudah mulai dikirim, jangan kirim lagi (cegah error "headers already sent").
  res.status(500).json({ ok: false, error: 'internal_server_error' });
  // Klien cuma dapat pesan generik; jangan bocorkan detail internal (DB, library, query).
}

module.exports = errorHandler;
