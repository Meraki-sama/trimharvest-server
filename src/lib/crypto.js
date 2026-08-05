// ============================================================================
// lib/crypto.js — Fungsi kriptografi kecil yang dipakai berulang di server:
// HMAC untuk verifikasi tanda tangan request, perbandingan tahan timing-
// attack, dan pembuat token acak aman untuk device_id/device_secret.
// ============================================================================

const crypto = require('crypto');
// ^ Modul bawaan Node.js untuk operasi kriptografi (hash, HMAC, random bytes,
//   dst) -- TIDAK perlu di-install lewat npm, sudah ada di Node sejak lama.

function hmacHex(key, data) {
  // Menghitung HMAC-SHA256 lalu mengembalikannya sebagai string heksadesimal.
  // HARUS identik logikanya dengan hmacHex() di firmware gateway
  // (gateway-rumah/src/http_client.cpp) supaya kedua sisi menghasilkan
  // signature yang sama persis untuk input yang sama -- lihat /PROTOCOL.md
  // bagian 2.1 untuk skema lengkapnya.
  return crypto.createHmac('sha256', key).update(data, 'utf8').digest('hex');
  // ^ createHmac('sha256', key) : buat objek HMAC baru dengan algoritma
  //     SHA-256 dan `key` sebagai kunci rahasia (di sini: device_secret).
  //   .update(data, 'utf8')     : masukkan data yang mau ditandatangani,
  //     di-encode sebagai UTF-8 (harus konsisten dengan encoding yang
  //     dipakai firmware saat menyusun string yang sama).
  //   .digest('hex')            : selesaikan perhitungan HMAC dan kembalikan
  //     hasilnya (32 byte untuk SHA-256) sebagai string hex 64 karakter.
}

function safeEqualHex(aHex, bHex) {
  // Membandingkan dua signature (dalam bentuk hex string) dengan CARA YANG
  // TAHAN TIMING-ATTACK -- JANGAN PERNAH memakai `aHex === bHex` biasa untuk
  // membandingkan signature/HMAC/password hash, karena perbandingan string
  // JavaScript biasa berhenti di karakter PERTAMA yang beda, sehingga waktu
  // eksekusinya sedikit berbeda tergantung berapa banyak karakter awal yang
  // cocok -- penyerang yang mengukur waktu respons server berkali-kali bisa
  // menebak signature yang benar BYTE DEMI BYTE (timing side-channel attack).
  const a = Buffer.from(aHex, 'hex');
  // ^ Ubah string hex jadi Buffer (array byte mentah) supaya bisa dibanding
  //   di level byte, bukan di level karakter string.
  const b = Buffer.from(bHex, 'hex');

  if (a.length !== b.length) return false;
  // ^ crypto.timingSafeEqual() akan MELEMPAR ERROR (bukan return false) kalau
  //   panjang dua buffer beda -- jadi panjang harus dicek & disamakan dulu
  //   secara eksplisit sebelum memanggilnya. Catatan: perbandingan panjang
  //   ini sendiri bukan celah timing yang berarti (panjang HMAC-SHA256 hex
  //   selalu tetap 64 karakter kalau formatnya benar).
  return crypto.timingSafeEqual(a, b);
  // ^ Fungsi bawaan Node yang membandingkan SELURUH byte tanpa short-circuit
  //   -- waktu eksekusinya konstan terlepas dari di mana letak byte yang
  //   berbeda, sehingga tidak membocorkan informasi lewat waktu respons.
}

function randomToken(bytesLength) {
  // Menghasilkan string token acak aman-kriptografis (bukan Math.random()
  // yang TIDAK aman secara kriptografis dan bisa ditebak) -- dipakai untuk
  // membuat device_id baru (6 byte) dan device_secret baru (32 byte) di
  // routes/devices.js.
  return crypto.randomBytes(bytesLength).toString('hex');
  // ^ randomBytes(n)   : minta `n` byte acak dari CSPRNG (Cryptographically
  //     Secure Pseudo-Random Number Generator) milik OS.
  //   .toString('hex') : ubah byte mentah itu jadi string hex yang mudah
  //     disimpan/dikirim lewat JSON (2 karakter hex per byte, jadi hasil
  //     akhirnya `bytesLength * 2` karakter).
}

module.exports = { hmacHex, safeEqualHex, randomToken };
// ^ Export ketiga fungsi supaya bisa dipakai di middleware/deviceAuth.js
//   (hmacHex + safeEqualHex, untuk verifikasi signature gateway) dan
//   routes/devices.js (randomToken, untuk provisioning device_id/secret baru).
