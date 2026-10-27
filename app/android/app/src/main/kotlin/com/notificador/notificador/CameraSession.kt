package com.notificador.notificador

import android.content.Context
import com.google.firebase.Timestamp
import com.google.firebase.firestore.DocumentChange
import com.google.firebase.firestore.DocumentReference
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import org.webrtc.AudioSource
import org.webrtc.AudioTrack
import org.webrtc.Camera2Enumerator
import org.webrtc.CameraVideoCapturer
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import java.util.Date

/// Captura a câmera e responde pedidos de visualização pelo Firestore, sem depender
/// do Flutter. A sinalização usa o mesmo esquema de groups/{código}/calls do app.
class CameraSession(
    private val context: Context,
    private val groupCode: String,
    private val deviceId: String,
    private val onFacingChanged: (String) -> Unit,
) {
    private val calls = FirebaseFirestore.getInstance().collection("groups/$groupCode/calls")
    private var eglBase: EglBase? = null
    private var factory: PeerConnectionFactory? = null
    private var capturer: CameraVideoCapturer? = null
    private var surfaceHelper: SurfaceTextureHelper? = null
    private var videoSource: VideoSource? = null
    private var audioSource: AudioSource? = null
    private var videoTrack: VideoTrack? = null
    private var audioTrack: AudioTrack? = null
    private var facing = "environment"
    private var callsRegistration: ListenerRegistration? = null
    private val peers = HashMap<String, Peer>()

    fun start(initialFacing: String) {
        facing = initialFacing
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(context).createInitializationOptions()
        )
        val egl = EglBase.create()
        eglBase = egl
        val pcFactory = PeerConnectionFactory.builder()
            .setVideoEncoderFactory(DefaultVideoEncoderFactory(egl.eglBaseContext, true, true))
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(egl.eglBaseContext))
            .createPeerConnectionFactory()
        factory = pcFactory

        val enumerator = Camera2Enumerator(context)
        val wantFront = facing == "user"
        val name = enumerator.deviceNames.firstOrNull { enumerator.isFrontFacing(it) == wantFront }
            ?: enumerator.deviceNames.firstOrNull()
            ?: throw IllegalStateException("Nenhuma câmera encontrada")
        val cam = enumerator.createCapturer(name, null)
            ?: throw IllegalStateException("Não consegui abrir a câmera")
        capturer = cam

        val helper = SurfaceTextureHelper.create("CaptureThread", egl.eglBaseContext)
        surfaceHelper = helper
        val vs = pcFactory.createVideoSource(cam.isScreencast)
        videoSource = vs
        cam.initialize(helper, context, vs.capturerObserver)
        cam.startCapture(1280, 720, 30)
        videoTrack = pcFactory.createVideoTrack("video0", vs)

        val audio = pcFactory.createAudioSource(MediaConstraints())
        audioSource = audio
        audioTrack = pcFactory.createAudioTrack("audio0", audio)

        listenForCalls()
    }

    /// Troca frontal/traseira sem reiniciar a transmissão (o track continua o mesmo).
    fun switchCamera() {
        val cam = capturer ?: return
        cam.switchCamera(object : CameraVideoCapturer.CameraSwitchHandler {
            override fun onCameraSwitchDone(isFrontCamera: Boolean) {
                facing = if (isFrontCamera) "user" else "environment"
                onFacingChanged(facing)
            }

            override fun onCameraSwitchError(errorDescription: String?) {}
        })
    }

    fun stop() {
        callsRegistration?.remove()
        callsRegistration = null
        peers.values.forEach { it.close() }
        peers.clear()
        capturer?.let {
            try {
                it.stopCapture()
            } catch (_: InterruptedException) {
            }
            it.dispose()
        }
        capturer = null
        videoTrack?.dispose()
        audioTrack?.dispose()
        videoSource?.dispose()
        audioSource?.dispose()
        surfaceHelper?.dispose()
        factory?.dispose()
        eglBase?.release()
        videoTrack = null
        audioTrack = null
        videoSource = null
        audioSource = null
        surfaceHelper = null
        factory = null
        eglBase = null
    }

    private fun listenForCalls() {
        callsRegistration = calls.whereEqualTo("targetId", deviceId).addSnapshotListener { snap, _ ->
            snap?.documentChanges?.forEach { change ->
                val callId = change.document.id
                if (change.type == DocumentChange.Type.REMOVED) {
                    peers.remove(callId)?.close()
                } else {
                    handleCall(change.document.reference, change.document.data)
                }
            }
        }
    }

    private fun handleCall(doc: DocumentReference, data: Map<String, Any>) {
        if (data["answer"] != null || peers.containsKey(doc.id)) return
        // Ignora pedidos antigos, de visualizações que já expiraram.
        val createdAt = (data["createdAt"] as? Timestamp)?.toDate() ?: return
        if (Date().time - createdAt.time > ANSWER_TIMEOUT_MS) return
        val offer = data["offer"] as? Map<*, *> ?: return
        val sdp = offer["sdp"] as? String ?: return
        answer(doc, sdp)
    }

    private fun answer(doc: DocumentReference, offerSdp: String) {
        val pcFactory = factory ?: return
        val rtc = PeerConnection.RTCConfiguration(
            listOf(PeerConnection.IceServer.builder(STUN_URL).createIceServer())
        )
        val regs = mutableListOf<ListenerRegistration>()
        // Candidatos que chegam antes da descrição remota são guardados e aplicados depois.
        val pendingCandidates = mutableListOf<IceCandidate>()
        var remoteReady = false

        val pc = pcFactory.createPeerConnection(rtc, object : PeerObserver() {
            override fun onIceCandidate(candidate: IceCandidate?) {
                if (candidate == null) return
                doc.collection("calleeCandidates").add(
                    mapOf(
                        "candidate" to candidate.sdp,
                        "sdpMid" to candidate.sdpMid,
                        "sdpMLineIndex" to candidate.sdpMLineIndex,
                    )
                )
            }
        }) ?: return
        val peer = Peer(pc, regs)
        peers[doc.id] = peer

        val streamIds = listOf("stream0")
        videoTrack?.let { pc.addTrack(it, streamIds) }
        audioTrack?.let { pc.addTrack(it, streamIds) }

        pc.setRemoteDescription(object : SdpAdapter() {
            override fun onSetSuccess() {
                pc.createAnswer(object : SdpAdapter() {
                    override fun onCreateSuccess(desc: SessionDescription?) {
                        if (desc == null) return
                        pc.setLocalDescription(SdpAdapter(), desc)
                        doc.update("answer", mapOf("sdp" to desc.description, "type" to "answer"))
                    }
                }, MediaConstraints())
                synchronized(pendingCandidates) {
                    remoteReady = true
                    pendingCandidates.forEach { pc.addIceCandidate(it) }
                    pendingCandidates.clear()
                }
            }
        }, SessionDescription(SessionDescription.Type.OFFER, offerSdp))

        regs += doc.collection("callerCandidates").addSnapshotListener { snap, _ ->
            snap?.documentChanges?.forEach { change ->
                if (change.type != DocumentChange.Type.ADDED) return@forEach
                val m = change.document.data
                val candidate = IceCandidate(
                    m["sdpMid"] as String,
                    (m["sdpMLineIndex"] as Number).toInt(),
                    m["candidate"] as String,
                )
                synchronized(pendingCandidates) {
                    if (remoteReady) pc.addIceCandidate(candidate) else pendingCandidates.add(candidate)
                }
            }
        }

        // Comandos do aparelho que está vendo (ex.: trocar a câmera).
        regs += doc.collection("commands").addSnapshotListener { snap, _ ->
            snap?.documentChanges?.forEach { change ->
                if (change.type == DocumentChange.Type.ADDED &&
                    change.document.getString("action") == "switch"
                ) {
                    switchCamera()
                }
            }
        }
    }

    private inner class Peer(private val pc: PeerConnection, private val regs: List<ListenerRegistration>) {
        fun close() {
            regs.forEach { it.remove() }
            pc.close()
            pc.dispose()
        }
    }

    companion object {
        private const val STUN_URL = "stun:stun.l.google.com:19302"
        private const val ANSWER_TIMEOUT_MS = 20_000L
    }
}

/// Observer do PeerConnection com implementações vazias: só sobrescreve o que usa.
open class PeerObserver : PeerConnection.Observer {
    override fun onSignalingChange(state: PeerConnection.SignalingState?) {}
    override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) {}
    override fun onIceConnectionReceivingChange(receiving: Boolean) {}
    override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) {}
    override fun onIceCandidate(candidate: IceCandidate?) {}
    override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}
    override fun onAddStream(stream: MediaStream?) {}
    override fun onRemoveStream(stream: MediaStream?) {}
    override fun onDataChannel(channel: org.webrtc.DataChannel?) {}
    override fun onRenegotiationNeeded() {}
    override fun onAddTrack(receiver: RtpReceiver?, streams: Array<out MediaStream>?) {}
}

/// SdpObserver com implementações vazias.
open class SdpAdapter : SdpObserver {
    override fun onCreateSuccess(desc: SessionDescription?) {}
    override fun onSetSuccess() {}
    override fun onCreateFailure(error: String?) {}
    override fun onSetFailure(error: String?) {}
}
