// ============================================================================
// routes/ingest.js — POST /api/ingest, satu-satunya endpoint yang dipanggil
// gateway ESP32, lihat /PROTOCOL.md bagian 2. deviceAuth (dipasang di
// index.js SEBELUM route ini) sudah memverifikasi HMAC & mengisi
// req.device/req.deviceId/req.deviceRef -- route ini TIDAK PERLU (dan tidak
// boleh) memverifikasi identitas lagi, cukup fokus ke LOGIKA BISNIS-nya.
// ============================================================================
const express = require('express');
const config = require('../config');
const db = require('../lib/db');
// ^ Memuat config (diperlukan untuk `config.readingsTtlDays` di bawah,
//   yaitu masa retensi TTL field `expireAt` per dokumen readings).
const router = express.Router();

router.post('/', async (req, res, next) => {
  // ^ Menangani POST /api/ingest (path kosong '/' di sini + prefix
  //   '/api/ingest' dari index.js = POST /api/ingest).
  try {
    const body = req.body || {};
    // ^ Fallback ke object kosong kalau body somehow kosong/undefined,
    //   supaya destructuring di bawah tidak error.
    const { type, seq } = body;
    // ^ Ambil dua field wajib dari body: `type` ("sensor"/"heartbeat") dan
    //   `seq` (nomor urut anti-replay lapis HTTP, lihat /PROTOCOL.md 2.1).

    if (type !== 'sensor' && type !== 'heartbeat') {
      // Validasi input dasar -- hanya dua jenis body yang didukung protokol
      // ini (lihat /PROTOCOL.md bagian 2.2).
      return res.status(400).json({ ok: false, error: 'type_harus_sensor_atau_heartbeat' });
    }
    if (typeof seq !== 'number' || !Number.isFinite(seq)) {
      // `seq` wajib angka valid (bukan string, bukan NaN/Infinity) supaya
      // perbandingan `seq <= lastSeq` di bawah bermakna secara matematis.
      return res.status(400).json({ ok: false, error: 'seq_wajib_berupa_angka' });
    }

    const device = req.device;
    // ^ Diisi oleh middleware/deviceAuth.js -- data dokumen Postgres
    //   devices/{deviceId} yang sudah divalidasi HMAC-nya.
    const lastSeq = typeof device.lastSeq === 'number' ? device.lastSeq : 0;
    // ^ Ambil seq terakhir yang tercatat di Postgres untuk device ini,
    //   default 0 kalau field-nya belum ada (device baru pertama kali
    //   ingest).
    if (seq <= lastSeq) {
      // Anti-replay lapis kedua (lihat /PROTOCOL.md 2.1) -- request lama
      // atau diputar ulang, ditolak diam-diam (bukan error server, dari
      // sudut pandang server ini "sah tapi basi").
      return res.status(409).json({ ok: false, error: 'seq_replay_atau_kadaluwarsa' });
      // ^ 409 Conflict -- kode status yang tepat secara semantik HTTP untuk
      //   "request valid tapi bertentangan dengan state server saat ini".
    }

    const nowIso = new Date().toISOString();
    // ^ Timestamp SERVER (bukan timestamp yang diklaim gateway di header
    //   X-Timestamp) -- dipakai untuk kolom `ts`/`lastSeenAt`, supaya waktu
    //   yang tercatat konsisten dengan jam server, bukan jam device yang
    //   bisa saja melenceng (walau sudah dicek toleransinya di deviceAuth).
    const pendingCommands = Array.isArray(device.pendingCommands) ? device.pendingCommands : [];
    // ^ Ambil salinan daftar command yang sedang MENUNGGU dikirim ke device
    //   ini (diisi lewat POST /api/devices/:id/commands dari app Flutter) --
    //   akan dibalikan sebagai bagian dari response supaya gateway langsung
    //   tahu ada perintah baru begitu ia selesai mengirim data sensor.

    // Update device doc: catat seq/waktu terakhir, DAN kosongkan
    // pendingCommands (sudah kita ambil salinannya di atas untuk dibalikan
    // sebagai respons). Trade-off yang disadari: kalau respons HTTP ini
    // gagal sampai ke gateway (mis. WiFi putus persis setelah server
    // membalas), command yang sudah dikosongkan di sini akan "hilang" satu
    // siklus -- diterima lagi hanya kalau app mengantre ulang. Untuk skala
    // proyek ini (1 gateway per rumah/sawah, command berupa hal yang aman
    // diulang seperti set_interval/restart) trade-off ini dianggap wajar
    // dibanding kompleksitas mekanisme ack terpisah.
    // PERBAIKAN RACE CONDITION (#13): dua ingest berurutan dari gateway
    // yang sampai BERSAMAAN bisa memicu update last_seq saling tabrak.
    // Pakai UPDATE kondisional (hanya naikkan kalau seq benar-benar lebih
    // besar) dalam SATU query, dan cek rowCount-nya. Kalau 0 baris
    // terupdate, berarti seq tidak melebihi lastSeq saat ini (request
    // duplikat/replay nyaris-bersamaan) -> kita tetap lanjutkan (data sudah
    // valid, command tetap dibalikan) tapi tidak menimpa state mundur.
    const updateResult = await db.query(
      'UPDATE devices SET last_seq = $1, last_seen_at = $2, pending_commands = $3 ' +
      'WHERE device_id = $4 AND last_seq < $1',
      [seq, nowIso, '[]', req.deviceId]
    );
    // ^ `AND last_seq < $1` menjamin last_seq MONOTON NAIK bahkan kalau dua
    //   request masuk berbarengan: hanya request dengan seq terbesar yang
    //   menang, request ganda tidak akan menurunkan nilai (menutup celah
    //   replay lewat race). rowCount (updateResult.rowCount) = 0 berarti
    //   update dilewati karena seq tidak lebih besar -- bukan error.

    if (type === 'sensor') {
      const readings = Array.isArray(body.readings) ? body.readings : [];
      // ^ Array pembacaan sensor, format [{id, value, unit}, ...] (lihat
      //   /PROTOCOL.md 2.2) -- fallback ke array kosong kalau field ini
      //   somehow bukan array (mis. gateway mengirim heartbeat tapi salah
      //   set `type`), supaya tidak error saat disimpan.

      // Field `expireAt` untuk retensi otomatis readings -- supaya tabel
      // `readings` TIDAK membengkak tak terbatas (tiap ingest = 1 baris baru).
      // Dihitung dari config.readingsTtlDays: sekarang + N hari. Kalau
      // readingsTtlDays == 0, kita TIDAK menulis expireAt sama sekali
      // (retensi tak terbatas, seperti perilaku lama).
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
      // ^ Simpan sebagai BARIS BARU di tabel readings (bukan menimpa) --
      //   ini yang membentuk HISTORI data untuk grafik di app.
    }
    // type === 'heartbeat': sengaja TIDAK membuat dokumen di sub-koleksi
    // readings (heartbeat cuma pembaruan status "masih hidup", bukan data
    // yang perlu masuk histori grafik) -- lastSeenAt di atas sudah cukup.

    return res.json({ ok: true, commands: pendingCommands });
    // ^ Response ke gateway berisi daftar command yang harus dieksekusi
    //   (kosong kalau memang tidak ada command menunggu) -- gateway
    //   membaca field `commands` ini dan meneruskan yang relevan ke node
    //   sawah lewat LoRa (lihat gateway-rumah/src/main.cpp).
  } catch (err) {
    return next(err);
    // ^ Error tak terduga (mis. Postgres error) diteruskan ke error
    //   handler terpusat (middleware/errorHandler.js).
  }
});

module.exports = router;
