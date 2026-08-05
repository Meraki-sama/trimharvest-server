// ============================================================================
// middleware/operatorAuth.js — Middleware Express yang memverifikasi JWT
// access token pada request dari app Flutter. Lihat /PROTOCOL.md bagian 3.
// ============================================================================
const jwt = require('jsonwebtoken');
// ^ Library standar untuk membuat & memverifikasi JSON Web Token.
const config = require('../config');

function operatorAuth(req, res, next) {
  const header = req.header('Authorization') || '';
  // ^ Ambil header "Authorization" (mis. isinya "Bearer eyJhbGciOi...").
  //   Fallback ke string kosong kalau header tidak ada, supaya baris
  //   `.match()` di bawah tidak error karena memanggil method di
  //   undefined.
  const match = header.match(/^Bearer (.+)$/);
  // ^ Regex: harus diawali literal "Bearer " lalu tangkap (capture group)
  //   sisa string sesudahnya sebagai token JWT-nya. Kalau format header
  //   salah (tidak ada "Bearer ", atau kosong), `match` akan bernilai null.
  if (!match) {
    return res.status(401).json({ ok: false, error: 'header_authorization_tidak_ada' });
  }

  try {
    const payload = jwt.verify(match[1], config.jwtAccessSecret);
    // ^ match[1] = token JWT hasil capture group regex di atas.
    //   jwt.verify melakukan DUA hal sekaligus: (1) memeriksa tanda tangan
    //   token cocok dengan secret ini (menjamin token memang diterbitkan
    //   oleh server ini, bukan dipalsukan), dan (2) memeriksa token belum
    //   kedaluwarsa (klaim `exp` di dalam payload, diisi otomatis oleh
    //   jwt.sign() saat login -- lihat routes/auth.js). Kalau salah satu
    //   gagal, function ini MELEMPAR ERROR (ditangkap oleh catch di bawah).
    if (payload.type !== 'access') {
      // ^ Server ini menandatangani DUA jenis token dengan struktur payload
      //   mirip (access & refresh, lihat routes/auth.js), dibedakan lewat
      //   field `type`. Cek ini mencegah refresh token (yang harusnya cuma
      //   dipakai di endpoint /api/auth/refresh) dipakai untuk mengakses
      //   endpoint data biasa seolah-olah access token -- refresh token
      //   punya masa berlaku jauh lebih panjang, jadi kalau bocor & bisa
      //   dipakai langsung tanpa pengecekan ini, dampaknya jauh lebih besar.
      return res.status(401).json({ ok: false, error: 'token_bukan_access_token' });
    }
    req.operator = { username: payload.sub };
    // ^ `sub` (subject) adalah klaim standar JWT untuk identitas pemilik
    //   token -- di sini diisi username operator saat token dibuat
    //   (lihat signAccessToken() di routes/auth.js). Disimpan di req supaya
    //   route handler berikutnya tahu siapa yang sedang login.
    return next(); // Token valid -> lanjut ke route handler.
  } catch (err) {
    // jwt.verify() melempar error untuk BANYAK alasan: signature tidak
    // cocok, token kedaluwarsa, format token rusak, dst -- semuanya
    // ditangani sama di sini dengan pesan generik (tidak membocorkan alasan
    // spesifik ke client, supaya tidak membantu penyerang menebak-nebak).
    return res.status(401).json({ ok: false, error: 'token_tidak_valid_atau_kedaluwarsa' });
  }
}

module.exports = operatorAuth;
