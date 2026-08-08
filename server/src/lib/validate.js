// lib/validate.js — Validasi input terpusat pakai Joi. Jangan percaya req.body mentah; gagal → 400 jelas, bukan crash/anomali di logika bisnis.

const Joi = require('joi');

function validate(schema) {
  // Kembalikan middleware Express yang memvalidasi req.body terhadap schema.
  return (req, res, next) => {
    const { error, value } = schema.validate(req.body, {
      stripUnknown: true, // buang field tak dikenal
      abortEarly: false,  // kumpulkan semua error
      convert: true,      // konversi tipe otomatis (mis. "30" -> 30)
    });
    if (error) {
      const detail = error.details.map((d) => d.message).join('; ');
      return res.status(400).json({ ok: false, error: 'input_tidak_valid', detail });
    }
    req.validated = value; // hasil bersih bisa dipakai route kalau mau
    next();
  };
}

// Schema per endpoint.
const schemas = {
  login: Joi.object({
    username: Joi.string().min(3).max(64).required(),
    password: Joi.string().min(1).max(256).required(),
  }),

  refresh: Joi.object({
    refreshToken: Joi.string().min(10).required(),
  }),

  changePassword: Joi.object({
    currentPassword: Joi.string().min(1).max(256).required(),
    newPassword: Joi.string().min(8).max(256).required(),
    // Minimal 8 karakter agar password tak terlalu lemah.
  }),

  provisionDevice: Joi.object({
    label: Joi.string().max(64).allow('').optional(),
  }),

  ingest: Joi.object({
    type: Joi.string().valid('sensor', 'heartbeat').required(),
    seq: Joi.number().integer().min(0).max(0xffffffff).required(),
    node_msg_type: Joi.string().valid('core', 'calib').optional(),
    readings: Joi.array()
      .items(
        Joi.object({
          id: Joi.string().min(1).max(40).required(),
          value: Joi.alternatives().try(Joi.number(), Joi.boolean(), Joi.valid(null)).required(),
          unit: Joi.string().min(1).max(20).required(),
        })
      )
      .max(64)
      .optional(),
    uptime_s: Joi.number().integer().min(0).optional(),
  }),

  command: Joi.object({
    dest: Joi.string().valid('node', 'gateway').required(),
    cmd: Joi.string().min(1).max(40).required(),
    // Field bebas (plug & play) dibatasi tipe & panjang agar tak ada injection aneh.
    value: Joi.alternatives().try(Joi.number(), Joi.boolean()).optional(),
    on: Joi.boolean().optional(),
    ssid: Joi.string().max(64).optional(),
    password: Joi.string().max(256).optional(),
    dry_raw: Joi.number().optional(),
    wet_raw: Joi.number().optional(),
    target: Joi.string().valid('fork', 'cap', 'tds', 'all').optional(),
    raw0: Joi.number().optional(),
    ppm0: Joi.number().optional(),
    raw1: Joi.number().optional(),
    ppm1: Joi.number().optional(),
    new_secret: Joi.string().optional(),
  }).unknown(false),
  // unknown(false): tolak field di luar daftar untuk mencegah payload tak terduga.
};

module.exports = { validate, schemas };
