// middleware/deviceAuth.js — Verifikasi tanda tangan HMAC tiap request gateway ESP32 ke /api/ingest. Harus dipasang setelah express.json() yang mengisi req.rawBody (HMAC dihitung atas byte body persis seperti dikirim). Lihat PROTOCOL.md 2.1.

const db = require('../lib/db');
const { hmacHex, safeEqualHex } = require('../lib/crypto');
const config = require('../config');

async function deviceAuth(req, res, next) {
  // Middleware Express standar; panggil next() kalau lolos, atau kirim response error & berhenti kalau gagal.
  try {
    const deviceId = req.header('X-Device-Id');
    const timestampHeader = req.header('X-Timestamp');
    const signature = req.header('X-Signature');
    // Tiga header wajib dari gateway: device_id (identitas), timestamp (anti-replay), signature (HMAC).

    if (!deviceId || !timestampHeader || !signature) {
      // Tolak lebih awal sebelum query Postgres kalau ada header yang kurang.
      return res.status(401).json({ ok: false, error: 'header_autentikasi_tidak_lengkap' });
    }

    if (typeof req.rawBody !== 'string') {
      // rawBody harus ada (diisi express.json di index.js); dicek eksplisit supaya salah config ketahuan, bukan lolos tanpa verifikasi.
      return res.status(500).json({ ok: false, error: 'server_misconfigured_rawbody' });
    }

    const timestamp = parseInt(timestampHeader, 10);
    if (!Number.isFinite(timestamp)) {
      // Timestamp harus angka valid; ditolak sebelum dipakai hitung selisih waktu.
      return res.status(401).json({ ok: false, error: 'timestamp_tidak_valid' });
    }

    const now = Date.now();
    if (Math.abs(now - timestamp) > config.requestTimestampWindowMs) {
      // Selisih ke dua arah melebihi jendela toleransi → tolak (pertahanan replay lintas waktu: signature tetap cocok tapi timestamp basi).
      return res.status(401).json({ ok: false, error: 'timestamp_di_luar_jendela_toleransi' });
    }

    const { rows } = await db.query(
      'SELECT device_id, secret, label, owner_id, last_seq, last_seen_at, next_secret, pending_commands FROM devices WHERE device_id = $1',
      [deviceId]
    );
    // Ambil device by id dari Postgres.
    if (rows.length === 0) {
      // Pesan sama untuk "device tak ada" & "signature salah" supaya penyerang tak bisa nebak device_id valid.
      return res.status(401).json({ ok: false, error: 'device_tidak_terdaftar' });
    }
    const device = rows[0];
    // device = { device_id, secret, label, owner_id, last_seq, last_seen_at, next_secret, pending_commands }.

    const signInput = `${deviceId}|${timestampHeader}|${req.rawBody}`;
    // String yang ditandatangani: device_id|timestamp|rawBody, persis sesuai PROTOCOL.md 2.1 & firmware gateway.
    const expectedWithCurrent = hmacHex(device.secret, signInput);
    // Hitung HMAC yang seharusnya memakai secret device ini.

    if (safeEqualHex(expectedWithCurrent, signature.toLowerCase())) {
      // Bandingkan (tahan timing-attack); toLowerCase() normalkan hex. Signature cocok → lanjut; simpan identitas device di req untuk route berikutnya.
      req.device = device;
      req.deviceId = deviceId;
      req.deviceRef = { id: deviceId };
      return next();
    }

    // Kalau tak cocok dengan secret saat ini, coba next_secret (masa transisi rekey). Disimpan terpisah agar ingest berikutnya yang masih pakai secret lama tak langsung gagal sebelum sempat menerima command rekey.
    if (device.next_secret) {
      // Cuma dicoba kalau memang ada rekey berjalan (biasanya NULL).
      const expectedWithNext = hmacHex(device.next_secret, signInput);
      if (safeEqualHex(expectedWithNext, signature.toLowerCase())) {
        // Signature cocok dengan secret BARU → gateway sudah menerapkan rekey. Promosikan next_secret jadi secret resmi & hapus next_secret.
        await db.query(
          'UPDATE devices SET secret = $1, next_secret = NULL WHERE device_id = $2',
          [device.next_secret, deviceId]
        );
        req.device = { ...device, secret: device.next_secret };
        // Salin device dengan secret baru supaya route berikutnya konsisten dengan DB.
        req.deviceId = deviceId;
        req.deviceRef = { id: deviceId };
        return next();
      }
    }

    return res.status(401).json({ ok: false, error: 'signature_tidak_valid' });
    // Tak cocok dengan secret lama maupun next_secret → signature benar-benar invalid.
  } catch (err) {
    return next(err);
    // Error tak terduga (Postgres down, dst) diteruskan ke errorHandler via next(err).
  }
}

module.exports = deviceAuth;
