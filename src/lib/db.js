// ============================================================================
// lib/db.js — Koneksi & inisialisasi PostgreSQL (Railway Postgres).
// Menggantikan firebaseAdmin.js (Postgres). Di-require di index.js SEBELUM
// route lain dimuat, supaya kalau DATABASE_URL salah/tidak ada, server GAGAL
// START cepat (fail-fast) alih-alih error membingungkan saat request pertama.
//
// Pola akses: kita tidak meniru API Postgres (collection/doc), tapi pakai
// fungsi SQL eksplisit per kebutuhan. Semua akses lewat `query(...)`.
// ============================================================================

const { Pool } = require('pg');
// ^ Driver PostgreSQL resmi untuk Node.js. Railway inject env DATABASE_URL
//   (postgres://user:pass@host:port/db) otomatis ke service ini.

let pool;
// ^ Akan diisi instance Pool pada pertama dipakai. Di-cache di module scope
//   supaya koneksi dipakai ulang antar request (pooling).

function getPool() {
  // Lazy singleton: bikin pool saat pertama kali dipakai, bukan saat require,
  // supaya test yang stub module ini tidak memicu koneksi sungguhan.
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
  // Helper tunggal untuk SELECT/INSERT/UPDATE/DELETE.
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
  // Dijalankan SEKALI saat server start (idempoten: CREATE TABLE IF NOT
  // EXISTS). Membuat tabel pengganti koleksi Postgres:
  //   operators, devices, readings, audit.
  const q = `
    CREATE TABLE IF NOT EXISTS operators (
      username      TEXT PRIMARY KEY,
      password_hash TEXT NOT NULL,
      created_at    TEXT NOT NULL
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
      pending_commands JSONB NOT NULL DEFAULT '[]'::jsonb
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
  // OPSIONAL: hanya jalan kalau env SEED_ADMIN_USER & SEED_ADMIN_PASS diisi
  // DAN operator itu BELUM ada. Dipakai sekali saat setup pertama, lalu bisa
  // dihapus env-nya. Tidak hardcode credential di source.
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
  await seedInitialOperator();
}

module.exports = { getPool, query, initSchema };
// ^ Route langsung pakai `query`; index.js memanggil `initSchema()` saat start.
