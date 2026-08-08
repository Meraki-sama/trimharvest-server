#!/usr/bin/env node
// scripts/create-operator.js — Buat/ganti password akun operator lewat CLI (tak ada endpoint signup publik, sistem single-tenant). Pakai: npm run create-operator -- <username> (password diminta interaktif, tak tampil di layar).
'use strict';
// Strict mode: cegah perilaku JS lama yang rawan bug (assignment var tak dideklarasi).
const readline = require('readline');
// Baca input interaktif dari terminal baris demi baris.
const bcrypt = require('bcryptjs');
const db = require('../src/lib/db');
// Pakai koneksi Postgres (DATABASE_URL) yang sama dengan server utama.

function promptHidden(question) {
  // Tampilkan pertanyaan lalu baca input TANPA menampilkan karakter (password tak kelihatan).
  return new Promise((resolve) => {
    // Dibungkus Promise agar bisa await di main().
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    // Interface baca-tulis terminal standar.

    // _writeToOutput adalah API internal readline; dipakai sebagai trik menyembunyikan input (rapuh terhadap perubahan versi Node, tapi berfungsi saat ini).
    const originalWrite = rl._writeToOutput;
    // Flag: karakter PERTAMA (teks pertanyaan) tetap tampil, sisinya (password) disembunyikan.
    let asked = false;
    rl._writeToOutput = function hiddenWrite(stringToWrite) {
      // Override: tampilkan teks pertanyaan & newline, tapi jangan cetak karakter password.
      if (!asked) {
        originalWrite.call(rl, stringToWrite);
        asked = true;
      } else if (stringToWrite === '\n' || stringToWrite === '\r\n') {
        originalWrite.call(rl, stringToWrite);
      }
    };
    rl.question(question, (answer) => {
      // Tampilkan pertanyaan, tunggu Enter, lalu resolve dengan jawaban.
      rl.close();
      resolve(answer);
    });
  });
}

async function main() {
  const username = process.argv[2];
  // process.argv[2] = username dari `npm run create-operator -- admin`; kosong → keluar error.
  if (!username) {
    console.error('Pemakaian: npm run create-operator -- <username>');
    process.exit(1);
  }

  const password = await promptHidden(`Password baru untuk operator "${username}": `);
  console.log(); // Newline kosmetik setelah input tersembunyi.

  if (password.length < 8) {
    // Minimal 8 karakter; cukup cegah password terlalu lemah tanpa aturan berlebihan.
    console.error('Password minimal 8 karakter.');
    process.exit(1);
  }

  const passwordHash = await bcrypt.hash(password, 12);
  // UPSERT: username ada → reset password & naikkan token_version (cabut semua sesi lama, krusial kalau akun diretas/HP hilang).
  await db.query(
    `INSERT INTO operators (username, password_hash, created_at, token_version)
     VALUES ($1, $2, $3, 0)
     ON CONFLICT (username) DO UPDATE SET password_hash = $2, created_at = $3,
       token_version = operators.token_version + 1`,
    [username, passwordHash, new Date().toISOString()]
  );

  console.log(`Operator "${username}" berhasil disimpan.`);
  process.exit(0);
}

main().catch((err) => {
  // Tangkap error luar (mis. Postgres gagal) → keluar dengan pesan jelas, bukan unhandled rejection.
  console.error('Gagal membuat operator:', err);
  process.exit(1);
});
