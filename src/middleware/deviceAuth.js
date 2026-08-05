// ============================================================================
// middleware/deviceAuth.js — Middleware Express yang memverifikasi tanda
// tangan HMAC pada setiap request dari gateway ESP32 ke /api/ingest.
// Lihat /PROTOCOL.md bagian 2.1 untuk skema lengkap. HARUS dipasang SETELAH
// middleware express.json() yang mengisi req.rawBody (lihat index.js) karena
// HMAC dihitung atas BYTE BODY PERSIS seperti yang dikirim, bukan hasil
// re-serialize req.body (urutan key JSON hasil re-serialize bisa berbeda
// dari aslinya dan akan membuat signature selalu gagal cocok).
// ============================================================================

const db = require('../lib/db');
const { hmacHex, safeEqualHex } = require('../lib/crypto');
const config = require('../config');

async function deviceAuth(req, res, next) {
  // Middleware Express standar: (req, res, next) -- kalau otentikasi
  // berhasil, panggil next() supaya request diteruskan ke route handler
  // berikutnya (routes/ingest.js); kalau gagal, langsung kirim response
  // error di sini dan TIDAK memanggil next() (request berhenti di sini).
  try {
    const deviceId = req.header('X-Device-Id');
    const timestampHeader = req.header('X-Timestamp');
    const signature = req.header('X-Signature');
    // ^ Tiga header wajib yang dikirim gateway (lihat http_client.cpp di
    //   firmware gateway-rumah) -- device_id (identitas), timestamp (waktu
    //   pembuatan request, untuk anti-replay), dan signature (HMAC-nya).

    if (!deviceId || !timestampHeader || !signature) {
      // Kalau salah satu header tidak ada sama sekali, tolak lebih awal
      // sebelum melakukan pekerjaan lain yang lebih mahal (query Postgres).
      return res.status(401).json({ ok: false, error: 'header_autentikasi_tidak_lengkap' });
    }

    if (typeof req.rawBody !== 'string') {
      // Seharusnya tidak pernah terjadi kalau middleware express.json()
      // sudah dipasang dengan benar di index.js -- dicek eksplisit di sini
      // supaya kegagalan konfigurasi ketahuan cepat (500, bukan diam-diam
      // lolos tanpa verifikasi signature sama sekali, yang jauh lebih
      // berbahaya).
      return res.status(500).json({ ok: false, error: 'server_misconfigured_rawbody' });
    }

    const timestamp = parseInt(timestampHeader, 10);
    if (!Number.isFinite(timestamp)) {
      // Header timestamp harus berupa angka yang valid (bukan NaN, bukan
      // Infinity) -- kalau gateway (atau penyerang) mengirim nilai aneh,
      // ditolak di sini sebelum dipakai dalam perhitungan selisih waktu.
      return res.status(401).json({ ok: false, error: 'timestamp_tidak_valid' });
    }

    const now = Date.now();
    if (Math.abs(now - timestamp) > config.requestTimestampWindowMs) {
      // Bandingkan waktu SEKARANG (di server) dengan timestamp yang diklaim
      // gateway -- kalau selisihnya (ke arah manapun, makanya pakai Math.abs)
      // melebihi jendela toleransi (default 120 detik, lihat config.js),
      // request ditolak. Ini pertahanan terhadap serangan REPLAY: kalau
      // penyerang merekam request lama yang valid lalu mengirim ulang jauh
      // di kemudian hari, signature-nya memang masih cocok (HMAC tidak
      // berubah), tapi timestamp yang sudah basi akan menggagalkan cek ini.
      return res.status(401).json({ ok: false, error: 'timestamp_di_luar_jendela_toleransi' });
    }

    const { rows } = await db.query(
      'SELECT device_id, secret, label, owner_id, last_seq, last_seen_at, next_secret, pending_commands FROM devices WHERE device_id = $1',
      [deviceId]
    );
    // ^ Query device by id -- network call sungguhan ke Postgres.
    if (rows.length === 0) {
      // Device_id yang diklaim di header TIDAK terdaftar sama sekali di
      // database -- tolak. Pesan errornya SAMA untuk "device tidak ada" dan
      // tidak dibedakan dari kasus signature salah di bawah, supaya penyerang
      // tidak gampang membedakan device_id mana yang valid.
      return res.status(401).json({ ok: false, error: 'device_tidak_terdaftar' });
    }
    const device = rows[0];
    // ^ Object biasa: { device_id, secret, label, owner_id, last_seq,
    //   last_seen_at, next_secret, pending_commands }

    const signInput = `${deviceId}|${timestampHeader}|${req.rawBody}`;
    // ^ String yang DITANDATANGANI, disusun PERSIS sesuai spesifikasi di
    //   /PROTOCOL.md 2.1: device_id + "|" + timestamp + "|" + rawBody.
    //   Urutan & pemisah ini HARUS identik dengan yang dihitung firmware
    //   gateway (http_client.cpp) -- kalau beda satu karakter saja, HMAC
    //   yang dihasilkan pasti berbeda total (properti avalanche effect HMAC).
    const expectedWithCurrent = hmacHex(device.secret, signInput);
    // ^ Hitung HMAC yang SEHARUSNYA, memakai secret yang tersimpan di
    //   Postgres untuk device ini (device.secret) sebagai kunci.

    if (safeEqualHex(expectedWithCurrent, signature.toLowerCase())) {
      // ^ Bandingkan hasil hitungan server dengan signature yang dikirim
      //   gateway, memakai perbandingan tahan timing-attack (lihat
      //   lib/crypto.js). `.toLowerCase()` menormalkan huruf besar/kecil
      //   hex (mis. gateway mungkin kirim huruf besar, server hitung huruf
      //   kecil -- keduanya representasi hex yang sama secara nilai).
      req.device = device;       // Simpan data device di req supaya bisa
      req.deviceId = deviceId;   // dipakai route handler berikutnya
      req.deviceRef = { id: deviceId }; // (routes/ingest.js) tanpa query ulang.
      return next(); // Signature COCOK dengan secret saat ini -> lanjut.
    }

    // Kalau tidak cocok dengan secret SAAT INI, coba `nextSecret` -- field
    // ini hanya terisi selama masa transisi rekey (lihat routes/devices.js
    // POST /:id/rekey). Ini MENCEGAH DEADLOCK: kalau kita langsung
    // menimpa `secret` saat rekey diminta, request ingest gateway
    // BERIKUTNYA (yang masih memakai secret LAMA, karena belum sempat
    // menerima & menerapkan command rekey) akan langsung gagal autentikasi
    // -- padahal request itu justru yang seharusnya MENGANTARKAN command
    // rekey ke gateway lewat responsnya. Dengan menyimpan secret baru
    // sebagai `nextSecret` (bukan langsung menimpa `secret`), secret LAMA
    // tetap sah dipakai sampai gateway benar-benar berhasil beralih --
    // begitu request pertama datang memakai `nextSecret` (tandanya gateway
    // sudah restart dengan secret baru), server MEMPROMOSIKANNYA jadi
    // `secret` resmi & menghapus `nextSecret`, menyelesaikan rotasi.
    if (device.next_secret) {
      // ^ Cuma dicoba kalau memang ada rekey yang sedang berjalan (field ini
      //   biasanya NULL pada device normal).
      const expectedWithNext = hmacHex(device.next_secret, signInput);
      if (safeEqualHex(expectedWithNext, signature.toLowerCase())) {
        // Signature ternyata cocok dengan SECRET BARU -> gateway sudah
        // menerapkan command rekey. Promosikan nextSecret jadi secret resmi:
        await db.query(
          'UPDATE devices SET secret = $1, next_secret = NULL WHERE device_id = $2',
          [device.next_secret, deviceId]
        );
        req.device = { ...device, secret: device.next_secret };
        // ^ Salin object device tapi timpa field `secret` dengan yang baru,
        //   supaya route handler berikutnya (ingest.js) melihat state yang
        //   sudah konsisten dengan yang baru saja ditulis ke database.
        req.deviceId = deviceId;
        req.deviceRef = { id: deviceId };
        return next(); // Rekey selesai, request tetap diproses seperti biasa.
      }
    }

    return res.status(401).json({ ok: false, error: 'signature_tidak_valid' });
    // ^ Tidak cocok dengan secret lama MAUPUN nextSecret (kalau ada) ->
    //   benar-benar signature invalid, tolak.
  } catch (err) {
    return next(err);
    // ^ Error tak terduga (mis. Postgres down, error jaringan) diteruskan
    //   ke error handler terpusat (middleware/errorHandler.js) lewat
    //   next(err) -- Express otomatis mengenali ini sebagai error handler
    //   ketika argumen pertama next() bukan undefined.
  }
}

module.exports = deviceAuth;
