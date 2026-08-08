// routes/devices.js — Endpoint app Flutter untuk kelola device; semua butuh operatorAuth (JWT). Setiap endpoint cek owner_id agar device milik operator lain tak terlihat (multi-tenancy). Device lama tanpa owner_id di-backfill dulu via scripts/backfill-owner.js.
const express = require('express');
const db = require('../lib/db');
const { randomToken } = require('../lib/crypto');
const logger = require('../lib/logger');
const audit = require('../lib/audit');
const { validate, schemas } = require('../lib/validate');
const operatorAuth = require('../middleware/operatorAuth');

const router = express.Router();
router.use(operatorAuth);
// Wajibkan JWT valid di semua endpoint; req.operator.username dipakai untuk cek kepemilikan.

// Ambil device by id & pastikan milik operator login; kirim 404/403 sendiri kalau gagal (pemanggil cukup `if (!device) return;`).
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
    // Pesan sengaja sama (404) untuk device tak ada & punya orang lain, agar owner_id tak bisa ditebak.
    res.status(404).json({ ok: false, error: 'device_tidak_ditemukan' });
    return null;
  }
  return device;
}

// GET /api/devices — daftar device milik operator + snapshot readings terakhir (untuk UI dinamis).
router.get('/', async (req, res, next) => {
  try {
    const { rows: devices } = await db.query(
      'SELECT device_id, label, created_at, last_seen_at, node_power_save, gateway_power_save FROM devices WHERE owner_id = $1 ORDER BY created_at ASC',
      [req.operator.username]
    );
    // Hanya device dengan owner_id cocok; milik operator lain tak muncul.

    const result = await Promise.all(
      devices.map(async (d) => {
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
          node_power_save: !!(d.node_power_save),
          gateway_power_save: !!(d.gateway_power_save),
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

// POST /api/devices — provisioning device baru (body: { label? }).
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
    // Urutkan kronologis (lama→baru) untuk grafik.
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

    // Append ke pending_commands (JSONB) secara atomik.
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

// POST /api/devices/:id/rekey — rotasi device_secret (device_id tetap).
router.post('/:id/rekey', async (req, res, next) => {
  try {
    const owned = await loadOwnedDeviceOrRespond(req, res);
    if (!owned) return;
    const newSecret = randomToken(32);

    // Simpan sebagai next_secret dulu + antre command rekey; deviceAuth mempromosikannya jadi secret resmi begitu gateway pakai secret baru.
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

// DELETE /api/devices/:id — hapus device permanen.
router.delete('/:id', async (req, res, next) => {
  try {
    const owned = await loadOwnedDeviceOrRespond(req, res);
    if (!owned) return; // response 404 sudah dikirim helper di atas

    // ON DELETE CASCADE ikut hapus readings terkait.
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
