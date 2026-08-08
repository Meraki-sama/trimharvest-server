import 'package:flutter/material.dart';

// route_transitions.dart — Transisi halaman kustom untuk mengurangi kesan
// "kaku" saat berpindah layar.
//
// SEBELUMNYA: seluruh app memakai `MaterialPageRoute` polos di setiap
// `Navigator.push`. Ini SEBENARNYA tidak salah (tetap memakai transisi
// platform default), tapi transisinya TERASA cepat/mendadak dan tidak
// konsisten dengan nuansa "tenang/hipnotis" yang jadi filosofi desain app
// ini (lihat theme.dart) -- perpindahan antar layar jadi satu-satunya
// bagian app yang tidak mengikuti bahasa desain "halus & lembut" itu.
//
// SEKARANG: `AppRoute.push(context, page)` menggantikan pola
// `Navigator.of(context).push(MaterialPageRoute(builder: (_) => page))`
// di seluruh app -- memberi transisi slide-dari-kanan + fade yang lebih
// lembut (280ms, easeOutCubic), TETAP mendukung generic type (`push<bool>`
// dst, dipakai add_device_screen & calibration_screen untuk mengembalikan
// nilai lewat `Navigator.pop(context, true)`), dan tetap mendukung tombol
// "kembali" & gestur swipe-back bawaan Flutter seperti biasa.
class AppRoute {
  static Future<T?> push<T>(BuildContext context, Widget page) {
    return Navigator.of(context).push<T>(_buildRoute<T>(page));
  }

  static Future<T?> pushReplacement<T, TO>(BuildContext context, Widget page) {
    return Navigator.of(context).pushReplacement<T, TO>(_buildRoute<T>(page));
  }

  static PageRoute<T> _buildRoute<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.06, 0), // geser tipis dari kanan, bukan full-screen slide
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }
}
