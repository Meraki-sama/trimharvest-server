// ============================================================================
// lib/audit.js — Audit log kejadian keamanan penting.
// Setiap aksi sensitif (login gagal/berhasil, provision device, rekey,
// delete device, ganti WiFi) dicatat KE Postgres (tabel `audit`) DAN ke
// structured logger. Ini standar industri untuk forensik & deteksi anomali
// (mis. banyak login gagal = brute-force).
//
// Perubahan dari versi database sebelumnya: collection 'audit' -> tabel `audit` (Postgres).
// ============================================================================
const db = require('./db');
const logger = require('./logger');

// Aksi yang dilacak. Dipusatkan supaya mudah diaudit & jangan ada yang
// terlewat.
const ACTIONS = {
  LOGIN_OK: 'login_ok',
  LOGIN_FAIL: 'login_fail',
  OPERATOR_CREATE: 'operator_create',
  DEVICE_PROVISION: 'device_provision',
  DEVICE_DELETE: 'device_delete',
  DEVICE_REKEY: 'device_rekey',
  WIFI_UPDATE: 'wifi_update',
  COMMAND_QUEUE: 'command_queue',
  OWNERSHIP_BACKFILL: 'ownership_backfill',
  PASSWORD_CHANGE_OK: 'password_change_ok',
  PASSWORD_CHANGE_FAIL: 'password_change_fail',
};

async function record(action, meta = {}) {
  // meta: { operator?, deviceId?, dest?, cmd?, ip?, reason? }
  logger.info({ audit: true, action, ...meta }, `audit: ${action}`);
  try {
    // Fire-and-forget ke Postgres. Tidak sampai menghambat response utama
    // karena dipanggil setelah response dikirim di endpoint terkait.
    await db.query(
      `INSERT INTO audit (action, operator, device_id, dest, cmd, ip, reason, meta)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
      [
        action,
        meta.operator || null,
        meta.deviceId || null,
        meta.dest || null,
        meta.cmd || null,
        meta.ip || null,
        meta.reason || null,
        JSON.stringify(meta), // seluruh meta (operator/ip/reason/extra) tersimpan
      ]
    );
  } catch (err) {
    // Jangan biarkan kegagalan audit log ikut merusak request utama.
    logger.error({ err: err.message }, 'audit: gagal menulis ke database');
  }
}

module.exports = { record, ACTIONS };
