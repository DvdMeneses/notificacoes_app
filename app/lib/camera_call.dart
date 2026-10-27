import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

// STUN só descobre o endereço público de cada aparelho; o vídeo continua indo
// direto entre os dois. Sem TURN, a conexão falha em redes que bloqueiam conexão
// direta (comum em 4G de operadora).
const _rtcConfig = <String, dynamic>{
  'iceServers': <Map<String, dynamic>>[
    {'urls': 'stun:stun.l.google.com:19302'},
  ],
};

// Tempo máximo para o aparelho-câmera responder um pedido de visualização.
const _answerTimeout = Duration(seconds: 20);

/// Aparelho que vê: abre um pedido de visualização para o aparelho-câmera escolhido
/// e mostra o vídeo quando a conexão direta estiver pronta. Quem responde é o
/// serviço nativo do aparelho-câmera (CameraSession.kt), pelo mesmo Firestore.
class CameraViewPage extends StatefulWidget {
  const CameraViewPage({
    super.key,
    required this.groupCode,
    required this.targetId,
    required this.targetName,
  });

  final String groupCode;
  final String targetId;
  final String targetName;

  @override
  State<CameraViewPage> createState() => _CameraViewPageState();
}

class _CameraViewPageState extends State<CameraViewPage> {
  final _renderer = RTCVideoRenderer();
  final _callId = const Uuid().v4();
  RTCPeerConnection? _pc;
  DocumentReference<Map<String, dynamic>>? _doc;
  StreamSubscription? _answerSub;
  StreamSubscription? _candidateSub;
  Timer? _timeout;
  bool _answered = false;
  bool _connected = false;
  bool _muted = false;
  MediaStreamTrack? _remoteAudio;
  String _status = 'Pedindo a câmera…';

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await _renderer.initialize();
    final prefs = await SharedPreferences.getInstance();
    final deviceId = prefs.getString('deviceId') ?? '';

    final pc = await createPeerConnection(_rtcConfig);
    _pc = pc;
    pc.onTrack = (e) {
      if (e.track.kind == 'audio') _remoteAudio = e.track;
      if (e.streams.isEmpty) return;
      _renderer.srcObject = e.streams.first;
      if (!mounted) return;
      setState(() {
        _connected = true;
        _status = 'Ao vivo';
      });
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed &&
          mounted) {
        setState(() => _status =
            'Não consegui conectar. Confira se os dois estão no mesmo Wi-Fi.');
      }
    };
    // Só recebe: não envia nada deste aparelho para o outro.
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );

    final doc = FirebaseFirestore.instance
        .doc('groups/${widget.groupCode}/calls/$_callId');
    _doc = doc;
    pc.onIceCandidate = (c) => doc.collection('callerCandidates').add(c.toMap());

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    await doc.set({
      'callerId': deviceId,
      'targetId': widget.targetId,
      'createdAt': Timestamp.now(),
      'offer': {'sdp': offer.sdp, 'type': offer.type},
    });

    _timeout = Timer(_answerTimeout, () {
      if (!_connected && mounted) {
        setState(() => _status =
            '${widget.targetName} não respondeu. Confira se a câmera está ligada nele.');
      }
    });

    _answerSub = doc.snapshots().listen((snap) async {
      final answer = snap.data()?['answer'] as Map<String, dynamic>?;
      if (answer == null || _answered) return;
      _answered = true;
      await pc.setRemoteDescription(RTCSessionDescription(
          answer['sdp'] as String, answer['type'] as String));
      _candidateSub = doc.collection('calleeCandidates').snapshots().listen((s) {
        for (final change in s.docChanges) {
          if (change.type != DocumentChangeType.added) continue;
          final m = change.doc.data()!;
          pc.addCandidate(
              RTCIceCandidate(m['candidate'], m['sdpMid'], m['sdpMLineIndex']));
        }
      });
    });
  }

  /// Silencia o áudio que chega deste outro aparelho. Não mexe no volume do celular.
  Future<void> _toggleMute() async {
    final track = _remoteAudio;
    if (track == null) return;
    _muted = !_muted;
    await Helper.setVolume(_muted ? 0 : 1, track);
    if (mounted) setState(() {});
  }

  /// Pede ao aparelho-câmera para alternar entre frontal e traseira.
  Future<void> _switchCamera() async {
    await _doc?.collection('commands').add({'action': 'switch', 'at': Timestamp.now()});
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _answerSub?.cancel();
    _candidateSub?.cancel();
    // Apagar o pedido avisa o aparelho-câmera que a visualização terminou.
    _doc?.delete();
    _pc?.close();
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('Câmera de ${widget.targetName}'),
        actions: [
          IconButton(
            tooltip: _muted ? 'Ativar som' : 'Silenciar',
            icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
            onPressed: _connected ? _toggleMute : null,
          ),
          IconButton(
            tooltip: 'Trocar frontal/traseira',
            icon: const Icon(Icons.cameraswitch),
            onPressed: _connected ? _switchCamera : null,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _connected
                ? RTCVideoView(_renderer)
                : const Center(child: CircularProgressIndicator()),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_status,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }
}
