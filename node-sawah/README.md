# iot-node-sawah

Firmware node sensor sawah (TTGO T-Beam, ESP32 + LoRa SX1276). Membaca
sensor TDS, Fork (konduktivitas tanah), Capacitive (kelembaban tanah),
PIR (gerak), dan baterai, lalu mengirim datanya lewat LoRa ke
`iot-gateway-rumah` dalam bentuk terenkripsi.

**Baca `/PROTOCOL.md` dan `/SECURITY.md` di root repo dulu** sebelum
mengubah apa pun — dua dokumen itu menjelaskan format data & skema
keamanan yang harus tetap sinkron dengan firmware gateway.

## Menjalankan

1. Buka folder ini sebagai project PlatformIO (VS Code + ekstensi
   PlatformIO, akan otomatis terdeteksi lewat `platformio.ini`).
2. **WAJIB**: edit `src/config.h`, ganti `LORA_PSK` dengan kunci acak baru
   (perintah ada di komentar file itu). Nilai ini harus SAMA PERSIS dengan
   `LORA_PSK` di `iot-gateway-rumah/src/config.h` pasangannya. Firmware
   TIDAK AKAN COMPILE kalau nilai ini masih placeholder (sengaja, supaya
   tidak ke-flash tanpa sadar dengan kunci contoh yang sudah publik).
3. `pio run --target upload` (atau tombol Upload di PlatformIO).
4. `pio device monitor` untuk melihat log Serial (115200 baud).

## Struktur kode

```
src/
  main.cpp          Entry point: setup()/loop(), susun & kirim data sensor,
                     proses perintah masuk dari gateway.
  config.h           Semua konstanta yang bisa diubah (pin, interval, LORA_PSK).
  sensors.h/.cpp     Pembacaan & pemfilteran sinyal TDS/Fork/Capacitive/PIR/baterai.
  calibration.h/.cpp Penyimpanan titik kalibrasi kustom (dari app) ke NVS.
  lora_node.h/.cpp   Kirim/terima paket LoRa (binary framing).
  lora_security.h/.cpp AES-128-CTR + HMAC-SHA256 + anti-replay (lihat /PROTOCOL.md).
```

## Kalau sensor kelihatan aneh

- **Baterai selalu 0%**: T-Beam punya beberapa revisi board dengan chip PMIC
  berbeda (AXP2101 vs AXP192 pada revisi lebih lama). Firmware ini memakai
  AXP2101 — cek revisi board fisikmu (tertulis di PCB) kalau battery monitor
  tidak terdeteksi (`"AXP2101 not detected"` di Serial).
- **Fork/Capacitive tidak akurat**: kalibrasi ulang lewat menu Kalibrasi di
  app (kirim titik kering/basah baru), tidak perlu flash ulang firmware.
- **Data tidak sampai ke gateway sama sekali**: pastikan `LORA_PSK` di
  firmware ini SAMA PERSIS dengan gateway — kalau beda satu karakter pun,
  HMAC akan selalu gagal dan gateway diam-diam membuang semua paket
  (dianggap noise/tidak sah), tanpa error yang jelas di sisi node.
