import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ble_peripheral/ble_peripheral.dart' as bp;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'library_store.dart';
import 'nearby.dart';

/// Bluetooth sharing: send songs to a phone nearby without Wi-Fi.
///
/// Two links:
/// - fast: Android ↔ Android (Nearby Connections) and iPhone ↔ iPhone
///   (Multipeer). Bluetooth finds the phone, the files go over a direct
///   Wi-Fi link. See P2pLink.kt and AppDelegate.swift.
/// - slow: iPhone ↔ Android over Bluetooth Low Energy (Apple allows nothing
///   faster between them). About 1–3 minutes a song.
///
/// The receiving phone opens Share → Receive, which makes it visible for
/// a few minutes. Both phones keep SpotVault open while songs move.
class BtPeer {
  final String id;
  final String name;

  /// True for the fast link (same kind of phone).
  final bool fast;
  final BluetoothDevice? device;
  BtPeer(this.id, this.name, this.fast, [this.device]);
}

/// BLE: one service per phone type, so each phone only lists phones of the
/// other type there (same-type phones use the fast link instead).
const _uuidAndroid = '5f2a0001-7a1c-4e47-9a5b-53504f545641';
const _uuidIphone = '5f2a0002-7a1c-4e47-9a5b-53504f545641';
const _rxUuid = '5f2a0010-7a1c-4e47-9a5b-53504f545641'; // sender → receiver
const _txUuid = '5f2a0011-7a1c-4e47-9a5b-53504f545641'; // receiver → sender (notify)
const _nameMaker = 0xFFFF; // manufacturer data id carrying the phone's name (Android)

String get _myService => Platform.isIOS ? _uuidIphone : _uuidAndroid;
String get _otherService => Platform.isIOS ? _uuidAndroid : _uuidIphone;

// ------------------------------------------------------------ BLE framing
/// Each BLE write is one frame: a type byte, then data.
class BleFrame {
  static const msgPart = 0x01, msgEnd = 0x02, fileStart = 0x10, fileData = 0x11, fileEnd = 0x12;

  /// Splits a JSON message into frames that fit [size] bytes each.
  static List<Uint8List> message(Map<String, dynamic> m, int size) {
    final bytes = utf8.encode(jsonEncode(m));
    final room = size - 1;
    final out = <Uint8List>[];
    for (var i = 0; i < bytes.length || i == 0; i += room) {
      final end = (i + room).clamp(0, bytes.length);
      final last = end >= bytes.length;
      out.add(Uint8List.fromList([last ? msgEnd : msgPart, ...bytes.sublist(i, end)]));
      if (last) break;
    }
    return out;
  }

  static Uint8List of(int type, [List<int> data = const []]) => Uint8List.fromList([type, ...data]);
}

/// Rebuilds messages and files from BLE frames, in order.
class BleFrameReader {
  final void Function(Map<String, dynamic> m) onMessage;
  final void Function(String name, File f) onFile;
  final Directory tmp;
  BleFrameReader({required this.onMessage, required this.onFile, required this.tmp});

  final _msg = BytesBuilder(copy: false);
  RandomAccessFile? _out;
  File? _file;
  String? _name;
  int _n = 0;

  void add(Uint8List frame) {
    if (frame.isEmpty) return;
    final data = Uint8List.sublistView(frame, 1);
    switch (frame[0]) {
      case BleFrame.msgPart:
        _msg.add(data);
      case BleFrame.msgEnd:
        _msg.add(data);
        try {
          onMessage(Map<String, dynamic>.from(jsonDecode(utf8.decode(_msg.takeBytes())) as Map));
        } catch (e) {
          debugPrint('bt: bad message $e');
        }
      case BleFrame.fileStart:
        _close();
        _name = utf8.decode(data);
        _file = File('${tmp.path}/ble_${DateTime.now().microsecondsSinceEpoch}_${_n++}');
        _out = _file!.openSync(mode: FileMode.write);
      case BleFrame.fileData:
        _out?.writeFromSync(data);
      case BleFrame.fileEnd:
        final f = _file, name = _name;
        _close();
        if (f != null && name != null) onFile(name, f);
    }
  }

  void _close() {
    _out?.closeSync();
    _out = null;
    _file = null;
    _name = null;
  }

  void dispose() => _close();
}

// ------------------------------------------------------------ service
class BtShareService extends ChangeNotifier {
  final LibraryStore store;
  final NearbyService nearby;
  BtShareService(this.store, this.nearby);

  static const _method = MethodChannel('spotvault/p2p');
  static const _events = EventChannel('spotvault/p2p/events');
  StreamSubscription? _eventSub;

  bool get supported => Platform.isAndroid || Platform.isIOS;

  // Receiving (visible to others).
  bool visible = false;
  DateTime? visibleUntil;
  Timer? _visibleTimer;

  // Sending.
  final Map<String, BtPeer> _peers = {};
  List<BtPeer> get peers => _peers.values.toList()..sort((a, b) => (b.fast ? 1 : 0) - (a.fast ? 1 : 0));
  bool scanning = false;
  StreamSubscription? _scanSub;

  /// What's being sent right now, for the sheet ("Sending 3 of 12…").
  String? sendStatus;

  // ---------------------------------------------------------------- setup
  Future<bool> _permissions() async {
    if (!Platform.isAndroid) return true; // iOS asks by itself the first time
    final asks = [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.nearbyWifiDevices,
      Permission.locationWhenInUse,
    ];
    final res = await asks.request();
    // Location only matters on older Android, Wi-Fi devices only on newer.
    bool ok(Permission p) => res[p]?.isGranted == true || res[p]?.isLimited == true;
    final sdkNew = ok(Permission.bluetoothScan) && ok(Permission.bluetoothConnect);
    return sdkNew || ok(Permission.locationWhenInUse);
  }

  void _listenNative() {
    _eventSub ??= _events.receiveBroadcastStream().listen((e) => _onNative(Map<String, dynamic>.from(e as Map)), onError: (_) {});
  }

  /// Short reason when Bluetooth can't be used, or null when it's fine.
  Future<String?> problem() async {
    if (!supported) return 'Bluetooth sharing works on phones.';
    if (!await _permissions()) return 'Allow Bluetooth (Nearby devices) for SpotVault in Settings.';
    try {
      if (await FlutterBluePlus.isSupported == false) return 'This phone has no Bluetooth.';
      final s = await FlutterBluePlus.adapterState.where((s) => s != BluetoothAdapterState.unknown).first.timeout(const Duration(seconds: 3));
      if (s != BluetoothAdapterState.on) return 'Turn on Bluetooth first.';
    } catch (_) {}
    return null;
  }

  // ---------------------------------------------------------------- receive
  /// Makes this phone visible to senders for [minutes].
  Future<String?> startReceiving({int minutes = 5}) async {
    final p = await problem();
    if (p != null) return p;
    _listenNative();
    await _tmpDir();
    await _method.invokeMethod('start', {'name': store.deviceName, 'advertise': true, 'discover': false});
    await _startBlePeripheral();
    visible = true;
    visibleUntil = DateTime.now().add(Duration(minutes: minutes));
    _visibleTimer?.cancel();
    _visibleTimer = Timer(Duration(minutes: minutes), () {
      // Keep going while songs are arriving.
      if (_rx.isEmpty) stopReceiving();
    });
    notifyListeners();
    return null;
  }

  Future<void> stopReceiving() async {
    _visibleTimer?.cancel();
    visible = false;
    visibleUntil = null;
    notifyListeners();
    try {
      await _method.invokeMethod('stop');
    } catch (_) {}
    try {
      await bp.BlePeripheral.stopAdvertising();
    } catch (_) {}
  }

  bool _peripheralReady = false;

  Future<void> _startBlePeripheral() async {
    try {
      if (!_peripheralReady) {
        await bp.BlePeripheral.initialize();
        bp.BlePeripheral.setWriteRequestCallback((device, char, offset, value) {
          if (char.toLowerCase() == _rxUuid && value != null) _bleIn(device, value);
          return null;
        });
        bp.BlePeripheral.setConnectionStateChangeCallback((device, connected) {
          if (!connected) _rxGone('ble:$device');
        });
        await bp.BlePeripheral.addService(bp.BleService(uuid: _myService, primary: true, characteristics: [
          bp.BleCharacteristic(
            uuid: _rxUuid,
            properties: [bp.CharacteristicProperties.write.index, bp.CharacteristicProperties.writeWithoutResponse.index],
            permissions: [bp.AttributePermissions.writeable.index],
          ),
          bp.BleCharacteristic(
            uuid: _txUuid,
            properties: [bp.CharacteristicProperties.notify.index, bp.CharacteristicProperties.read.index],
            permissions: [bp.AttributePermissions.readable.index],
          ),
        ]));
        _peripheralReady = true;
      }
      final name = utf8.encode(store.deviceName);
      await bp.BlePeripheral.startAdvertising(
        services: [_myService],
        // iPhone: the name goes in the advert. Android: setting it would rename
        // the whole phone, so it rides in the scan response instead.
        localName: Platform.isIOS ? store.deviceName : null,
        manufacturerData: Platform.isAndroid
            ? bp.ManufacturerData(manufacturerId: _nameMaker, data: Uint8List.fromList(name.take(24).toList()))
            : null,
        addManufacturerDataInScanResponse: true,
      );
    } catch (e) {
      debugPrint('bt: peripheral failed: $e');
    }
  }

  /// Incoming shares by link id ("p2p:<id>" or "ble:<device>").
  final Map<String, _Incoming> _rx = {};
  Directory? _tmp;

  Future<Directory> _tmpDir() async => _tmp ??= await getTemporaryDirectory();

  void _bleIn(String device, Uint8List frame) {
    final key = 'ble:$device';
    var r = _rx[key];
    if (r == null) {
      final tmp = _tmp ?? Directory.systemTemp;
      r = _rx[key] = _Incoming(key, (m) => _bleSend(device, m));
      r.reader = BleFrameReader(onMessage: (m) => _inOrder(key, () => _onMessage(key, m)), onFile: (n, f) => _inOrder(key, () => _onFile(key, n, f)), tmp: tmp);
    }
    r.reader!.add(frame);
  }

  Future<void> _bleSend(String device, Map<String, dynamic> m) =>
      bp.BlePeripheral.updateCharacteristic(characteristicId: _txUuid, value: Uint8List.fromList(utf8.encode(jsonEncode(m))), deviceId: device);

  /// Handles one share's messages and files strictly one after another, so
  /// "end" never overtakes the last song still being saved.
  void _inOrder(String key, Future<void> Function() job) {
    final r = _rx[key] ??= _Incoming(key, (msg) => _p2pSend(key.substring(4), msg));
    r.chain = r.chain.then((_) => job()).catchError((Object e) => debugPrint('bt: $e'));
  }

  Future<void> _onMessage(String key, Map<String, dynamic> m) async {
    final r = _rx[key];
    if (r == null) return;
    switch (m['t']) {
      case 'offer':
        final songs = [for (final s in (m['songs'] as List? ?? const [])) SongInfo.fromJson(Map<String, dynamic>.from(s as Map))];
        if (songs.isEmpty || nearby.onIncomingShare == null || nearby.receiving != null) {
          await r.reply({'t': 'answer', 'ok': false});
          return;
        }
        final from = '${m['from'] ?? 'Someone'}';
        final playlist = (m['playlist'] as String?)?.trim();
        final offer = IncomingShare(from, '', 0, '', songs, playlist == null || playlist.isEmpty ? null : playlist);
        var ok = false;
        try {
          ok = await nearby.onIncomingShare!(offer).timeout(const Duration(seconds: 90));
        } catch (_) {}
        await r.reply({'t': 'answer', 'ok': ok});
        if (!ok) return;
        r.offer = offer;
        r.folder = nearby.sharedFolder(offer);
        nearby.receiveTotal = songs.length;
        nearby.receiveDone = 0;
        nearby.receiving = 'Getting ${songs.length} song${songs.length == 1 ? '' : 's'} from $from over Bluetooth…';
        nearby.changed();
      case 'end':
        await _finish(key);
    }
  }

  Future<void> _onFile(String key, String name, File f) async {
    final r = _rx[key];
    final offer = r?.offer;
    if (r == null || offer == null) {
      _delete(f);
      return;
    }
    final bar = name.lastIndexOf('|');
    final id = bar < 0 ? name : name.substring(0, bar);
    final kind = bar < 0 ? 'audio' : name.substring(bar + 1);
    if (kind == 'art') {
      r.art[id] = f;
      return;
    }
    final song = offer.songs.where((s) => s.id == id).firstOrNull;
    if (song == null) {
      _delete(f);
      return;
    }
    final ok = await nearby.importShared(song, r.folder!, f, r.art.remove(id));
    if (!ok) r.failed++;
    nearby.receiveDone++;
    nearby.changed();
    await r.reply({'t': 'got', 'n': nearby.receiveDone});
  }

  Future<void> _finish(String key) async {
    final r = _rx.remove(key);
    if (r == null) return;
    r.reader?.dispose();
    for (final f in r.art.values) {
      _delete(f);
    }
    final missing = (r.offer?.songs.length ?? 0) - nearby.receiveDone + r.failed;
    nearby.receiving = missing <= 0 ? null : '$missing song${missing == 1 ? '' : 's'} could not be received.';
    nearby.changed();
    try {
      await r.reply({'t': 'done'});
    } catch (_) {}
    if (missing > 0) {
      Timer(const Duration(seconds: 8), () {
        nearby.receiving = null;
        nearby.changed();
      });
    }
    if (!visible) await stopReceiving();
  }

  void _rxGone(String key) {
    if (_rx.containsKey(key)) _inOrder(key, () => _finish(key));
  }

  void _delete(File f) {
    try {
      f.deleteSync();
    } catch (_) {}
  }

  // ---------------------------------------------------------------- native link
  final Map<String, Completer<bool>> _connecting = {};
  final Map<String, void Function(Map<String, dynamic>)> _senderInbox = {};

  Future<void> _p2pSend(String id, Map<String, dynamic> m) =>
      _method.invokeMethod('sendMessage', {'id': id, 'data': Uint8List.fromList(utf8.encode(jsonEncode(m)))});

  void _onNative(Map<String, dynamic> e) {
    final id = '${e['id'] ?? ''}';
    switch (e['type']) {
      case 'found':
        _peers['p2p:$id'] = BtPeer('p2p:$id', '${e['name'] ?? 'Phone'}', true);
        notifyListeners();
      case 'lost':
        _peers.remove('p2p:$id');
        notifyListeners();
      case 'connected':
        _connecting.remove(id)?.complete(true);
      case 'failed':
        _connecting.remove(id)?.complete(false);
      case 'disconnected':
        _connecting.remove(id)?.complete(false);
        _senderInbox[id]?.call({'t': 'gone'});
        _rxGone('p2p:$id');
      case 'message':
        final data = e['data'];
        if (data is! Uint8List) return;
        Map<String, dynamic> m;
        try {
          m = Map<String, dynamic>.from(jsonDecode(utf8.decode(data)) as Map);
        } catch (_) {
          return;
        }
        final inbox = _senderInbox[id];
        if (inbox != null) {
          inbox(m);
        } else {
          _inOrder('p2p:$id', () => _onMessage('p2p:$id', m));
        }
      case 'file':
        final f = File('${e['path']}');
        _inOrder('p2p:$id', () => _onFile('p2p:$id', '${e['name']}', f));
      case 'fileFailed':
        if (!'${e['name']}'.endsWith('|audio') || _rx['p2p:$id'] == null) return;
        _inOrder('p2p:$id', () async {
          _rx['p2p:$id']?.failed++;
          nearby.receiveDone++;
          nearby.changed();
        });
    }
  }

  // ---------------------------------------------------------------- send
  /// Looks for phones that are on Receive.
  Future<String?> scan() async {
    final p = await problem();
    if (p != null) return p;
    _listenNative();
    _peers.clear();
    scanning = true;
    notifyListeners();
    try {
      await _method.invokeMethod('start', {'name': store.deviceName, 'advertise': false, 'discover': true});
    } catch (e) {
      debugPrint('bt: native discovery failed: $e');
    }
    try {
      await _scanSub?.cancel();
      _scanSub = FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
          final ad = r.advertisementData;
          final maker = ad.manufacturerData[_nameMaker];
          var name = maker != null ? utf8.decode(maker, allowMalformed: true) : ad.advName;
          if (name.trim().isEmpty) name = Platform.isIOS ? 'Android phone' : 'iPhone';
          _peers['ble:${r.device.remoteId.str}'] = BtPeer('ble:${r.device.remoteId.str}', name, false, r.device);
        }
        notifyListeners();
      });
      await FlutterBluePlus.startScan(withServices: [Guid(_otherService)], timeout: const Duration(seconds: 25));
    } catch (e) {
      debugPrint('bt: ble scan failed: $e');
    }
    Timer(const Duration(seconds: 25), () {
      scanning = false;
      notifyListeners();
    });
    return null;
  }

  Future<void> stopScan() async {
    scanning = false;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    try {
      if (!visible) await _method.invokeMethod('stop');
    } catch (_) {}
  }

  /// Sends [tracks] to [to]. Returns null when done, or what went wrong.
  Future<String?> send(BtPeer to, List<Track> tracks, {String? playlistName}) async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    final link = to.fast ? _FastLink(this, to.id.substring(4)) : _BleLink(to.device!);
    try {
      sendStatus = 'Connecting to ${to.name}…';
      notifyListeners();
      if (!await link.open()) return "Couldn't connect to ${to.name}";
      sendStatus = 'Waiting for ${to.name} to accept…';
      notifyListeners();
      await link.send({
        't': 'offer',
        'from': store.deviceName,
        'playlist': playlistName,
        'songs': [for (final t in tracks) SongInfo.of(t, store).toJson()],
      });
      final answer = await link.next((m) => m['t'] == 'answer').timeout(const Duration(seconds: 100));
      if (answer['ok'] != true) return '${to.name} said no';
      var n = 0;
      for (final t in tracks) {
        n++;
        sendStatus = 'Sending $n of ${tracks.length}: ${t.title}';
        notifyListeners();
        final art = store.artFile(t);
        if (t.hasArt && art.existsSync()) await link.sendFile('${t.id}|art', art);
        await link.sendFile('${t.id}|audio', store.localFile(t));
      }
      await link.send({'t': 'end'});
      // Wait until they've saved everything (the fast link sends in the background).
      await link.next((m) => m['t'] == 'done' || m['t'] == 'gone').timeout(Duration(minutes: 2 + tracks.length * 2));
      return null;
    } on TimeoutException {
      return '${to.name} stopped answering';
    } catch (e) {
      debugPrint('bt: send failed: $e');
      return 'Sending stopped. Keep both phones close with SpotVault open.';
    } finally {
      sendStatus = null;
      notifyListeners();
      await link.close();
    }
  }
}

/// One incoming share, on either link.
class _Incoming {
  final String key;
  final Future<void> Function(Map<String, dynamic>) reply;
  _Incoming(this.key, this.reply);
  BleFrameReader? reader;
  IncomingShare? offer;
  String? folder;
  final Map<String, File> art = {};
  int failed = 0;
  Future<void> chain = Future.value();
}

/// A connection to the receiving phone.
abstract class _Link {
  final _inbox = StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, dynamic>> _early = [];

  void deliver(Map<String, dynamic> m) {
    _early.add(m);
    _inbox.add(m);
  }

  /// The next message matching [test] (including one that already arrived).
  Future<Map<String, dynamic>> next(bool Function(Map<String, dynamic>) test) {
    for (final m in _early) {
      if (test(m)) {
        _early.remove(m);
        return Future.value(m);
      }
    }
    return _inbox.stream.firstWhere(test).then((m) {
      _early.remove(m);
      return m;
    });
  }

  Future<bool> open();
  Future<void> send(Map<String, dynamic> m);
  Future<void> sendFile(String name, File f);
  Future<void> close();
}

class _FastLink extends _Link {
  final BtShareService s;
  final String id;
  _FastLink(this.s, this.id);

  @override
  Future<bool> open() async {
    final c = s._connecting[id] = Completer<bool>();
    s._senderInbox[id] = deliver;
    await BtShareService._method.invokeMethod('connect', {'id': id});
    return c.future.timeout(const Duration(seconds: 40), onTimeout: () => false);
  }

  @override
  Future<void> send(Map<String, dynamic> m) => s._p2pSend(id, m);

  @override
  Future<void> sendFile(String name, File f) => BtShareService._method.invokeMethod('sendFile', {'id': id, 'name': name, 'path': f.path});

  @override
  Future<void> close() async {
    s._senderInbox.remove(id);
    try {
      await BtShareService._method.invokeMethod('stop');
    } catch (_) {}
  }
}

class _BleLink extends _Link {
  final BluetoothDevice d;
  _BleLink(this.d);
  BluetoothCharacteristic? _rx;
  StreamSubscription? _sub;
  int _size = 20;

  @override
  Future<bool> open() async {
    await d.connect(timeout: const Duration(seconds: 20));
    final services = await d.discoverServices();
    for (final sv in services) {
      for (final c in sv.characteristics) {
        final u = c.uuid.str128.toLowerCase();
        if (u == _rxUuid) _rx = c;
        if (u == _txUuid) {
          await c.setNotifyValue(true);
          _sub = c.onValueReceived.listen((v) {
            try {
              deliver(Map<String, dynamic>.from(jsonDecode(utf8.decode(v)) as Map));
            } catch (_) {}
          });
        }
      }
    }
    _size = (d.mtuNow - 3).clamp(20, 512);
    return _rx != null && _sub != null;
  }

  Future<void> _write(Uint8List frame, {bool fast = false}) => _rx!.write(frame, withoutResponse: fast);

  @override
  Future<void> send(Map<String, dynamic> m) async {
    for (final f in BleFrame.message(m, _size)) {
      await _write(f);
    }
  }

  @override
  Future<void> sendFile(String name, File f) async {
    await _write(BleFrame.of(BleFrame.fileStart, utf8.encode(name)));
    final room = _size - 1;
    final raf = await f.open();
    try {
      final buf = Uint8List(room);
      var i = 0;
      while (true) {
        final n = await raf.readInto(buf);
        if (n <= 0) break;
        // Every 32nd chunk waits for a reply, so nothing piles up and drops.
        await _write(BleFrame.of(BleFrame.fileData, Uint8List.sublistView(buf, 0, n)), fast: ++i % 32 != 0);
      }
    } finally {
      await raf.close();
    }
    await _write(BleFrame.of(BleFrame.fileEnd));
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    try {
      await d.disconnect();
    } catch (_) {}
  }
}
