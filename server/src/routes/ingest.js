// routes/ingest.js — POST /api/ingest, satu-satunya endpoint gateway ESP32. deviceAuth (index.js) sudah verifikasi HMAC & isi req.device/req.deviceId; route ini hanya logika bisnis. Lihat PROTOCOL.md 2.
const express = require('express');
const config = require('../config'); // Diperlukan untuk readingsTtlDays (retensi readings).
const db = require('../lib/db');
const router = express.Router();

router.post('/', async (req, res, next) => {
  // POST /api/ingest (prefix index.js + path kosong).
  try {
    const body = req.body || {};
    // Fallback object kosong kalau body undefined, agar destructuring tak error.
    const { type, seq } = body;
    // Field wajib: type (sensor/heartbeat) & seq (anti-replay lapis HTTP).

    if (type !== 'sensor' && type !== 'heartbeat') {
      // Hanya dua jenis body yang didukung protokol.
      return res.status(400).json({ ok: false, error: 'type_harus_sensor_atau_heartbeat' });
    }
    if (typeof seq !== 'number' || !Number.isFinite(seq)) {
      // seq wajib angka valid agar perbandingan anti-replay bermakna.
      return res.status(400).json({ ok: false, error: 'seq_wajib_berupa_angka' });
    }

    const device = req.device;
    // Diisi deviceAuth; dokumen device yang sudah tervalidasi HMAC.
    // BUG FIX: pg mengembalikan kolom snake_case (last_seq), bukan lastSeq. Kode lama baca undefined → cek anti-replay mati.
    const lastSeq = typeof device.last_seq === 'number' ? device.last_seq : 0;
    // Ambil seq terakhir di Postgres; default 0 untuk device baru.
    if (seq <= lastSeq) {
      // Anti-replay lapis kedua: request lama/diputar ulang ditolak diam-diam (409 = valid tapi bertentangan state).
      return res.status(409).json({ ok: false, error: 'seq_replay_atau_kadaluwarsa' });
    }

    const nowIso = new Date().toISOString();
    // Pakai timestamp SERVER (bukan klaim gateway) agar waktu konsisten walau jam device melenceng.
    // BUG FIX: kolom Postgres bernama pending_commands (snake_case), bukan pendingCommands. Kode lama selalu undefined → perintah app tak sampai gateway.
    const rawPending = typeof device.pending_commands === 'string'
      ? JSON.parse(device.pending_commands)
      : device.pending_commands;
    const pendingCommands = Array.isArray(rawPending) ? rawPending : [];
    // Ambil salinan command yang menunggu (dari app) untuk dibalikan ke gateway sebagai respons.

    // Kosongkan pending_commands & catat seq/waktu. Trade-off: kalau respons gagal sampai, command hilang 1 siklus (diterima lagi kalau app antre ulang) — wajar untuk 1 gateway/rumah.
    // RACE FIX: UPDATE kondisional (last_seq < $1) jaga seq MONOTON NAIK walau dua ingest bersamaan; rowCount 0 = duplikat/replay, bukan error.
    const updateResult = await db.query(
      'UPDATE devices SET last_seq = $1, last_seen_at = $2, pending_commands = $3 ' +
      'WHERE device_id = $4 AND last_seq < $1',
      [seq, nowIso, '[]', req.deviceId]
    );

    // Capture flag gateway power-save (gpsv:1/0) dari heartbeat → badge "HEMAT GW" di app.
    if (typeof body.gpsv === 'number') {
      await db.query(
        'UPDATE devices SET gateway_power_save = $1 WHERE device_id = $2',
        [body.gpsv === 1, req.deviceId]
      );
    }

    if (type === 'sensor') {
      const readings = Array.isArray(body.readings) ? body.readings : [];
      // Array pembacaan sensor [{id,value,unit}]; fallback kosong kalau bukan array.
      // Capture flag node power-save (psv:1/0) → badge "HEMAT" tanpa colok USB ke node.
      if (typeof body.psv === 'number') {
        await db.query(
          'UPDATE devices SET node_power_save = $1 WHERE device_id = $2',
          [body.psv === 1, req.deviceId]
        );
      }

      // expire_at = sekarang + N hari (retensi); kalau TTL=0, tak ditulis (simpan selamanya).
      const expireAt =
        config.readingsTtlDays > 0
          ? new Date(Date.now() + config.readingsTtlDays * 24 * 60 * 60 * 1000)
          : null;

      await db.query(
        `INSERT INTO readings (device_id, ts, type, node_msg_type, readings, seq, expire_at)
         VALUES ($1, $2, 'sensor', $3, $4, $5, $6)`,
        [
          req.deviceId,
          nowIso,
          body.node_msg_type || 'core',
          JSON.stringify(readings),
          seq,
          expireAt,
        ]
      );
      // Simpan sebagai BARIS BARU di readings (bukan timpa) → membentuk histori grafik.
    }
    // heartbeat: tak buat readings (status "masih hidup" cukup di last_seen_at).

    return res.json({ ok: true, commands: pendingCommands });
    // Balikan ke gateway berisi command yang harus dieksekusi (kosong kalau tak ada).
  } catch (err) {
    return next(err);
    // Error tak terduga diteruskan ke errorHandler.
  }
});

module.exports = router;
