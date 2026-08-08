// middleware/operatorAuth.js — Verifikasi JWT access token pada request app Flutter. Lihat PROTOCOL.md bagian 3.
const jwt = require('jsonwebtoken');
// Library standar untuk membuat & memverifikasi JSON Web Token.
const config = require('../config');
const db = require('../lib/db');
// Dibutuhkan untuk cek operators.token_version (pencabutan sesi).

async function operatorAuth(req, res, next) {
  const header = req.header('Authorization') || '';
  // Ambil header Authorization ("Bearer ..."); fallback string kosong supaya .match() tak error.
  const match = header.match(/^Bearer (.+)$/);
  // Regex capture token setelah "Bearer "; kalau format salah, match = null.
  if (!match) {
    return res.status(401).json({ ok: false, error: 'header_authorization_tidak_ada' });
  }

  try {
    const payload = jwt.verify(match[1], config.jwtAccessSecret);
    // jwt.verify sekaligus cek signature & masa berlaku; lempar error kalau gagal.
    if (payload.type !== 'access') {
      // Cegah refresh token (umur panjang) dipakai sebagai access token.
      return res.status(401).json({ ok: false, error: 'token_bukan_access_token' });
    }
    // Pencabutan sesi: tolak token lama begitu password diganti (token_version naik).
    const { rows } = await db.query(
      'SELECT token_version FROM operators WHERE username = $1',
      [payload.sub]
    );
    if (rows.length === 0) {
      // Operator sudah dihapus tapi token masih beredar.
      return res.status(401).json({ ok: false, error: 'operator_tidak_ditemukan' });
    }
    if ((payload.tv || 0) !== (rows[0].token_version || 0)) {
      return res.status(401).json({ ok: false, error: 'sesi_sudah_dicabut_silakan_login_ulang' });
    }

    req.operator = { username: payload.sub };
    // sub = identitas pemilik token; simpan di req untuk route berikutnya.
    return next();
  } catch (err) {
    // Error JWT (signature/expired) → 401 generik tanpa bocorkan alasan. Error lain (mis. Postgres down) diteruskan sebagai 500, bukan dijadikan 401 agar gangguan DB tak menyamar sebagai "token invalid".
    const isTokenError =
      err && ['JsonWebTokenError', 'TokenExpiredError', 'NotBeforeError'].includes(err.name);
    if (!isTokenError) return next(err);
    return res.status(401).json({ ok: false, error: 'token_tidak_valid_atau_kedaluwarsa' });
  }
}

module.exports = operatorAuth;
