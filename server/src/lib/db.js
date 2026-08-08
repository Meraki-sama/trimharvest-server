// lib/db.js — Koneksi & inisialisasi PostgreSQL (driver pg). Di-require di index.js sebelum route, agar server gagal start cepat kalau DATABASE_URL salah (fail-fast).

const { Pool } = require('pg');
// Driver PostgreSQL resmi; Railway inject DATABASE_URL otomatis.

let pool;
// Pool di-cache di module scope agar koneksi dipakai ulang antar request.

function getPool() {
  // Lazy singleton: buat pool saat pertama dipakai (bukan saat require) supaya test yang stub modul ini tak memicu koneksi sungguhan.
  if (!pool) {
    if (!process.env.DATABASE_URL) {
      throw new Error(
        'Konfigurasi wajib "DATABASE_URL" belum diisi (Railway inject otomatis ' +
          'dari Postgres add-on, atau isi di .env lokal).'
      );
    }
    pool = new Pool({
      connectionString: process.env.DATABASE_URL,
      ssl: process.env.NODE_ENV === 'production'
        ? { rejectUnauthorized: false }
        : false,
      max: 10,
      idleTimeoutMillis: 30_000,
      connectionTimeoutMillis: 5_000,
    });
  }
  return pool;
}

async function query(text, params = []) {
  // Helper tunggal untuk SELECT/INSERT/UPDATE/DELETE; catat query yang >1 detik.
  const p = getPool();
  const start = Date.now();
  try {
    const res = await p.query(text, params);
    return res;
  } finally {
    const dur = Date.now() - start;
    if (dur > 1000) {
      require('./logger').warn({ dur, text }, 'query lambat');
    }
  }
}

async function createSchema() {
  // Dijalankan sekali saat start (idempoten: CREATE TABLE IF NOT EXISTS). Membuat tabel operators, devices, readings, audit.
  const q = `
    CREATE TABLE IF NOT EXISTS operators (
      username      TEXT PRIMARY KEY,
      password_hash TEXT NOT NULL,
      created_at    TEXT NOT NULL,
      token_version INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS devices (
      device_id        TEXT PRIMARY KEY,
      secret           TEXT NOT NULL,
      label            TEXT NOT NULL,
      owner_id         TEXT NOT NULL,
      created_at       TEXT,
      last_seen_at     TEXT,
      last_seq         INTEGER NOT NULL DEFAULT 0,
      next_secret      TEXT,
      pending_commands JSONB NOT NULL DEFAULT '[]'::jsonb,
      node_power_save     BOOLEAN NOT NULL DEFAULT FALSE,
      gateway_power_save  BOOLEAN NOT NULL DEFAULT FALSE
    );

    CREATE TABLE IF NOT EXISTS readings (
      id            BIGSERIAL PRIMARY KEY,
      device_id     TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
      ts            TEXT NOT NULL,
      type          TEXT NOT NULL,
      node_msg_type TEXT,
      readings      JSONB NOT NULL DEFAULT '[]'::jsonb,
      seq           INTEGER,
      expire_at     TIMESTAMPTZ,
      created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE INDEX IF NOT EXISTS idx_readings_device_ts ON readings(device_id, ts DESC);
    CREATE INDEX IF NOT EXISTS idx_readings_expire_at ON readings(expire_at)
      WHERE expire_at IS NOT NULL;
    -- Indeks parsial untuk pembersih retensi (lib/retention.js): tanpa ini,
    -- DELETE ... WHERE expire_at < now() memindai SELURUH tabel tiap kali.
    -- Dibuat parsial (hanya baris ber-expire_at) supaya indeksnya kecil.

    CREATE TABLE IF NOT EXISTS audit (
      id        BIGSERIAL PRIMARY KEY,
      action    TEXT NOT NULL,
      operator  TEXT,
      device_id TEXT,
      dest      TEXT,
      cmd       TEXT,
      ip        TEXT,
      reason    TEXT,
      meta      JSONB,
      ts        TIMESTAMPTZ NOT NULL DEFAULT now()
    );
  `;
  await query(q);
}

async function seedInitialOperator() {
  // Opsional: jalan kalau SEED_ADMIN_USER & SEED_ADMIN_PASS diisi DAN operator itu belum ada (setup awal, tanpa hardcode credential).
  const seedUser = process.env.SEED_ADMIN_USER;
  const seedPass = process.env.SEED_ADMIN_PASS;
  if (!seedUser || !seedPass) return;

  const { rows } = await query('SELECT username FROM operators WHERE username = $1', [seedUser]);
  if (rows.length > 0) return; // sudah ada, lewati (idempoten)

  const bcrypt = require('bcryptjs');
  const hash = await bcrypt.hash(seedPass, 12);
  await query(
    'INSERT INTO operators (username, password_hash, created_at) VALUES ($1, $2, $3)',
    [seedUser, hash, new Date().toISOString()]
  );
  const logger = require('./logger');
  logger.info({ operator: seedUser }, 'Seeded initial operator from env');
}

async function initSchema() {
  await createSchema();
  // Pastikan kolom power-save ada; ALTER IF NOT EXISTS aman untuk tabel lama tanpa menghapus data.
  await query(
    'ALTER TABLE devices ADD COLUMN IF NOT EXISTS node_power_save BOOLEAN NOT NULL DEFAULT FALSE'
  ).catch(() => {});
  await query(
    'ALTER TABLE devices ADD COLUMN IF NOT EXISTS gateway_power_save BOOLEAN NOT NULL DEFAULT FALSE'
  ).catch(() => {});
  // Kolom token_version wajib di-ALTER juga untuk DB lama, agar login tak error "column does not exist".
  await query(
    'ALTER TABLE operators ADD COLUMN IF NOT EXISTS token_version INTEGER NOT NULL DEFAULT 0'
  ).catch(() => {});
  await seedInitialOperator();
}

module.exports = { getPool, query, initSchema };
// Route pakai query(); index.js memanggil initSchema() saat start.
