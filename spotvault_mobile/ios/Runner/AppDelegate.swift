import Flutter
import MultipeerConnectivity
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var p2p: P2pLink?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SpotVaultP2p") {
      p2p = P2pLink(messenger: registrar.messenger())
    }
  }
}

/// Fast phone-to-phone link between iPhones (Multipeer Connectivity: Bluetooth
/// and peer-to-peer Wi-Fi). Who may send what is decided in Dart (the Accept
/// prompt), so invitations are accepted here automatically.
class P2pLink: NSObject, FlutterStreamHandler, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate,
  MCNearbyServiceBrowserDelegate
{
  private static let service = "spotvault-p2p"
  private var events: FlutterEventSink?
  private var me = MCPeerID(displayName: "iPhone")
  private var session: MCSession?
  private var advertiser: MCNearbyServiceAdvertiser?
  private var browser: MCNearbyServiceBrowser?
  private var peers: [String: MCPeerID] = [:]

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    FlutterMethodChannel(name: "spotvault/p2p", binaryMessenger: messenger).setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
    FlutterEventChannel(name: "spotvault/p2p/events", binaryMessenger: messenger).setStreamHandler(self)
  }

  func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    events = eventSink
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    events = nil
    return nil
  }

  private func emit(_ map: [String: Any]) {
    DispatchQueue.main.async { self.events?(map) }
  }

  private func key(_ p: MCPeerID) -> String {
    let k = "\(p.displayName)#\(p.hash)"
    peers[k] = p
    return k
  }

  private func ensureSession() -> MCSession {
    if let s = session { return s }
    let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
    s.delegate = self
    session = s
    return s
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start":
      stopAll()
      let name = (args["name"] as? String) ?? "iPhone"
      me = MCPeerID(displayName: String(name.prefix(60)))
      _ = ensureSession()
      if (args["advertise"] as? Bool) == true {
        let a = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: nil, serviceType: P2pLink.service)
        a.delegate = self
        a.startAdvertisingPeer()
        advertiser = a
      }
      if (args["discover"] as? Bool) == true {
        let b = MCNearbyServiceBrowser(peer: me, serviceType: P2pLink.service)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
      }
      result(true)
    case "stop":
      stopAll()
      result(true)
    case "connect":
      guard let id = args["id"] as? String, let peer = peers[id], let b = browser else {
        result(FlutterError(code: "connect", message: "Phone not found", details: nil))
        return
      }
      b.invitePeer(peer, to: ensureSession(), withContext: nil, timeout: 30)
      result(true)
    case "disconnect":
      session?.disconnect()
      session = nil
      result(true)
    case "sendMessage":
      guard let id = args["id"] as? String, let peer = peers[id], let data = args["data"] as? FlutterStandardTypedData,
        let s = session
      else {
        result(FlutterError(code: "send", message: "Not connected", details: nil))
        return
      }
      do {
        try s.send(data.data, toPeers: [peer], with: .reliable)
        result(true)
      } catch {
        result(FlutterError(code: "send", message: error.localizedDescription, details: nil))
      }
    case "sendFile":
      guard let id = args["id"] as? String, let peer = peers[id], let name = args["name"] as? String,
        let path = args["path"] as? String, let s = session
      else {
        result(FlutterError(code: "send", message: "Not connected", details: nil))
        return
      }
      s.sendResource(at: URL(fileURLWithPath: path), withName: name, toPeer: peer) { error in
        DispatchQueue.main.async {
          if let e = error {
            result(FlutterError(code: "send", message: e.localizedDescription, details: nil))
          } else {
            result(0)
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func stopAll() {
    advertiser?.stopAdvertisingPeer()
    browser?.stopBrowsingForPeers()
    session?.disconnect()
    advertiser = nil
    browser = nil
    session = nil
  }

  // MARK: advertiser / browser
  func advertiser(
    _ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?,
    invitationHandler: @escaping (Bool, MCSession?) -> Void
  ) {
    emit(["type": "peer", "id": key(peerID), "name": peerID.displayName])
    invitationHandler(true, ensureSession())
  }

  func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
    emit(["type": "error", "message": error.localizedDescription])
  }

  func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
    emit(["type": "found", "id": key(peerID), "name": peerID.displayName])
  }

  func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
    emit(["type": "lost", "id": key(peerID)])
  }

  func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
    emit(["type": "error", "message": error.localizedDescription])
  }

  // MARK: session
  func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
    switch state {
    case .connected: emit(["type": "connected", "id": key(peerID)])
    case .notConnected: emit(["type": "disconnected", "id": key(peerID)])
    default: break
    }
  }

  func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
    emit(["type": "message", "id": key(peerID), "data": FlutterStandardTypedData(bytes: data)])
  }

  func session(
    _ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
    with progress: Progress
  ) {}

  func session(
    _ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
    at localURL: URL?, withError error: Error?
  ) {
    let id = key(peerID)
    guard error == nil, let url = localURL else {
      emit(["type": "fileFailed", "id": id, "name": resourceName])
      return
    }
    // The temporary file is deleted when this returns, so move it first.
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("p2p_\(UUID().uuidString)")
    do {
      try FileManager.default.moveItem(at: url, to: out)
      emit(["type": "file", "id": id, "name": resourceName, "path": out.path])
    } catch {
      emit(["type": "fileFailed", "id": id, "name": resourceName])
    }
  }

  func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
}
