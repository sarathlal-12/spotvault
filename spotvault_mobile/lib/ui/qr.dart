import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_state.dart';

/// SpotVault links. They open the website, which hands them to the app
/// (or offers the download when SpotVault isn't installed):
///   Jam on this Wi-Fi:  https://spotvault-web.vercel.app/j?h=192.168.1.23&p=50510&n=Saad
///   Link to a PC:       https://spotvault-web.vercel.app/pc?h=192.168.1.10&p=50505&k=123456
/// spotvault://j?... and spotvault://pc?... work the same way.
const String kLinkBase = 'https://spotvault-web.vercel.app';

String jamLink(String host, int port, String name) =>
    Uri.parse('$kLinkBase/j').replace(queryParameters: {'h': host, 'p': '$port', 'n': name}).toString();

String pcLinkFor(String host, int port, String pin) =>
    Uri.parse('$kLinkBase/pc').replace(queryParameters: {'h': host, 'p': '$port', 'k': pin}).toString();

/// What a scanned code or opened link asks for.
class SpotLink {
  final String kind; // 'jam' or 'pc'
  final String host;
  final int port;
  final String name;
  final String pin;
  const SpotLink(this.kind, this.host, this.port, {this.name = '', this.pin = ''});

  static SpotLink? parse(String raw) {
    final u = Uri.tryParse(raw.trim());
    if (u == null) return null;
    final okHost = u.scheme == 'spotvault' || u.host.endsWith('spotvault-web.vercel.app');
    if (!okHost) return null;
    // spotvault://j?.. has "j" as the host; https://.../j?.. has it as the path.
    final what = (u.scheme == 'spotvault' ? u.host : u.pathSegments.firstOrNull) ?? '';
    final h = u.queryParameters['h'] ?? '';
    final p = int.tryParse(u.queryParameters['p'] ?? '');
    if (!RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h) || p == null) return null;
    if (what == 'j') return SpotLink('jam', h, p, name: u.queryParameters['n'] ?? '');
    if (what == 'pc') return SpotLink('pc', h, p, pin: (u.queryParameters['k'] ?? '').replaceAll(RegExp(r'\D'), ''));
    return null;
  }
}

/// A sheet with a big QR code, the link and a Copy button.
Future<void> showQrSheet(BuildContext context, {required String title, required String subtitle, required String link}) {
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: TextStyle(color: kText, fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(subtitle, textAlign: TextAlign.center, style: TextStyle(color: kMuted, fontSize: 13)),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22)),
            child: QrImageView(data: link, size: 230, backgroundColor: Colors.white, eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Color(0xFF111111)), dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: Color(0xFF111111))),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: link));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied. Send it to your friend.')));
            },
            icon: const Icon(Icons.link_rounded),
            label: const Text('Copy link'),
          ),
        ]),
      ),
    ),
  );
}

/// Opens the camera and returns the first SpotVault code it sees.
Future<SpotLink?> scanSpotLink(BuildContext context) {
  return Navigator.of(context).push<SpotLink>(MaterialPageRoute(builder: (_) => const _ScanScreen()));
}

class _ScanScreen extends StatefulWidget {
  const _ScanScreen();

  @override
  State<_ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<_ScanScreen> {
  final controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool done = false;
  String hint = 'Point the camera at the SpotVault code on the other screen.';

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.transparent, foregroundColor: Colors.white, title: const Text('Scan code')),
      body: Stack(children: [
        MobileScanner(
          controller: controller,
          onDetect: (capture) {
            if (done) return;
            for (final b in capture.barcodes) {
              final link = SpotLink.parse(b.rawValue ?? '');
              if (link != null) {
                done = true;
                HapticFeedback.mediumImpact();
                Navigator.pop(context, link);
                return;
              }
            }
            setState(() => hint = "That isn't a SpotVault code.");
          },
          errorBuilder: (context, error) => const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text("Can't use the camera. Allow camera access for SpotVault in Settings.", textAlign: TextAlign.center, style: TextStyle(color: Colors.white)),
            ),
          ),
        ),
        Center(
          child: Container(
            width: 250,
            height: 250,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(28), border: Border.all(color: Colors.white, width: 3)),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 48,
          child: Text(hint, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15)),
        ),
      ]),
    );
  }
}
