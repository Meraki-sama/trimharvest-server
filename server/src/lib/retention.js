// lib/retention.js — Pembersih berkala baris readings yang lewat masa simpan (expire_at). Postgres tak punya TTL otomatis, jadi tanpa job ini tabel tumbuh tak terbatas; job ini hapus tiap 6 jam secara batch.

const db = require('./db');
const logger = require('./logger');

// Batasi per putaran agar satu DELETE raksasa tak mengunci tabel lama & menghambat ingest.
const DELETE_BATCH = 5000;

async function purgeExpiredReadings() {
  // expire_at IS NOT NULL penting: kalau TTL=0, ingest menulis NULL → baris itu tak boleh terhapus.
  const { rowCount } = await db.query(
    `DELETE FROM readings WHERE id IN (
       SELECT id FROM readings
       WHERE expire_at IS NOT NULL AND expire_at < now()
       LIMIT $1
     )`,
    [DELETE_BATCH]
  );
  if (rowCount > 0) {
    logger.info({ deleted: rowCount }, 'retensi: baris readings kedaluwarsa dihapus');
  }
  return rowCount;
}

// Jalankan sekali saat start (bersihkan tunggakan), lalu ulangi tiap interval.
function startRetentionJob(intervalMs = 6 * 60 * 60 * 1000) {
  const runSafely = async () => {
    try {
      await purgeExpiredReadings();
    } catch (err) {
      // Kegagalan pembersihan tak boleh menjatuhkan server (tugas latar, bukan jalur request).
      logger.error({ err: err.message }, 'retensi: gagal menghapus readings kedaluwarsa');
    }
  };

  runSafely();
  const timer = setInterval(runSafely, intervalMs);
  timer.unref();
  // unref() agar timer tak menahan proses tetap hidup saat shutdown (SIGTERM).
  return timer;
}

module.exports = { purgeExpiredReadings, startRetentionJob, DELETE_BATCH };
