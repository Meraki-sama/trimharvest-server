# MANUAL BOOK — TrimHarvest (Cara Pakai Lengkap & Detail)

Untuk Bapak/Ibu yang baru mulai. Bahasa dibuat sesederhana mungkin.
Ikuti urutan nomor. Jangan loncat.

---

## BAGIAN 0 — Apa yang sudah siap (file hasil kerjaan)

Semua sudah di-compile, tinggal dipasang ke alat:

| Benda | Letak file | Kegunaan |
|---|---|---|
| Firmware Gateway (rumah) | `gateway-rumah/.pio/build/esp32dev/firmware.bin` | Otak penghubung di rumah |
| Firmware Node (sawah) | `node-sawah/.pio/build/ttgo-t-beam/firmware.bin` | Otak sensor di sawah/tanah |
| App HP (Android) | `monitor-app/build/app/outputs/flutter-apk/app-debug.apk` | Aplikasi di HP Bapak/Ibu |

> Folder utama: `C:\Users\Windows\Documents\TrimHarvest_perbaikan_dokfix\TrimHarvest\`

---

## BAGIAN 1 — Pasang Firmware ke Gateway (rumah)

**Pakai VS Code + PlatformIO (cara klik, bukan ketik perintah).**

1. Buka **VS Code**.
2. **File → Open Folder** → pilih folder `gateway-rumah` (di dalam folder TrimHarvest).
3. Cari ikon **PlatformIO** di bar kiri (logo semut/rumah hijau). Klik.
4. Tunggu sebentar, akan muncul **PROJECT TASKS → gateway-rumah → esp32-tunggu... → pilih `esp32dev`**.
5. Klik **`Erase Flash`** (ini membersihkan setting lama, termasuk WiFi "Yuka" yang bikin bermasalah tadi).
6. Setelah selesai, klik **`Upload`** (ini memasukkan firmware baru ke gateway).
7. Tunggu sampai muncul tulisan **`SUCCESS`**.

✅ Setelah ini, gateway BAPAK/IBU sudah pakai sistem baru (bisa reset total & otomatis balik ke mode setting kalau WiFi bermasalah).

---

## BAGIAN 2 — Pasang Firmware ke Node (sawah/tanah)

Cara SAMA seperti gateway, tapi folder & board beda:

1. **File → Open Folder** → pilih folder `node-sawah`.
2. PlatformIO → **PROJECT TASKS → node-sawah → `ttgo-t-beam`**.
3. Klik **`Upload`** (node ini nggak perlu Erase, cukup Upload).
4. Tunggu sampai **`SUCCESS`**.

✅ Node siap kirim data lewat radio ke gateway.

---

## BAGIAN 3 — Pasang App ke HP Android

1. Sambungkan HP ke laptop pakai kabel USB.
2. Copy file `app-debug.apk` ke HP (lewat kabel, atau kirim ke diri sendiri lewat WA).
3. Di HP, buka file `app-debug.apk` → ketuk **Install**.
4. Kalau muncul peringatan "Blokir dari sumber tak dikenal", nyalakan izinnya (ketuk **Setelannya → izinkan**).
5. Selesai. Ada icon **TrimHarvest** di layar HP.

---

## BAGIAN 4 — Pengaturan Awal (pertama kali buka app)

1. Buka app **TrimHarvest**.
2. App akan minta **URL Server**.
   - Kalau pakai server bawaan (Railway): tinggal ketuk **"Gunakan Server Default (Railway)"** lalu **"Simpan & Lanjutkan"**.
   - Kalau punya server sendiri: ketik alamatnya (contoh `https://server-anda.com`), jangan pakai garis miring di belakang.
3. Masuk ke layar **Login**. Isi username & password yang Bapak/Ibu buat saat daftar.
4. Selesai — masuk ke layar utama (dashboard).

---

## BAGIAN 5 — Hubungkan Gateway ke App (cara baru, lebih gampang)

Sekarang gateway sudah pakai firmware baru, jadi caranya lancar:

1. Colok listrik gateway.
2. Tunggu ±10 detik. Gateway akan pancarkan WiFi sendiri bernama **`Gateway-Setup-XXXX`** (XXXX = kode alat).
   - Kalau nggak muncul: **cabut lalu colok lagi listrik sambil menahan tombol reset** (tombol di kabel GPIO 4) ±3 detik.
3. Di HP Bapak/Ibu: buka **Setting WiFi** → pilih **`Gateway-Setup-XXXX`** → password: **`gateway-setup`**.
4. Buka browser HP → biasanya otomatis ke halaman, atau buka `http://192.168.4.1`.
5. Isi:
   - **WiFi rumah** (nama & password WiFi yang ada internetnya)
   - **URL Server** (sama seperti Bagian 4)
   - **Device ID & Secret** (didapat dari app: lihat Bagian 6)
6. Ketuk **Simpan**. Gateway restart sendiri.
7. Kembalikan HP Bapak/Ibu ke WiFi rumah seperti biasa.
8. Di app, device akan muncul & data mulai jalan.

---

## BAGIAN 6 — Tambah Device di App (dapatkan Device ID & Secret)

1. Di dashboard app, ketuk tombol **"+" (Tambah Device)**.
2. App akan minta Bapak/Ibu hubungkan ke WiFi `Gateway-Setup-XXXX` (lihat Bagian 5 langkah 3).
3. App kirim otomatis Device ID & Secret ke gateway.
4. Kembali ke WiFi rumah. Device muncul di dashboard dengan nama yang Bapak/Ibu berikan.

---

## BAGIAN 7 — Daftar Fitur & Cara Pakai

### 7.1 Buku Panduan (di dalam app)
- Ketuk ikon **buku** di kanan atas (AppBar) kapan saja.
- Isinya bahasa awam: cara colok, cara baca angka, cara kalibrasi, catatan kerusakan, hemat baterai, kalau ada masalah.
- Bukan tutorial pop-up, tapi buku yang bisa dibuka ulang kapan saja.

### 7.2 Jurnal Pemeliharaan (tab khusus)
- Di bawah ada tab **"Jurnal"**.
- Fungsi: catat kerusakan/perbaikan per bagian (Node, Gateway, Sensor, Baterai, PIR, Umum).
- Cara: ketuk **+** → pilih bagian → tulis catatan → bisa **pin** (sematkan) biar nempel di atas.
- Cocok untuk ingat "tanggal ganti baterai", "sensor mati tanggal sekian", dll.

### 7.3 Ganti Password
- Ikon **gembok** di kanan atas → isi password lama & baru.

### 7.4 Pengaturan Server (SETELAH login)
- Ikon **server/dns** di kanan atas.
- Buka kalau server pindah host (mis. Railway mau diganti server sendiri).
- Setelah simpan, app **otomatis logout** → login lagi pakai server baru.
- Field sudah berisi URL sekarang, jadi tinggal ketuk Simpan kalau nggak diubah.

### 7.5 Factory Reset Gateway (dari jauh, tanpa pegang alat)
- Masuk ke **detail device** (ketuk device di dashboard) → scroll ke bawah → tombol merah **"Factory Reset"**.
- Fungsi: hapus SEMUA setting gateway (WiFi, identitas, secret) → gateway jadi seperti baru.
- Pakai kalau mau berikan gateway ke orang lain, atau setting rusak.
- Ada dialog konfirmasi (karena nggak bisa dibatalkan).

### 7.6 Ganti WiFi Gateway (dari jauh)
- Di detail device → **"Ganti WiFi Gateway"** → isi nama & password WiFi baru.
- Gateway restart & nyambung ke WiFi baru (kalau gagal, otomatis balik ke mode setting).

### 7.7 Restart / Hemat (dari jauh)
- Detail device ada tombol **Restart Node**, **Hemat Node**, **Restart Gateway**, **Hemat Gateway**.
- "Hemat" = baterai awet (tetap nyala, cuma kirim lebih jarang).

### 7.8 Kalibrasi Sensor
- Detail device → **"Kalibrasi Sensor"** → ikuti petunjuk di layar.

---

## BAGIAN 8 — Troubleshooting (kalau ada masalah)

### Gateway nggak muncul di WiFi HP ("Gateway-Setup" nggak ada)
- **Penyebab umum:** setting lama nyangkut (kayak kasus WiFi "Yuka" tadi).
- **Solusi 1 (paling gampang):** colok listrik sambil **tahan tombol reset (GPIO 4)** ±3 detik → gateway jadi baru, WiFi setup muncul.
- **Solusi 2:** flash ulang pakai **Erase Flash** dulu (Bagian 1 langkah 5) lalu Upload.
- **Solusi 3 (firmware baru):** kalau WiFi nyambung tapi nggak ke server, gateway **otomatis balik ke mode setup** sendiri dalam beberapa detik — tinggal cek WiFi HP.

### App bilang "Server belum dikonfigurasi"
- Buka ikon server di kanan atas → isi URL → Simpan.

### Login gagal terus
- Cek URL server benar. Cek username/password. Coba logout lalu login lagi.

### Data nggak muncul di dashboard
- Pastikan node & gateway menyala & dalam jangkauan radio.
- Cek tab Jurnal untuk catat kerusakan.
- Di detail device ada status "HEMAT" — kalau hemat, data datang lebih jarang (wajar).

### Lupa password
- Hubungi pengelola server / lakukan reset lewat server (di luar app).

---

## BAGIAN 9 — Urutan Kerja Singkat (cheat sheet)

1. Flash gateway (Erase + Upload) → Bagian 1
2. Flash node (Upload) → Bagian 2
3. Install app di HP → Bagian 3
4. Buka app → set URL server → login → Bagian 4
5. Colok gateway → hubungkan HP ke WiFi `Gateway-Setup` → isi → Bagian 5
6. Tambah device di app → Bagian 6
7. Pakai fitur (buku panduan, jurnal, kalibrasi) → Bagian 7

---

*Manual ini dibuat untuk skripsi TrimHarvest. Semua firmware & app sudah di-compile dan siap dipasang.*
