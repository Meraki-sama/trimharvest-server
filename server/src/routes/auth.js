// routes/auth.js — Login operator (app Flutter). Server satu-satunya penjaga gerbang: password di-hash bcrypt di sini; app tak bicara langsung ke DB. Lihat PROTOCOL.md bagian 3.
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

// Batasi brute-force login: 10 percobaan / 15 menit per IP. Endpoint lain sudah dilindungi HMAC/JWT.
const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 menit.
  limit: 10,                // Maks 10 percobaan per IP per jendela.
  standardHeaders: true,
  legacyHeaders: false,
  message: { ok: false, error: 'terlalu_banyak_percobaan_login_coba_lagi_nanti' },
  // Body 429 saat limit terlampaui (lebih deskriptif dari default).
});

// Buat access token JWT: sub=username, type='access', tv=tokenVersion (dicocokkan tiap request untuk pencabutan sesi).
function signAccessToken(username, tokenVersion = 0) {
  return jwt.sign({ sub: username, type: 'access', tv: tokenVersion }, config.jwtAccessSecret, {
    expiresIn: config.jwtAccessTtl, // jwt otomatis isi klaim exp (default 15m).
  });
}

// Sama, tapi pakai secret & TTL berbeda (jauh lebih lama, default 30 hari). tv ikut ditanam agar refresh token bisa dicabut via ganti password.
function signRefreshToken(username, tokenVersion = 0) {
  return jwt.sign({ sub: username, type: 'refresh', tv: tokenVersion }, config.jwtRefreshSecret, {
    expiresIn: config.jwtRefreshTtl,
  });
}

router.post('/login', loginLimiter, validate(schemas.login), async (req, res, next) => {
  // POST /api/auth/login — loginLimiter & validasi Joi dipasang sebelum handler; payload anomali langsung 400.
  try {
    const { username, password } = req.body || {};
    if (!username || !password) {
      return res.status(400).json({ ok: false, error: 'username_atau_password_kosong' });
    }

    const { rows } = await db.query(
      'SELECT username, password_hash, token_version FROM operators WHERE username = $1',
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
    const tv = operator.token_version || 0;
    return res.json({
      ok: true,
      accessToken: signAccessToken(username, tv),
      refreshToken: signRefreshToken(username, tv),
    });
  } catch (err) {
    return next(err);
  }
});

router.post('/refresh', validate(schemas.refresh), async (req, res, next) => {
  // POST /api/auth/refresh — tak pakai loginLimiter (butuh refresh token valid, lebih sulit ditebak).
  try {
    const { refreshToken } = req.body || {};
    if (!refreshToken) {
      return res.status(400).json({ ok: false, error: 'refresh_token_kosong' });
    }

    let payload;
    try {
      payload = jwt.verify(refreshToken, config.jwtRefreshSecret);
      // Verifikasi pakai SECRET REFRESH; access token akan gagal di sini karena secret berbeda.
    } catch (e) {
      return res.status(401).json({ ok: false, error: 'refresh_token_tidak_valid_atau_kedaluwarsa' });
    }
    if (payload.type !== 'refresh') {
      // Lapis aman: pastikan payload memang type 'refresh'.
      return res.status(401).json({ ok: false, error: 'token_bukan_refresh_token' });
    }

    // Cocokkan tv dengan token_version terkini — inilah yang membuat pencabutan sesi berlaku untuk refresh token 30 hari.
    const { rows } = await db.query(
      'SELECT username, token_version FROM operators WHERE username = $1',
      [payload.sub]
    );
    if (rows.length === 0) {
      return res.status(401).json({ ok: false, error: 'operator_tidak_ditemukan' });
    }
    const currentTv = rows[0].token_version || 0;
    if ((payload.tv || 0) !== currentTv) {
      return res.status(401).json({ ok: false, error: 'sesi_sudah_dicabut_silakan_login_ulang' });
    }

    return res.json({ ok: true, accessToken: signAccessToken(payload.sub, currentTv) });
    // Hanya terbitkan access token baru (refresh token dipakai terus hingga 30 hari). Kini bisa dicabut via ganti password.
  } catch (err) {
    return next(err);
  }
});

// POST /api/auth/change-password — dilindungi operatorAuth; hanya operator login yang bisa ganti password sendiri.
router.post('/change-password', operatorAuth, validate(schemas.changePassword), async (req, res, next) => {
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
    // Naikkan token_version sekaligus → semua sesi lama (HP lain/hilang) langsung tak berlaku begitu password diganti.
    const upd = await db.query(
      'UPDATE operators SET password_hash = $1, token_version = token_version + 1 ' +
      'WHERE username = $2 RETURNING token_version',
      [newHash, auth.username]
    );
    await audit.record(audit.ACTIONS.PASSWORD_CHANGE_OK, { operator: auth.username });

    // Terbitkan token baru agar pengguna yang baru ganti password tak ikut terlempar oleh pencabutan yang dia picu.
    const newTv = upd.rows[0] ? upd.rows[0].token_version : 0;
    return res.json({
      ok: true,
      accessToken: signAccessToken(auth.username, newTv),
      refreshToken: signRefreshToken(auth.username, newTv),
    });
  } catch (err) {
    return next(err);
  }
});

module.exports = router;
