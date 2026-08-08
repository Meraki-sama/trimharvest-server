# TrimHarvest

Sistem pemantauan & kendali sawah/rumah: node sensor sawah (LoRa) →
gateway rumah (LoRa↔WiFi) → server API Gateway (Node.js) → Postgres
Postgres, dikendalikan lewat app Flutter. Lihat **`/PROTOCOL.md`** untuk
peta arsitektur & format data lengkap, dan **`/SECURITY.md`** untuk
panduan operasional keamanan (kunci, TLS, dst).

```
node-sawah/       Firmware ESP32 T-Beam + LoRa (sensor sawah)
gateway-rumah/     Firmware ESP32 DevKit + LoRa (jembatan ke internet)
server/            API Gateway Node.js (satu-satunya pihak yang bicara ke Postgres)
monitor-app/       App Flutter (kendali & pemantauan)
PROTOCOL.md        Spesifikasi format data & keamanan (baca ini duluan)
SECURITY.md        Panduan kunci/TLS/rotasi kredensial
```

## Urutan setup dari nol

Ikuti urutan ini -- tiap tahap butuh output dari tahap sebelumnya.

### 1. Postgres (database)

1. Siapkan instance Postgres (lokal atau layanan cloud, mis. Railway/Render/Neon).
2. Catat connection string `postgres://user:pass@host:5432/db` — ini dipakai
   sebagai `DATABASE_URL` di `.env` server (lihat langkah 2).
3. Server otomatis membuat skema tabel (`initSchema`) saat dijalankan pertama kali,
   jadi tidak perlu import SQL manual.

### 2. Server (Node.js)

```bash
cd server
cp .env.example .env
# edit .env: pastikan DATABASE_URL (postgres://...) benar,
# JWT_ACCESS_SECRET & JWT_REFRESH_SECRET (lihat /SECURITY.md cara membangkitkannya)
npm install
npm run create-operator -- admin   # buat akun operator pertama untuk app
npm start
```

Deploy ke server sungguhan (VPS/Cloud Run/dst) sebelum lanjut ke langkah
berikutnya -- gateway butuh URL server yang bisa diakses dari internet
rumahmu. Lihat `/SECURITY.md` bagian TLS untuk cara mengamankannya dengan
benar.

### 3. Firmware Node Sawah

```bash
cd node-sawah
# edit src/config.h: WAJIB isi LORA_PSK (kunci acak baru, lihat /SECURITY.md)
pio run --target upload
pio device monitor
```

### 4. Firmware Gateway Rumah

```bash
cd gateway-rumah
# edit src/config.h: WAJIB isi LORA_PSK (SAMA PERSIS dengan langkah 3),
# DEFAULT_SERVER_BASE_URL (URL server dari langkah 2)
pio run --target upload
pio device monitor
```

### 5. App Flutter

```bash
cd monitor-app
flutter create . --platforms=android,ios --org com.trimharvest --project-name trimharvest_monitor
flutter pub get
flutter run
```

Di app: masukkan URL server → login pakai akun operator dari langkah 2 →
tombol "Tambah Device" → ikuti alur provisioning (app akan memandu
menyambungkan gateway ke WiFi rumah & mengirim identitasnya).

## Kalau ada yang tidak jalan

Tiap sub-proyek punya `README.md` sendiri dengan bagian troubleshooting:
`node-sawah/README.md`, `gateway-rumah/README.md`,
`monitor-app/README.md`. Untuk masalah lintas-komponen (mis. "data tidak
sampai ke app sama sekali"), urutan pengecekan yang disarankan:

1. Node sawah: Serial Monitor menunjukkan `LoRa TX [r]: ...` tiap
   interval kirim? Kalau tidak, masalah ada di node itu sendiri
   (sensor/LoRa lokal, lihat `node-sawah/README.md`).
2. Gateway rumah: Serial Monitor menunjukkan `Data sensor diteruskan ke
   server.`? Kalau paket dari node tidak pernah muncul di sini, cek
   `LORA_PSK` SAMA PERSIS di kedua firmware (kalau beda, HMAC selalu
   gagal & paket dibuang diam-diam sebagai "noise").
3. Server: cek log (`npm start` mencetak tiap request lewat `morgan`).
   Kode selain 200 di respons ke gateway? Lihat pesan `error` di body
   respons (mis. `signature_tidak_valid` = device_secret tidak cocok,
   `timestamp_di_luar_jendela_toleransi` = jam gateway belum sinkron NTP
   atau meleset jauh dari jam server).
4. App: pull-to-refresh di dashboard, atau cek apakah `GET /api/devices`
   membalas device yang dimaksud lewat `curl`/Postman langsung ke server
   (pakai access token dari `POST /api/auth/login`) untuk mengisolasi
   apakah masalahnya di app atau di server.
