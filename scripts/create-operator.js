#!/usr/bin/env node
// ============================================================================
// scripts/create-operator.js — Membuat/mengganti password akun operator
// (pengguna app Flutter) lewat command line. SENGAJA tidak ada endpoint HTTP
// publik untuk signup -- sistem ini single-tenant (untuk pemilik sawah/rumah
// sendiri, bukan layanan multi-pengguna publik), jadi akun operator dibuat
// manual lewat akses server langsung (SSH/terminal), bukan lewat internet
// terbuka. Ini mengurangi luas serangan (attack surface): tidak ada endpoint
// publik yang bisa dipakai orang asing mendaftarkan diri sendiri.
//
// Pemakaian:
//   npm run create-operator -- <username>
// (akan diminta memasukkan password secara interaktif, tidak ditampilkan
// di layar & tidak masuk shell history)
// ============================================================================
'use strict';
// ^ Strict mode: menonaktifkan beberapa perilaku JS lama yang rawan bug
//   (mis. assignment ke variabel yang belum dideklarasikan).
const readline = require('readline');
// ^ Modul bawaan Node untuk membaca input interaktif dari terminal baris
//   demi baris.
const bcrypt = require('bcryptjs');
const db = require('../src/lib/db');
// ^ Reuse koneksi Firestore yang sama dengan server utama -- script ini
//   dijalankan terpisah (bukan lewat `node src/index.js`), tapi tetap
//   memakai kredensial Firebase yang sama dari .env.

function promptHidden(question) {
  // Helper: tampilkan `question` di terminal, lalu baca satu baris input
  // TANPA menampilkan karakter yang diketik (supaya password tidak
  // terlihat di layar/terekam di screen recording, dst).
  return new Promise((resolve) => {
    // ^ Dibungkus Promise supaya bisa dipakai dengan `await` di main().
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    // ^ Buat interface baca-tulis terminal standar.

    // Sembunyikan input password dengan menimpa output write bawaan.
    const originalWrite = rl._writeToOutput;
    // ^ CATATAN: `_writeToOutput` adalah API INTERNAL/tidak publik dari
    //   modul readline (diawali underscore, konvensi umum untuk "jangan
    //   dipakai dari luar, bisa berubah tanpa peringatan di versi Node
    //   berikutnya"). Dipakai di sini sebagai trik untuk mem-bypass
    //   perilaku default readline yang selalu menampilkan apa yang
    //   diketik user -- pendekatan yang berfungsi di versi Node saat ini,
    //   tapi secara teknis rapuh terhadap perubahan versi Node/readline di
    //   masa depan (kalau butuh solusi lebih tahan-lama, pertimbangkan
    //   library pihak ketiga seperti `read` atau `prompts` yang menangani
    //   ini secara resmi).
    let asked = false;
    // ^ Flag untuk membedakan: karakter PERTAMA yang ditulis rl (yaitu teks
    //   pertanyaan `question` itu sendiri) HARUS tetap ditampilkan, tapi
    //   karakter SESUDAHNYA (yaitu apa yang diketik user) harus disembunyikan.
    rl._writeToOutput = function hiddenWrite(stringToWrite) {
      // ^ Override method internal ini dengan versi kustom.
      if (!asked) {
        originalWrite.call(rl, stringToWrite);
        // ^ Panggilan PERTAMA (menampilkan teks pertanyaan) tetap
        //   ditampilkan normal.
        asked = true;
      } else if (stringToWrite === '\n' || stringToWrite === '\r\n') {
        // ^ Tetap tampilkan newline (Enter) supaya kursor terminal pindah
        //   baris dengan wajar setelah user selesai mengetik.
        originalWrite.call(rl, stringToWrite);
      }
      // karakter password lainnya sengaja tidak ditulis ke terminal
      // ^ Kasus lain (karakter password itu sendiri) TIDAK dipanggil
      //   originalWrite -- artinya tidak pernah benar-benar dicetak ke
      //   layar, walau readline tetap MENERIMA input itu secara internal.
    };
    rl.question(question, (answer) => {
      // ^ Tampilkan `question`, tunggu user menekan Enter, lalu callback
      //   ini dipanggil dengan seluruh baris yang diketik (`answer`).
      rl.close(); // Tutup interface readline (lepas kontrol dari stdin).
      resolve(answer); // Selesaikan Promise dengan password yang diketik.
    });
  });
}

async function main() {
  const username = process.argv[2];
  // ^ process.argv = ['node', 'create-operator.js', <argumen setelah -->]
  //   -- index [2] adalah argumen pertama setelah nama script, yaitu
  //   username yang diberikan lewat `npm run create-operator -- admin`.
  if (!username) {
    console.error('Pemakaian: npm run create-operator -- <username>');
    process.exit(1); // Keluar dengan kode error (bukan 0) -- konvensi CLI.
  }

  const password = await promptHidden(`Password baru untuk operator "${username}": `);
  console.log(); // newline setelah input tersembunyi
  // ^ Tambahan baris kosong murni kosmetik, supaya output berikutnya tidak
  //   menempel di baris yang sama dengan prompt password.

  if (password.length < 8) {
    // ^ Validasi minimal (panjang saja, tidak ada aturan kompleksitas
    //   karakter) -- cukup untuk mencegah password yang jelas terlalu
    //   lemah, tanpa membuat operator frustrasi dengan aturan yang
    //   berlebihan untuk sistem skala rumahan seperti ini.
    console.error('Password minimal 8 karakter.');
    process.exit(1);
  }

  const passwordHash = await bcrypt.hash(password, 12);
  // UPSERT: kalau username sudah ada, password-nya diganti (reset password).
  await db.query(
    `INSERT INTO operators (username, password_hash, created_at)
     VALUES ($1, $2, $3)
     ON CONFLICT (username) DO UPDATE SET password_hash = $2, created_at = $3`,
    [username, passwordHash, new Date().toISOString()]
  );

  console.log(`Operator "${username}" berhasil disimpan.`);
  process.exit(0); // Keluar dengan kode sukses (0).
}

main().catch((err) => {
  // ^ Penangan error paling luar -- kalau ada apa pun yang gagal di
  //   dalam main() (koneksi Firestore gagal, dst) dan tidak tertangkap di
  //   dalam, ditangkap di sini supaya script keluar dengan pesan jelas
  //   alih-alih "unhandled promise rejection" yang membingungkan.
  console.error('Gagal membuat operator:', err);
  process.exit(1);
});
