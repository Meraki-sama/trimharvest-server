# TrimHarvest — Spesifikasi Protokol & Arsitektur

Dokumen ini adalah **sumber kebenaran tunggal** untuk format data & aturan
keamanan yang dipakai oleh keempat komponen sistem. Kalau salah satu
komponen diubah, cek dokumen ini dulu supaya tetap sinkron dengan yang lain.

```
[Sensor Node/Sawah] --LoRa (AES-128-CTR + HMAC + rolling counter)--> [Gateway/Rumah]
                                                                            |
                                                                            | HTTPS
                                                                            | (HMAC per-request + timestamp)
                                                                            v
                                                                   [Node.js API Gateway]
                                                                            |
                                                                            | PostgreSQL client (pg)
                                                                            | (connection string, hanya
                                                                            |  ada di server -- tidak pernah
                                                                            |  bocor ke client/firmware)
                                                                            v
                                                                    [PostgreSQL Database]
                                                                            ^
                                                                            | HTTPS + JWT
                                                                            |
                                                                    [App Flutter]
```

Prinsip inti: **ESP32 (node & gateway) tidak pernah punya kredensial
Postgres apapun, dan app Flutter juga tidak pernah punya kredensial Postgres
**Satu-satunya pihak yang bicara ke PostgreSQL adalah server Node.js,
lewat driver `pg` (connection string `DATABASE_URL` yang hanya ada di
server). Tidak ada client/firmware yang memegang kredensial database —
semua akses data harus lewat API Gateway ini. Lapisan pertahanan kedua
ada di sisi database itu sendiri (user DB dengan hak terbatas, firewall
yang membatasi port hanya dari host server), sehingga kalau suatu saat
ada yang salah menaruh config di tempat yang salah, data tidak langsung
terbuka ke publik.**

---

## 1. Node Sawah → Gateway Rumah (LoRa)

### 1.0 Anggaran ukuran paket (PENTING — batas keras hardware)

Radio SX127x (dipakai T-Beam & modul LoRa gateway) punya FIFO **256 byte
keras** per paket, dan makin panjang paket makin rentan corrupt di jarak
jauh. Karena itu protokol ini SENGAJA:
- memakai **framing biner** (bukan membungkus ciphertext sebagai hex/base64
  di dalam JSON — itu akan menggandakan ukuran data sia-sia, lihat catatan
  desain di komentar `lora_security.cpp`),
- memakai **JSON ringkas berbentuk tuple/array** `[id, value, unit]`
  (bukan object `{"id":...,"value":...,"unit":...}`) untuk tiap sensor —
  menghemat ~15 byte/entri,
- **memisahkan data "inti" (dikirim tiap interval kirim) dari data
  "raw+kalibrasi" (dikirim lebih jarang, atau hanya saat layar Kalibrasi
  aktif)** — data raw/kalibrasi hanya berguna secara live saat pengguna
  sedang mengkalibrasi, tidak perlu memenuhi tiap paket rutin.

Dengan ini, paket data inti ≈ 140 byte dan paket kalibrasi ≈ 165 byte —
jauh di bawah batas 256 byte, menyisakan ruang untuk beberapa sensor baru
ke depan tanpa perlu redesain protokol.

### 1.1 Dua jenis body (sebelum dienkripsi) — Plug & Play JSON

Field wajib per entri sensor: **`[id, value, unit]`** — `id` (string bebas
unik), `value` (angka/bool, atau `null` kalau sensor sedang tidak valid,
mis. TDS saturasi — BUKAN angka sentinel seperti `-1`, supaya konsumen
generik cukup tahu `null` = tidak valid, untuk sensor apapun), `unit`
(string bebas: "ppm", "%", "V", "bool", "raw", dst). **Tidak ada nama
field yang di-hardcode** di gateway/server/app — semuanya loop generik
atas array `r`, jadi menambah sensor baru = cuma tambah 1 entri di
firmware node.

**Body tipe "r" (readings inti — dikirim tiap `sendIntervalMs`):**
```json
{"t":"r","r":[["tds",842.0,"ppm"],["fork",63,"%"],["cap",41,"%"],
             ["batt_v",3.94,"V"],["batt_pct",78,"%"],["motion",0,"bool"]]}
```

> **Kompensasi suhu TDS.** Nilai `tds` (ppm) sudah dikompensasi ke suhu
> rujukan **25 °C** di firmware node (koefisien **2 %/°C**, standar sensor
> TDS). Tanpa ini, bacaan TDS meleset saat suhu air berbeda dari suhu
> kalibrasi — relevan karena spec sensor mencantumkan operasi 5–50 °C.
> Suhu diambil dari PMIC **AXP2101** (T-Beam); ini *approksimasi* suhu air
> (suhu die chip, bukan probe di air). Untuk akurasi tinggi, pasang probe
> suhu air (DS18B20/NTC) dan definisikan `externalWaterTemperatureC()` —
> fungsi `readWaterTemperatureC()` ditandai `weak` sehingga definisi itu
> otomatis menggantikan default tanpa mengubah kode sensor. Kalau suhu
> tidak wajar (sensor rusak / PMIC absen), kompensasi dilewati dan ppm
> tetap memakai hasil interpolasi tabel kalibrasi apa adanya.

**Body tipe "c" (raw + status kalibrasi — dikirim tiap
`CALIB_BROADCAST_EVERY_N` kali interval kirim biasa, DAN dipercepat
otomatis selama layar Kalibrasi di app sedang aktif, lihat 1.5 perintah
`calib_stream`):**
```json
{"t":"c","r":[["tds_raw",1820,"raw"],["fork_raw",5400,"raw"],["cap_raw",9100,"raw"],
              ["tds_cal",0,"bool"],["fork_cal",1,"bool"],["cap_cal",0,"bool"]]}
```

### 1.2 Framing biner (yang benar-benar dikirim lewat radio)

Bukan JSON — murni byte, supaya tidak ada overhead encoding:

```
[0]      version (1 byte, = 0x01)
[1..4]   seq (uint32, big-endian)  -- juga dipakai sebagai nonce AES-CTR
[5..N-9] ciphertext (AES-128-CTR dari body JSON, panjang = panjang body asli persis, stream cipher jadi TANPA padding)
[N-8..N-1] mac (8 byte pertama HMAC-SHA256(MAC_KEY, version||seq||ciphertext)) -- encrypt-then-MAC
```

- `seq`: counter 32-bit naik terus, tidak pernah diulang selama pasangan
  PSK yang sama dipakai (disimpan di NVS, lihat catatan wear-leveling di
  firmware). Dipakai sebagai **nonce AES-CTR** — aman karena AES-CTR hanya
  butuh nonce UNIK & TIDAK PERNAH BERULANG per kunci, dan seq sudah
  menjamin itu (properti yang sama dipakai untuk anti-replay).
- `mac` dihitung atas **ciphertext**, bukan plaintext (encrypt-then-MAC),
  supaya penyerang tidak bisa mengubah ciphertext tanpa ketahuan.

Downlink (gateway → node, perintah kontrol) memakai framing yang SAMA
PERSIS, hanya body-nya beda bentuk (lihat bagian 1.5), dan pakai nomor
urut (seq) yang TERPISAH dari arah uplink (tiap arah pengiriman punya
counter sendiri, di kedua sisi).

### 1.3 Turunan kunci dari satu Pre-Shared Key (LORA_PSK)

Supaya konfigurasi cukup 1 nilai rahasia per pasangan node+gateway (bukan
2 kunci terpisah yang gampang salah tempel), 2 kunci turunan dihitung dari
`LORA_PSK` pakai SHA-256 dengan domain separation:

```
ENC_KEY (16 byte)  = SHA-256(LORA_PSK || "enc")[0:16]   -> kunci AES-128
MAC_KEY (32 byte)  = SHA-256(LORA_PSK || "mac")          -> kunci HMAC-SHA256
```

`LORA_PSK` HARUS identik persis di firmware node & gateway (pasangan
1-ke-1). Wajib dibangkitkan acak per pasangan perangkat, jangan pernah
memakai nilai contoh di repo ini — lihat `SECURITY.md` tiap firmware.

### 1.4 Nonce AES-CTR dari seq

Blok counter awal (16 byte) = 12 byte nol + `seq` sebagai big-endian
uint32 (4 byte). Karena `seq` dijamin naik terus dan tidak pernah dipakai
ulang (itulah properti anti-replay), blok counter ini juga dijamin tidak
pernah dipakai ulang — syarat keamanan AES-CTR terpenuhi tanpa perlu
mengirim IV terpisah lewat radio (hemat bandwidth LoRa yang sempit).

### 1.5 Perintah downlink (gateway → node)

Body sebelum dienkripsi (dibungkus dengan framing biner yang sama seperti
1.2, `seq` counter TERPISAH dari uplink, lihat firmware). Body downlink
tetap JSON biasa (bukan tuple) karena jauh lebih jarang dikirim daripada
uplink, jadi ukuran bukan masalah — kejelasan lebih penting di sini:

```json
{ "cmd": "set_interval", "value": 30 }
```

Command yang didukung: `restart`, `set_interval` (detik), `power_save`
(bool), `calib_set_fork` / `calib_set_cap` (`{dry_raw, wet_raw}`),
`calib_set_tds` (`{raw0, ppm0, raw1, ppm1}`), `calib_clear`
(`{target: "fork"|"cap"|"tds"|"all"}`), `calib_stream` (`{on: bool}`) —
saat `on: true`, node mengirim body tipe "c" (1.1) tiap interval kirim
biasa (bukan tiap `CALIB_BROADCAST_EVERY_N`), supaya layar Kalibrasi di
app dapat data raw yang responsif; app mengirim `calib_stream {on:false}`
begitu pengguna keluar dari layar Kalibrasi.

---

## 2. Gateway Rumah → Server Node.js (HTTPS)

### 2.1 Autentikasi per-request (HMAC, bukan token statis)

Setiap request dari gateway ke server ditandatangani pakai
`device_secret` (dibagikan sekali saat provisioning, tersimpan di NVS
gateway & di Postgres server — TIDAK PERNAH dikirim ulang lewat jaringan
setelah provisioning awal).

Header wajib:
```
X-Device-Id: <device_id>
X-Timestamp: <unix ms saat request dibuat>
X-Signature: hex(HMAC-SHA256(device_secret, device_id + "|" + timestamp + "|" + rawBody))
```

Server menolak request kalau:
- `device_id` tidak terdaftar,
- `timestamp` di luar jendela toleransi ±120 detik (defense terhadap
  replay lintas-jaringan, terpisah dari `seq` LoRa yang sudah menangani
  replay di lapisan radio),
- `X-Signature` tidak cocok dengan HMAC yang dihitung server pakai
  `device_secret` yang tersimpan,
- `seq` di dalam body lebih kecil atau sama dengan `lastSeq` tersimpan di
  Postgres untuk device itu (anti-replay lapis kedua, di atas
  HTTPS/internet, TERPISAH SEPENUHNYA dari seq LoRa di bagian 1 — ini
  counter monoton milik GATEWAY sendiri, dinaikkan tiap kali gateway
  memanggil `httpIngest()`, baik untuk data sensor MAUPUN heartbeat;
  desain ini sengaja dipisah dari seq LoRa supaya tiap lapisan protokol
  independen & lebih mudah dinalar/di-debug sendiri-sendiri).

### 2.2 Endpoint

`POST /api/ingest` — body:

```json
{ "type": "sensor", "seq": 42, "node_msg_type": "core",
  "readings": [ { "id": "tds", "value": 842.0, "unit": "ppm" }, ... ] }
```
atau
```json
{ "type": "heartbeat", "seq": 43, "uptime_s": 1234 }
```

`readings` di sini SUDAH dalam bentuk object `{id,value,unit}` (bukan
tuple ringkas seperti di bagian 1.1) — gateway yang mengonversinya saat
meneruskan dari node, karena di jalur HTTPS ukuran bukan kendala seperti
di LoRa, dan bentuk object lebih jelas dibaca/di-debug di sisi
server/app. `node_msg_type` (`"core"` atau `"calib"`) menandai apakah ini
body tipe "r" atau "c" dari node (lihat 1.1) — server/app bisa memilih
menyimpan histori grafik hanya dari `"core"` kalau mau (raw+kalibrasi
biasanya tidak perlu masuk histori jangka panjang).

Response (selalu 200 kalau autentikasi sukses, supaya gateway tidak perlu
logika retry rumit — kalau ada command yang tertunda, dititipkan di sini):

```json
{
  "ok": true,
  "commands": [
    { "dest": "node",    "cmd": "set_interval", "value": 30 },
    { "dest": "gateway", "cmd": "restart" },
    { "dest": "gateway", "cmd": "rekey", "new_secret": "..." }
  ]
}
```

Gateway meneruskan command dengan `dest: "node"` lewat LoRa downlink
(dibungkus ulang pakai amplop 1.2, field `dest` dibuang dulu sebelum
diteruskan -- lihat 1.5), dan mengeksekusi command `dest: "gateway"`
langsung.

CATATAN PENAMAAN PENTING: field routing ini SENGAJA dinamai `dest`
(destination), BUKAN `target` -- supaya tidak bentrok dengan field
`target` milik command `calib_clear` sendiri (lihat 1.5: `{"cmd":
"calib_clear", "target": "fork"}`), yang berada di objek JSON YANG SAMA
saat command itu dikirim (`{"dest":"node","cmd":"calib_clear","target":"fork"}`).
Dua konsep "target" yang berbeda (routing vs parameter kalibrasi) TIDAK
BOLEH memakai nama field yang sama dalam satu objek JSON.

---

## 3. App Flutter → Server Node.js (HTTPS + JWT)

- `POST /api/auth/login` — `{ username, password }` → `{ accessToken,
  refreshToken }`. Password operator di-hash bcrypt di server (bukan di
  Postgres Auth — server ini satu-satunya penjaga gerbang, sesuai
  arsitektur di atas).
- `POST /api/auth/refresh` — `{ refreshToken }` → `{ accessToken }`.
- Semua endpoint lain butuh header `Authorization: Bearer <accessToken>`.
- `GET /api/devices` — daftar device + skema sensor terakhir (untuk UI
  dinamis, lihat 4).
- `POST /api/devices` — provisioning device baru, server generate
  `device_id` + `device_secret` acak, balikan HANYA SEKALI ini ke app
  (app menampilkannya ke pengguna untuk dimasukkan manual ke gateway lewat
  layar setup WiFi/provisioning gateway).
- `GET /api/devices/:id/readings?limit=100` — histori data (untuk grafik).
- `POST /api/devices/:id/commands` — `{ dest, cmd, value?, ... }` —
  antre command untuk device (diambil gateway di respons `/api/ingest`
  berikutnya). `dest` harus `"node"` atau `"gateway"` (lihat catatan
  penamaan di bagian 2.2 kenapa bukan `target`).
- `POST /api/devices/:id/rekey` — ganti `device_secret` (device_id TETAP
  SAMA, sengaja tidak ikut diganti supaya tidak perlu migrasi dokumen
  Postgres) — server generate secret baru, antre command `rekey` untuk
  gateway, balikan nilai baru ke app SEKALI. Berguna kalau device_secret
  dicurigai bocor. Secret lama TETAP SAH dipakai sampai gateway benar-benar
  menerima & menerapkan command-nya (server menyimpan secret baru sebagai
  field transisi terpisah, bukan langsung menimpa secret aktif — kalau
  langsung ditimpa, request ingest gateway BERIKUTNYA yang justru
  seharusnya mengantarkan command rekey itu sendiri akan langsung gagal
  autentikasi lebih dulu, mengunci device secara permanen).

Access token JWT umur pendek (15 menit), refresh token umur panjang (30
hari) disimpan di `flutter_secure_storage`, BUKAN `shared_preferences`.

### 3.1 Pencabutan sesi (`token_version`)

Setiap token membawa klaim `tv` (token version) yang dicocokkan dengan kolom
`operators.token_version` **pada setiap request** (`middleware/operatorAuth.js`)
dan pada setiap refresh (`POST /api/auth/refresh`).

`POST /api/auth/change-password` menaikkan `token_version`, sehingga seluruh
access & refresh token lama langsung ditolak dengan
`401 sesi_sudah_dicabut_silakan_login_ulang`. Ini penting karena refresh token
berumur 30 hari: tanpa mekanisme ini, HP yang hilang atau dicuri tetap
memegang akses selama sebulan penuh walaupun password sudah diganti.

Agar perangkat yang **melakukan** penggantian tidak ikut terlempar keluar,
`change-password` membalas sepasang token baru:

```
POST /api/auth/change-password → { ok: true, accessToken, refreshToken }
```

App wajib menyimpan keduanya (lihat `changePassword()` di `api_client.dart`).

---

## 4. UI Dinamis (JSON-Driven) di App

App **tidak punya model Dart per-jenis-sensor**. Yang ada hanya model
generik:

```dart
class Reading {
  final String id;
  final num? value; // null kalau sensor lagi invalid
  final String unit;
}
```

Tampilan kartu metrik memilih ikon/warna/format berdasarkan **`unit`**
(generik: semua `unit == "%"` dirender sebagai gauge persentase, semua
`unit == "bool"` dirender sebagai chip status, semua `unit == "raw"`
disembunyikan dari dashboard utama dan hanya muncul di layar Kalibrasi,
sisanya dirender sebagai kartu angka+satuan biasa) — BUKAN berdasarkan
`id` yang di-hardcode. Menambah sensor baru dengan `unit` yang sudah
dikenal (mis. sensor pH dengan `unit: "pH"` → fallback ke kartu angka
biasa) otomatis tampil TANPA update kode app sama sekali.

---

## 5. Ringkasan properti keamanan per lapisan

| Lapisan | Kerahasiaan | Integritas | Anti-Replay |
|---|---|---|---|
| Node → Gateway (LoRa) | AES-128-CTR | HMAC-SHA256 (encrypt-then-MAC) | rolling counter (seq) |
| Gateway → Server (HTTPS) | TLS (HTTPS) | HMAC-SHA256 per-request + TLS | timestamp window + seq server-side |
| Server → Postgres | TLS + connection string | Driver `pg` (tepercaya penuh) | N/A (server tepercaya) |
| App → Server (HTTPS) | TLS (HTTPS) | JWT signature | expiry token pendek |
