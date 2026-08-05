// ============================================================================
// routes/auth.js — Login operator (pengguna app Flutter) -- lihat
// /PROTOCOL.md bagian 3. Server ini SATU-SATUNYA penjaga gerbang: password
// operator di-hash bcrypt DI SINI (bukan layanan auth pihak ketiga); app
// tidak pernah bicara langsung ke database, semua lewat server ini.
// ============================================================================
const express = require('express');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const rateLimit = require('express-rate-limit');
const db = require('../lib/db');
const config = require('../config');
const logger = require('../lib/logger');
const audit = require('../lib/audit');
const operatorAuth = require('../middleware/operatorAuth');
const { validate, schemas } = require('../lib/validate');

const router = express.Router();

// Batasi percobaan login supaya tidak bisa di-brute-force -- 10 percobaan
// per 15 menit per alamat IP. Endpoint lain tidak dibatasi seketat ini
// karena sudah dilindungi HMAC (device) atau JWT (operator yang sudah login).
const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 menit dalam milidetik.
  limit: 10,                // Maksimum 10 percobaan login per IP per jendela.
  standardHeaders: true,
  legacyHeaders: false,
  message: { ok: false, error: 'terlalu_banyak_percobaan_login_coba_lagi_nanti' },
  // ^ Body response kustom saat limit terlampaui (default express-rate-limit
  //   kurang deskriptif) -- dikirim otomatis oleh middleware ini dengan
  //   status 429 Too Many Requests.
});

function signAccessToken(username) {
  // ^ Helper: buat access token JWT baru untuk `username` yang sudah
  //   terverifikasi login-nya.
  return jwt.sign({ sub: username, type: 'access' }, config.jwtAccessSecret, {
    // ^ Payload: `sub` (subject, standar JWT untuk identitas pemilik token)
    //   diisi username, `type: 'access'` untuk membedakan dari refresh token
    //   (dicek di middleware/operatorAuth.js).
    expiresIn: config.jwtAccessTtl,
    // ^ jsonwebtoken otomatis menghitung & menambahkan klaim `exp` (waktu
    //   kedaluwarsa Unix timestamp) berdasarkan opsi ini (default '15m').
  });
}

function signRefreshToken(username) {
  // ^ Sama seperti signAccessToken, tapi pakai secret & masa berlaku
  //   BERBEDA (jwtRefreshSecret, jwtRefreshTtl -- jauh lebih lama, default
  //   30 hari) -- lihat config.js untuk alasan pemisahan ini.
  return jwt.sign({ sub: username, type: 'refresh' }, config.jwtRefreshSecret, {
    expiresIn: config.jwtRefreshTtl,
  });
}

router.post('/login', loginLimiter, validate(schemas.login), async (req, res, next) => {
  // ^ POST /api/auth/login -- loginLimiter dipasang SEBAGAI MIDDLEWARE
  //   KEDUA (setelah path matching, sebelum handler), jadi hanya endpoint
  //   ini yang dibatasi seketat itu (bukan seluruh /api/auth/*). Sekarang
  //   juga divalidasi schema Joi (username/password wajib & terbatas
  //   panjangnya) supaya payload anomali langsung 400, tidak sampai
  //   diproses lebih lanjut.
  try {
    const { username, password } = req.body || {};
    if (!username || !password) {
      return res.status(400).json({ ok: false, error: 'username_atau_password_kosong' });
    }

    const { rows } = await db.query(
      'SELECT username, password_hash FROM operators WHERE username = $1',
      [username]
    );
    if (rows.length === 0) {
      await audit.record(audit.ACTIONS.LOGIN_FAIL, { operator: username, reason: 'no_such_user' });
      return res.status(401).json({ ok: false, error: 'username_atau_password_salah' });
    }

    const operator = rows[0];
    const match = await bcrypt.compare(password, operator.password_hash);
    if (!match) {
      await audit.record(audit.ACTIONS.LOGIN_FAIL, { operator: username, reason: 'bad_password' });
      logger.warn({ operator: username }, 'login gagal: password salah');
      return res.status(401).json({ ok: false, error: 'username_atau_password_salah' });
    }

    await audit.record(audit.ACTIONS.LOGIN_OK, { operator: username });
    return res.json({
      ok: true,
      accessToken: signAccessToken(username),
      refreshToken: signRefreshToken(username),
    });
  } catch (err) {
    return next(err);
  }
});

router.post('/refresh', validate(schemas.refresh), async (req, res, next) => {
  // ^ POST /api/auth/refresh -- TIDAK dipasangi loginLimiter (endpoint ini
  //   sudah butuh refresh token yang valid, jauh lebih sulit ditebak
  //   daripada kombinasi username+password, jadi risiko brute-force lebih
  //   rendah).
  try {
    const { refreshToken } = req.body || {};
    if (!refreshToken) {
      return res.status(400).json({ ok: false, error: 'refresh_token_kosong' });
    }

    let payload;
    try {
      payload = jwt.verify(refreshToken, config.jwtRefreshSecret);
      // ^ Verifikasi memakai SECRET REFRESH (beda dari secret access) --
      //   kalau seseorang mencoba mengirim access token ke endpoint ini,
      //   verifikasi ini akan GAGAL karena access token ditandatangani
      //   dengan secret yang berbeda.
    } catch (e) {
      return res.status(401).json({ ok: false, error: 'refresh_token_tidak_valid_atau_kedaluwarsa' });
    }
    if (payload.type !== 'refresh') {
      // ^ Lapis validasi tambahan (jaga-jaga): pastikan payload memang
      //   punya type 'refresh', bukan token lain yang somehow lolos
      //   verifikasi signature (skenario ini seharusnya sudah mustahil
      //   karena secret berbeda, tapi validasi eksplisit ini murah & jelas
      //   maksudnya untuk pembaca kode).
      return res.status(401).json({ ok: false, error: 'token_bukan_refresh_token' });
    }

    return res.json({ ok: true, accessToken: signAccessToken(payload.sub) });
    // ^ HANYA menerbitkan access token BARU, TIDAK menerbitkan refresh
    //   token baru -- refresh token yang sama terus dipakai sampai 30 hari
    //   masa berlakunya habis (operator harus login ulang dengan password
    //   setelah itu). Ini desain umum "refresh token tanpa rotasi" -- lebih
    //   sederhana, trade-off-nya kalau refresh token bocor, ia tetap valid
    //   sampai kedaluwarsa (tidak ada mekanisme revoke di sistem ini).
  } catch (err) {
    return next(err);
  }
});

// Ganti password operator yang sedang login. Wajib kirim password lama
// (verifikasi ulang) + password baru (divalidasi panjang minimal).
// Password di-hash bcrypt sebelum disimpan, persis seperti saat create.
router.post('/change-password', operatorAuth, validate(schemas.changePassword), async (req, res, next) => {
  // ^ POST /api/auth/change-password -- DILINDUNGI operatorAuth (lihat
  //   index.js: mount setelah middleware auth) -- hanya operator dengan
  //   access token valid yang bisa mengganti password sendiri.
  try {
    const auth = req.operator; // diisi middleware operatorAuth.js
    if (!auth || !auth.username) {
      return res.status(401).json({ ok: false, error: 'belum_login' });
    }
    const { currentPassword, newPassword } = req.body || {};
    if (!currentPassword || !newPassword) {
      return res.status(400).json({ ok: false, error: 'password_kosong' });
    }

    const { rows } = await db.query(
      'SELECT username, password_hash FROM operators WHERE username = $1',
      [auth.username]
    );
    if (rows.length === 0) {
      return res.status(404).json({ ok: false, error: 'operator_tidak_ditemukan' });
    }

    const match = await bcrypt.compare(currentPassword, rows[0].password_hash);
    if (!match) {
      await audit.record(audit.ACTIONS.PASSWORD_CHANGE_FAIL, { operator: auth.username });
      return res.status(401).json({ ok: false, error: 'password_lama_salah' });
    }

    const newHash = await bcrypt.hash(newPassword, 12);
    await db.query('UPDATE operators SET password_hash = $1 WHERE username = $2', [
      newHash,
      auth.username,
    ]);
    await audit.record(audit.ACTIONS.PASSWORD_CHANGE_OK, { operator: auth.username });
    return res.json({ ok: true });
  } catch (err) {
    return next(err);
  }
});

module.exports = router;
