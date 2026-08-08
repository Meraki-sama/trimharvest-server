#ifndef SENSORS_H
#define SENSORS_H
#include <Arduino.h>
#include <Wire.h>
// Library bawaan Arduino untuk komunikasi I2C (dipakai ADS1115 & OLED).
#include <Adafruit_ADS1X15.h>
// Driver ADC eksternal presisi tinggi (16-bit) -- dipakai membaca sensor
//   analog (fork/capacitive/TDS) yang butuh presisi lebih baik dari ADC
//   internal ESP32 (yang cuma 12-bit dan kurang linear).
#include <XPowersLib.h>
// Driver PMIC (Power Management IC) bawaan board TTGO T-Beam -- untuk
//   membaca status baterai/charging lebih akurat.

extern Adafruit_ADS1115 ads;
// `extern` = deklarasi bahwa variabel global `ads` (objek driver ADS1115)
//   didefinisikan SUNGGUHAN di sensors.cpp, file lain (mis. calibration.cpp
//   kalau perlu) bisa memakainya lewat #include "sensors.h" ini tanpa
//   mendefinisikan ulang objeknya sendiri.

int getAvg(uint8_t ch);
// Baca channel ADC `ch` dari ADS1115 sebanyak ADS_SAMPLE_COUNT kali
//   (config.h) dengan jeda ADS_SAMPLE_DELAY_US antar-sampel, kembalikan
//   RATA-RATA-nya -- dipakai sebagai dasar semua fungsi read*Sensor() di
//   bawah untuk mengurangi noise pembacaan tunggal.
void initSensors();
// Inisialisasi I2C bus & ADS1115 (Wire.begin, ads.begin) -- dipanggil
//   sekali di setup(), SETELAH initCalibration() (lihat calibration.h).
bool sensorsAdcOk();
// true kalau ADS1115 benar-benar terdeteksi di bus I2C saat initSensors()
//   (atau saat percobaan re-init berkala berhasil). Kalau false, SEMUA
//   pembacaan analog (TDS/fork/capacitive) TIDAK BISA DIPERCAYA -- chip ADC
//   tidak pernah terinisialisasi, jadi ads.readADC_SingleEnded() hanya
//   mengembalikan sampah. main.cpp WAJIB mengecek ini dan mengirim `null`
//   (bukan angka) untuk ketiga sensor itu, sesuai konvensi /PROTOCOL.md 1.1
//   ("null = sensor sedang tidak valid"). Tanpa ini, node akan mengirim
//   angka palsu yang terlihat wajar dan petani mengambil keputusan
//   pemupukan/penyiraman berdasarkan data yang salah.
void sensorsRetryAdc();
// Coba inisialisasi ulang ADS1115 kalau sebelumnya gagal (dipanggil
//   berkala dari loop()). Meniru pola retry yang sudah dipakai LoRa lewat
//   ensureLoRaReady() -- tanpa ini, kegagalan ADC sesaat saat boot (mis.
//   kabel I2C longgar sekejap) mengunci node dalam kondisi rusak sampai
//   di-restart manual, padahal unitnya dipasang jauh di tengah sawah.
float readTDSSensor();
// Baca sensor TDS (Total Dissolved Solids -- kandungan zat terlarut
//   dalam air, indikator kadar garam/pupuk terlarut), kembalikan dalam
//   satuan ppm (parts per million) hasil interpolasi kurva kalibrasi
//   (lihat TDS_CALIB_TABLE / calibration.h).
int readForkSensor();
// Baca sensor fork (probe garpu, indikator konduktivitas/kelembaban
//   tanah), kembalikan dalam PERSEN (0-100, dipetakan dari raw ADC lewat
//   titik kalibrasi kering/basah).
int readCapacitiveSensor();
// Baca sensor kelembaban tanah tipe kapasitif, kembalikan dalam PERSEN
//   (0-70 default, sesuai CAPACITIVE_SENSOR_MAX_PERCENT).

// Raw ADC mentah (hasil getAvg(), SEBELUM difilter/dipetakan ke %/ppm) dari
// pembacaan read*Sensor() TERAKHIR -- disertakan di tiap payload data yang
// dikirim ke app (lihat main.cpp sendSensorData()) supaya layar kalibrasi
// di app bisa menampilkan angka raw secara live saat pengguna menempatkan
// probe di kondisi referensi, tanpa perlu jalur perintah/respons terpisah
// lewat LoRa (yang lambat & half-duplex).
int lastTdsRaw();
int lastForkRaw();
int lastCapRaw();
// Ketiga fungsi ini TIDAK melakukan pembacaan ADC baru -- cuma
//   mengembalikan nilai raw yang disimpan (cache) dari pemanggilan
//   read*Sensor() PALING TERAKHIR. Pola "getter murah" ini menghindari
//   pembacaan ADC dobel (satu untuk nilai olahan, satu lagi untuk raw)
//   yang akan memperlambat siklus sampling & boros energi.

bool readPIRSensor();
// Baca status pin PIR SAAT INI (true = sedang mendeteksi gerakan).
bool consumeMotionEvent();
// Berbeda dari readPIRSensor(): fungsi ini mengembalikan true HANYA
//   SEKALI per kejadian gerakan (setelah true dikembalikan, flag internal
//   direset ke false sampai ada gerakan baru terdeteksi lagi, dengan
//   debounce PIR_DEBOUNCE_MS) -- pola "consume"/"ambil lalu habis" ini
//   cocok untuk event diskrit (mis. "kirim notifikasi gerakan sekali saja
//   per kejadian", bukan "terus-menerus selama PIR aktif").
int readBatteryRaw();
float readBatteryVoltage();
int readBatteryPercent();
void initBatteryMonitor();
// Fungsi terkait pemantauan baterai: raw ADC, tegangan hasil konversi,
//   persentase hasil interpolasi (BATTERY_LOW_VOLTAGE..BATTERY_FULL_VOLTAGE),
//   dan inisialisasi (setup awal PMIC/ADC baterai).
void calibrationPrint();
void calibrationPrintCap();
void calibrationPrintTds();
// Fungsi bantu DEBUG (mencetak nilai raw/kalibrasi ke Serial Monitor)
//   -- dipakai developer saat menentukan titik kalibrasi manual lewat
//   kabel USB, terpisah dari alur kalibrasi lewat app (lihat calibration.h).
void debugPrintPir();
// Cetak status PIR ke Serial -- alat bantu debug wiring/sensitivitas PIR.

#endif
