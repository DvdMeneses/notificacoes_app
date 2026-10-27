import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Controla o modo câmera. A câmera e a transmissão rodam no serviço nativo
/// (Kotlin), então continuam funcionando mesmo com o app fechado. Aqui só se
/// liga, desliga, troca a câmera e mostra o estado.
class CameraMonitor extends ChangeNotifier {
  CameraMonitor._();
  static final CameraMonitor instance = CameraMonitor._();

  static const _channel = MethodChannel('camera_native');

  // Textos da notificação fixa. {facing} vira "frontal" ou "traseira".
  // Para mudar as palavras, edite estas duas constantes.
  static const _notificationTitle = '';
  static const _notificationTextTemplate =
      ''
      '';

  bool _active = false;
  String? _error;
  // 'environment' = traseira, 'user' = frontal. Persistido entre sessões.
  String _facing = 'environment';

  bool get active => _active;
  String? get error => _error;
  bool get isFrontCamera => _facing == 'user';
  String get facingLabel => _facing == 'user' ? 'frontal' : 'traseira';

  /// Confere com o serviço nativo se a câmera continua ligada (ex.: desligada
  /// pelo botão da notificação enquanto o app estava fechado).
  Future<void> refresh() async {
    try {
      final running = await _channel.invokeMethod<bool>('isRunning') ?? false;
      final prefs = await SharedPreferences.getInstance();
      _facing = prefs.getString('cameraFacing') ?? 'environment';
      if (running != _active) {
        _active = running;
        notifyListeners();
      }
    } on PlatformException {
      // Sem serviço nativo disponível: mantém o estado atual.
    }
  }

  /// Liga a câmera pelo serviço nativo. Precisa ser chamado com o app aberto.
  Future<void> start() async {
    if (_active) return;
    _error = null;

    final prefs = await SharedPreferences.getInstance();
    final groupCode = prefs.getString('groupCode');
    final deviceId = prefs.getString('deviceId');
    if (groupCode == null || deviceId == null) {
      _error = 'Entre no grupo antes de ligar a câmera.';
      notifyListeners();
      return;
    }

    await _requestNotificationPermission();
    if (!await _requestMediaPermissions()) {
      _error = 'Permissão de câmera/microfone negada.';
      notifyListeners();
      return;
    }

    _facing = prefs.getString('cameraFacing') ?? 'environment';
    try {
      await _channel.invokeMethod('start', {
        'groupCode': groupCode,
        'deviceId': deviceId,
        'facing': _facing,
        'title': _notificationTitle,
        'text': _notificationTextTemplate,
      });
    } on PlatformException catch (e) {
      _error = 'Não consegui ligar a câmera: ${e.message}';
      notifyListeners();
      return;
    }
    _active = true;
    await prefs.setBool('cameraMode', true);
    notifyListeners();
  }

  /// Desliga a câmera e remove a notificação fixa.
  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } on PlatformException {
      // Se o serviço já tinha parado, não há o que fazer.
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('cameraMode', false);
    _active = false;
    notifyListeners();
  }

  /// Alterna entre câmera traseira e frontal, sem reiniciar a transmissão.
  Future<void> switchCamera() async {
    try {
      await _channel.invokeMethod('switch');
    } on PlatformException catch (e) {
      _error = 'Não consegui trocar a câmera: ${e.message}';
      notifyListeners();
      return;
    }
    _facing = _facing == 'environment' ? 'user' : 'environment';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cameraFacing', _facing);
    notifyListeners();
  }

  /// Abre a tela do Android para tirar o app das restrições de bateria.
  /// A própria pessoa pode desfazer isso nas configurações.
  static Future<void> requestBatteryExemption() async {
    try {
      await _channel.invokeMethod('batteryExemption');
    } on PlatformException {
      // Sem a tela disponível, nada a fazer.
    }
  }

  Future<void> _requestNotificationPermission() async {
    await FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  }

  /// Pede câmera e microfone pelo flutter_webrtc. Abre e fecha a captura só para
  /// o Android mostrar a permissão; a captura de verdade é do serviço nativo.
  Future<bool> _requestMediaPermissions() async {
    try {
      final s = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': true,
      });
      for (final t in s.getTracks()) {
        t.stop();
      }
      await s.dispose();
      return true;
    } catch (_) {
      return false;
    }
  }
}
