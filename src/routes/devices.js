// ============================================================================
// routes/devices.js — Endpoint yang dipakai app Flutter untuk mengelola
// device -- semua butuh operatorAuth (JWT), lihat /PROTOCOL.md bagian 3.
//
// PERBAIKAN BUG MULTI-TENANCY: SEMUA endpoint memverifikasi `owner_id`
// device cocok dengan operator yang sedang login sebelum mengizinkan akses.
// Device LAMA yang belum punya owner_id (dibuat sebelum perbaikan ini)
// perlu dijalankan `node scripts/backfill-owner.js <username>` dulu supaya
// kembali terlihat oleh pemiliknya.
//
// Storage: PostgreSQL (lihat lib/db.js). Collection 'devices' -> tabel
// `devices`, sub-koleksi 'readings' -> tabel `readings`.
// ============================================================================
const express = require('express');
const db = require('../lib/db');
const { randomToken } = require('../lib/crypto');
const logger = require('../lib/logger');
const audit = require('../lib/audit');
const { validate, schemas } = require('../lib/validate');
const operatorAuth = require('../middleware/operatorAuth');

const router = express.Router();
router.use(operatorAuth);
// ^ Dipasang di LEVEL ROUTER -- SEMUA endpoint di bawah otomatis mensyaratkan
//   JWT access token valid. `req.operator.username` dipakai di seluruh file
//   ini untuk menegakkan kepemilikan device per operator.

// Helper: ambil device by id DAN pastikan device ini milik operator yang
// sedang login. Mengirim response 404/403 sendiri kalau gagal (supaya
// pemanggil cukup `if (!device) return;`).
async function loadOwnedDeviceOrRespond(req, res) {
  const { rows } = await db.query(
    'SELECT device_id, secret, label, owner_id, created_at, last_seen_at, last_seq, next_secret, pending_commands FROM devices WHERE device_id = $1',
    [req.params.id]
  );
  if (rows.length === 0) {
    res.status(404).json({ ok: false, error: 'device_tidak_ditemukan' });
    return null;
  }
  const device = rows[0];
  if (device.owner_id !== req.operator.username) {
    // ^ Pesan error SENGAJA sama dengan "tidak ditemukan" (404, bukan 403)
    //   supaya operator lain tidak bisa menebak device_id mana yang ada.
    res.status(404).json({ ok: false, error: 'device_tidak_ditemukan' });
    return null;
  }
  return device;
}

// GET /api/devices — daftar device MILIK OPERATOR YANG LOGIN + snapshot
// readings TERAKHIR (dipakai app untuk UI dinamis).
router.get('/', async (req, res, next) => {
  try {
    const { rows: devices } = await db.query(
      'SELECT device_id, label, created_at, last_seen_at FROM devices WHERE owner_id = $1 ORDER BY created_at ASC',
      [req.operator.username]
    );
    // ^ HANYA device dengan owner_id cocok -- device milik operator LAIN
    //   tidak akan pernah muncul.

    const result = await Promise.all(
      devices.map(async (d) => {
        // Ambil 1 readings terbaru per device (urut ts DESC, limit 1).
        const { rows: rrows } = await db.query(
          'SELECT ts, type, node_msg_type, readings FROM readings WHERE device_id = $1 ORDER BY ts DESC LIMIT 1',
          [d.device_id]
        );
        const lastReading = rrows.length ? rrows[0] : null;
        return {
          device_id: d.device_id,
          label: d.label || d.device_id,
          created_at: d.created_at || null,
          last_seen_at: d.last_seen_at || null,
          last_reading: lastReading
            ? {
                ts: lastReading.ts,
                type: lastReading.type,
                node_msg_type: lastReading.node_msg_type || null,
                readings: typeof lastReading.readings === 'string'
                  ? JSON.parse(lastReading.readings)
                  : (lastReading.readings || []),
              }
            : null,
        };
      })
    );
    return res.json({ ok: true, devices: result });
  } catch (err) {
    return next(err);
  }
});

// POST /api/devices — provisioning device baru. body: { label? }
router.post('/', validate(schemas.provisionDevice), async (req, res, next) => {
  try {
    const label = (req.body && req.body.label) || '';
    const deviceId = `dev_${randomToken(6)}`;
    const deviceSecret = randomToken(32);

    await db.query(
      `INSERT INTO devices (device_id, secret, label, owner_id, created_at, last_seq, pending_commands)
       VALUES ($1, $2, $3, $4, $5, 0, '[]')`,
      [deviceId, deviceSecret, label || deviceId, req.operator.username, new Date().toISOString()]
    );

    await audit.record(audit.ACTIONS.DEVICE_PROVISION, {
      operator: req.operator.username,
      deviceId,
      label: label || deviceId,
    });
    return res.status(201).json({ ok: true, device_id: deviceId, device_secret: deviceSecret });
  } catch (err) {
    return next(err);
  }
});

// GET /api/devices/:id/readings?limit=100 — histori data untuk grafik.
router.get('/:id/readings', async (req, res, next) => {
  try {
    const limit = Math.min(parseInt(req.query.limit, 10) || 100, 500);
    const owned = await loadOwnedDeviceOrRespond(req, res);
    if (!owned) return;

    const { rows } = await db.query(
      'SELECT ts, type, node_msg_type, readings, seq FROM readings WHERE device_id = $1 ORDER BY ts DESC LIMIT $2',
      [req.params.id, limit]
    );
    // Urutkan kronologis (lama->baru) untuk grafik.
    const readings = rows
      .map((r) => ({
        ts: r.ts,
        type: r.type,
        node_msg_type: r.node_msg_type || null,
        readings: typeof r.readings === 'string' ? JSON.parse(r.readings) : (r.readings || []),
        seq: r.seq,
      }))
      .reverse();

    return res.json({ ok: true, readings });
  } catch (err) {
    return next(err);
  }
});

// POST /api/devices/:id/commands — antre command untuk device.
router.post('/:id/commands', validate(schemas.command), async (req, res, next) => {
  try {
    const owned = await loadOwnedDeviceOrRespond(req, res);
    if (!owned) return;

    const { dest, cmd } = req.body || {};
    if (dest !== 'node' && dest !== 'gateway') {
      return res.status(400).json({ ok: false, error: 'dest_harus_node_atau_gateway' });
    }
    if (!cmd || typeof cmd !== 'string') {
      return res.status(400).json({ ok: false, error: 'cmd_wajib_diisi' });
    }

    // Append ke array pending_commands (JSONB) secara atomik via
    // jsonb_set / || concat. Pakai `pending_commands || $1::jsonb` untuk
    // menambah elemen baru ke array.
    const current = typeof owned.pending_commands === 'string'
      ? JSON.parse(owned.pending_commands)
      : (owned.pending_commands || []);
    const nextCommands = [...current, req.body];

    await db.query(
      'UPDATE devices SET pending_commands = $1 WHERE device_id = $2',
      [JSON.stringify(nextCommands), req.params.id]
    );

    await audit.record(audit.ACTIONS.COMMAND_QUEUE, {
      operator: req.operator.username,
      deviceId: req.params.id,
      dest: req.body.dest,
      cmd: req.body.cmd,
    });
    return res.json({ ok: true });
  } catch (err) {
    return next(err);
  }
});

// POST /api/devices/:id/rekey — rotasi device_secret (device_id tetap sama).
router.post('/:id/rekey', async (req, res, next) => {
  try {
    const owned = await loadOwnedDeviceOrRespond(req, res);
    if (!owned) return;
    const newSecret = randomToken(32);

    // Simpan sebagai next_secret dulu, dan antre command rekey.
    const current = typeof owned.pending_commands === 'string'
      ? JSON.parse(owned.pending_commands)
      : (owned.pending_commands || []);
    const nextCommands = [
      ...current,
      { dest: 'gateway', cmd: 'rekey', new_secret: newSecret },
    ];

    await db.query(
      'UPDATE devices SET next_secret = $1, pending_commands = $2 WHERE device_id = $3',
      [newSecret, JSON.stringify(nextCommands), req.params.id]
    );

    await audit.record(audit.ACTIONS.DEVICE_REKEY, {
      operator: req.operator.username,
      deviceId: req.params.id,
    });
    return res.json({ ok: true, device_secret: newSecret });
  } catch (err) {
    return next(err);
  }
});

// DELETE /api/devices/:id — hapus device secara permanen.
router.delete('/:id', async (req, res, next) => {
  try {
    const owned = await loadOwnedDeviceOrRespond(req, res);
    if (!owned) return; // response 404 sudah dikirim helper di atas

    // ON DELETE CASCADE di tabel readings menghapus semua readings terkait.
    await db.query('DELETE FROM devices WHERE device_id = $1', [req.params.id]);

    await audit.record(audit.ACTIONS.DEVICE_DELETE, {
      operator: req.operator.username,
      deviceId: req.params.id,
    });
    return res.json({ ok: true });
  } catch (err) {
    return next(err);
  }
});

module.exports = router;
