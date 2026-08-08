import 'package:flutter/material.dart';
import '../services/api_client.dart';
import '../theme.dart';

// Layar ganti password operator (pengganti default lemah 12345678).
// Wajib isi password lama (verifikasi) + password baru (minimal 8 char,
// divalidasi juga di server). Setelah berhasil, kembali ke layar sebelumnya.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _currentCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _done = false;

  @override
  void dispose() {
    _currentCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _error = null);
    final current = _currentCtrl.text;
    final newP = _newCtrl.text;
    final confirm = _confirmCtrl.text;

    if (newP.length < 8) {
      setState(() => _error = 'Password baru minimal 8 karakter.');
      return;
    }
    if (newP != confirm) {
      setState(() => _error = 'Konfirmasi password tidak cocok.');
      return;
    }

    setState(() => _busy = true);
    try {
      await ApiClient.instance.changePassword(current, newP);
      if (mounted) setState(() => _done = true);
      // Tunggu sebentar lalu kembali agar pengguna lihat konfirmasi.
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) Navigator.of(context).pop();
    } on Exception catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ganti Password')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_done)
                const Card(
                  color: AppColors.leaf,
                  child: Padding(
                    padding: EdgeInsets.all(AppSpacing.md),
                    child: Text('Password berhasil diubah.',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Text(_error!, style: TextStyle(color: AppColors.danger(context))),
                ),
              TextField(
                controller: _currentCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password lama',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _newCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password baru (min. 8 karakter)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _confirmCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Konfirmasi password baru',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Simpan Password Baru'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
