// lib/crypto.js — HMAC (verifikasi signature), perbandingan tahan timing-attack, dan token acak aman untuk device_id/secret.

const crypto = require('crypto');
// Modul kripto bawaan Node (hash, HMAC, random bytes) — tak perlu di-install.

function hmacHex(key, data) {
  // HMAC-SHA256 → hex; harus identik dengan firmware gateway (lihat PROTOCOL.md 2.1).
  return crypto.createHmac('sha256', key).update(data, 'utf8').digest('hex');
}

function safeEqualHex(aHex, bHex) {
  // Bandingkan dua hex signature secara tahan timing-attack (jangan pakai === biasa, rawan bocor via waktu).
  const a = Buffer.from(aHex, 'hex');
  const b = Buffer.from(bHex, 'hex');

  if (a.length !== b.length) return false; // timingSafeEqual melempar kalau panjang beda, jadi cek dulu.
  return crypto.timingSafeEqual(a, b);
  // Waktu eksekusi konstan terlepas di mana letak byte berbeda → tak bocor lewat respons.
}

function randomToken(bytesLength) {
  // Token acak dari CSPRNG (bukan Math.random); dipakai device_id (6 byte) & secret (32 byte).
  return crypto.randomBytes(bytesLength).toString('hex');
}

module.exports = { hmacHex, safeEqualHex, randomToken };
// Dipakai deviceAuth (hmacHex + safeEqualHex) dan routes/devices (randomToken).
