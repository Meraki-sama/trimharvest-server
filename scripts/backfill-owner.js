#!/usr/bin/env node
// ============================================================================
// scripts/backfill-owner.js — Migrasi SATU KALI: sebelum fix multi-tenancy,
// baris `devices` tidak punya kolom `owner_id`, jadi query baru
// (WHERE owner_id = $1 -- lihat routes/devices.js) tidak akan menemukan
// device lama itu sama sekali. Script ini menandai semua device yang BELUM
// punya owner_id sebagai milik satu username tertentu (operator lama).
//
// Pemakaian:
//   node scripts/backfill-owner.js <username>
//
// Aman dijalankan berkali-kali (idempotent): device yang sudah punya
// owner_id dilewati, tidak ditimpa.
// ============================================================================
'use strict';
const db = require('../src/lib/db');

async function main() {
  const username = process.argv[2];
  if (!username) {
    console.error('Pemakaian: node scripts/backfill-owner.js <username>');
    process.exit(1);
  }

  const { rows: op } = await db.query(
    'SELECT username FROM operators WHERE username = $1',
    [username]
  );
  if (op.length === 0) {
    console.error(
      `Operator "${username}" tidak ditemukan di tabel "operators" -- cek ejaan, ` +
      `atau buat dulu lewat "npm run create-operator -- ${username}".`
    );
    process.exit(1);
  }

  const { rows: devices } = await db.query(
    'SELECT device_id FROM devices WHERE owner_id IS NULL OR owner_id = $1',
    [username]
  );
  // ^ Ambil device yang belum punya owner, ATAU sudah milik username ini
  //   (supaya idempoten: jalankan lagi tidak mengubah apa-apa).

  let updated = 0;
  let skipped = 0;
  for (const d of devices) {
    // Cek lagi per-device (race condition aman: UPDATE hanya kalau masih NULL)
    const { rows: chk } = await db.query(
      'SELECT owner_id FROM devices WHERE device_id = $1',
      [d.device_id]
    );
    if (chk[0].owner_id) {
      skipped += 1;
      continue;
    }
    await db.query(
      'UPDATE devices SET owner_id = $1 WHERE device_id = $2',
      [username, d.device_id]
    );
    updated += 1;
    console.log(`  device ${d.device_id} -> owner_id "${username}"`);
  }

  console.log(`Selesai. ${updated} device diisi owner_id, ${skipped} device dilewati (sudah punya owner_id).`);
  process.exit(0);
}

main().catch((err) => {
  console.error('Gagal backfill:', err);
  process.exit(1);
});
