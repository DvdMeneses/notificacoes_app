import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'camera_call.dart';
import 'camera_monitor.dart';
import 'firebase_options.dart';

/// URL padrão do backend. Pode ser trocada pela tela (ícone de engrenagem).
/// Ex.: http://192.168.0.10:3000 (PC na rede local) ou https://seu-app.onrender.com
const defaultBackendUrl = 'https://notificacoes-back.onrender.com';

// importance.max = aparece como popup na tela (heads-up).
const _channel = AndroidNotificationChannel(
  'mensagens', // mesmo id do AndroidManifest (default_notification_channel_id)
  'Mensagens',
  description: 'Mensagens recebidas de outros aparelhos',
  importance: Importance.max,
);

final _localNotifications = FlutterLocalNotificationsPlugin();

/// Chave global para abrir diálogos em cima de qualquer tela.
final navigatorKey = GlobalKey<NavigatorState>();
bool _dialogOpen = false; // evita abrir dois diálogos ao mesmo tempo

List<String> _parseOptions(String? raw) {
  final out = <String>[];
  try {
    for (final o in (jsonDecode(raw ?? '[]') as List)) {
      out.add(o.toString());
    }
  } catch (_) {}
  return out;
}

/// Monta a notificação a partir dos dados do push. Com opções, vira uma
/// notificação de tela cheia (fullScreenIntent) que traz o app para a frente,
/// e cada opção também vira um botão. Usada em foreground e background.
Future<void> _showMessage(RemoteMessage message) async {
  final d = message.data;
  if ((d['body'] ?? '').toString().isEmpty) return;
  final options = _parseOptions(d['options']);

  // Guarda a pergunta pendente: o overlay (ou o diálogo) lê daqui.
  if (options.isNotEmpty) {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pendingMessage', jsonEncode(d));

    // Caminho preferido: overlay de sistema (aparece por cima de QUALQUER app,
    // em segundo plano, e só fecha quando responder).
    try {
      if (await FlutterOverlayWindow.isPermissionGranted()) {
        if (!await FlutterOverlayWindow.isActive()) {
          await FlutterOverlayWindow.showOverlay(
            height: WindowSize.fullCover,
            width: WindowSize.matchParent,
            alignment: OverlayAlignment.center,
            flag: OverlayFlag.defaultFlag, // focável: recebe toques e trava o "voltar"
            overlayTitle: d['title']?.toString() ?? 'Mensagem',
            overlayContent: 'Responda para continuar',
          );
        }
        return; // o overlay cuida de tudo; não precisa de notificação
      }
    } catch (_) {}
  }

  // No máximo 3 botões cabem na notificação; o resto responde pelo diálogo.
  final actions = [
    for (final opt in options.take(3))
      AndroidNotificationAction(
        opt, // o id da ação é o próprio texto da opção
        opt,
        showsUserInterface: true, // abre o app para garantir a gravação
        cancelNotification: true,
      ),
  ];

  await _localNotifications.show(
    id: (d['messageId'] ?? message.hashCode.toString()).hashCode,
    title: d['title'],
    body: d['body'],
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _channel.id,
        _channel.name,
        channelDescription: _channel.description,
        importance: Importance.max,
        priority: Priority.high,
        actions: actions,
        category: AndroidNotificationCategory.call,
        // Pergunta: notificação de tela cheia (traz o app) e FIXA.
        fullScreenIntent: options.isNotEmpty,
        ongoing: options.isNotEmpty,
        autoCancel: options.isEmpty,
      ),
    ),
    payload: jsonEncode({'messageId': d['messageId'], 'groupCode': d['groupCode']}),
  );
}

/// Grava a resposta no Firestore. Serve para o diálogo e para o botão da
/// notificação. Inicializa tudo que precisa, inclusive em isolate de background.
Future<void> _saveResponse(
    String groupCode, String messageId, String option) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  if (FirebaseAuth.instance.currentUser == null) {
    await FirebaseAuth.instance.signInAnonymously();
  }
  final prefs = await SharedPreferences.getInstance();
  final deviceId = prefs.getString('deviceId') ?? 'desconhecido';
  final deviceName = prefs.getString('deviceName') ?? 'Aparelho';
  await FirebaseFirestore.instance
      .doc('groups/$groupCode/messages/$messageId/responses/$deviceId')
      .set({
    'option': option,
    'name': deviceName,
    'at': FieldValue.serverTimestamp(),
  });
  await prefs.remove('pendingMessage');
}

/// Mostra a pergunta como caixa de diálogo em cima da tela. Com opções, só
/// fecha depois de responder (não dá para cancelar nem usar o "voltar").
Future<void> showQuestionDialog(Map<String, dynamic> data) async {
  final messageId = data['messageId']?.toString();
  final groupCode = data['groupCode']?.toString();
  if (messageId == null || groupCode == null || messageId.isEmpty) return;
  final options = _parseOptions(data['options']);
  final ctx = navigatorKey.currentContext;
  if (ctx == null || _dialogOpen) return;
  _dialogOpen = true;

  await showDialog<void>(
    context: ctx,
    barrierDismissible: options.isEmpty, // pergunta: obriga a responder
    builder: (c) => PopScope(
      canPop: options.isEmpty, // bloqueia o botão "voltar" quando há opções
      child: AlertDialog(
        title: Text(data['title']?.toString() ?? 'Mensagem'),
        content: Text(data['body']?.toString() ?? ''),
        actions: options.isEmpty
            ? [
                TextButton(
                    onPressed: () => Navigator.pop(c), child: const Text('OK'))
              ]
            : [
                for (final opt in options)
                  TextButton(
                    onPressed: () async {
                      await _saveResponse(groupCode, messageId, opt);
                      await _localNotifications.cancel(id: messageId.hashCode);
                      if (c.mounted) Navigator.pop(c);
                    },
                    child: Text(opt),
                  ),
              ],
      ),
    ),
  );
  _dialogOpen = false;
}

/// Lê uma pergunta pendente (salva quando a notificação chegou) e a mostra.
Future<void> checkPendingQuestion() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('pendingMessage');
  if (raw == null) return;
  try {
    await showQuestionDialog((jsonDecode(raw) as Map).cast<String, dynamic>());
  } catch (_) {}
}

/// Grava a resposta quando o usuário toca num botão DA NOTIFICAÇÃO.
Future<void> _saveResponseFromAction(NotificationResponse r) async {
  final option = r.actionId;
  if (option == null || option.isEmpty || r.payload == null) return;
  final ref = jsonDecode(r.payload!) as Map<String, dynamic>;
  final groupCode = ref['groupCode']?.toString();
  final messageId = ref['messageId']?.toString();
  if (groupCode == null || messageId == null) return;
  await _saveResponse(groupCode, messageId, option);
}

/// Isolate de background: mostra a notificação de tela cheia.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _localNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_channel);
  await _showMessage(message);
}

@pragma('vm:entry-point')
void notificationActionBackground(NotificationResponse r) {
  _saveResponseFromAction(r);
}

/// Cadastra/atualiza este aparelho no grupo. Roda no fundo em TODA abertura do
/// app, mesmo que a tela de gerenciamento nunca seja aberta, para que os
/// celulares "alvo" (que ficam só na tela branca) apareçam na lista e recebam
/// notificações.
Future<void> registerDevice(String groupCode) async {
  final prefs = await SharedPreferences.getInstance();
  var deviceId = prefs.getString('deviceId');
  if (deviceId == null) {
    deviceId = const Uuid().v4();
    await prefs.setString('deviceId', deviceId);
  }
  final name = prefs.getString('deviceName') ?? 'Aparelho';
  if (FirebaseAuth.instance.currentUser == null) {
    await FirebaseAuth.instance.signInAnonymously();
  }
  await FirebaseMessaging.instance.requestPermission();
  final token = await FirebaseMessaging.instance.getToken();
  if (token == null) return;
  await FirebaseFirestore.instance
      .doc('groups/$groupCode/devices/$deviceId')
      .set({
    'name': name,
    'token': token,
    'platform': 'android',
    'updatedAt': FieldValue.serverTimestamp(),
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);


  // Se o token mudar, reescreve o cadastro automaticamente (grupo guardado).
  FirebaseMessaging.instance.onTokenRefresh.listen((t) async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('groupCode');
    final id = prefs.getString('deviceId');
    if (code == null || id == null) return;
    await FirebaseFirestore.instance.doc('groups/$code/devices/$id').set({
      'name': prefs.getString('deviceName') ?? 'Aparelho',
      'token': t,
      'platform': 'android',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  });

  // Login anônimo e invisível: o usuário não vê tela de login, mas o backend
  // consegue recusar requisições que não vieram do app.
  if (FirebaseAuth.instance.currentUser == null) {
    await FirebaseAuth.instance.signInAnonymously();
  }

  await _localNotifications.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveNotificationResponse: _saveResponseFromAction,
    onDidReceiveBackgroundNotificationResponse: notificationActionBackground,
  );
  await _localNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_channel);

  // App aberto: mostra o overlay; sem permissão de overlay, usa o diálogo.
  FirebaseMessaging.onMessage.listen((m) async {
    await _showMessage(m);
    if (!await FlutterOverlayWindow.isPermissionGranted()) {
      await showQuestionDialog(m.data);
    }
  });
  // Tocou na notificação / abriu por tela cheia: mostra o diálogo (fallback).
  FirebaseMessaging.onMessageOpenedApp.listen((m) async {
    if (!await FlutterOverlayWindow.isPermissionGranted()) {
      await showQuestionDialog(m.data);
    }
  });

  runApp(const NotificadorApp());
}

class NotificadorApp extends StatefulWidget {
  const NotificadorApp({super.key});

  @override
  State<NotificadorApp> createState() => _NotificadorAppState();
}

class _NotificadorAppState extends State<NotificadorApp>
    with WidgetsBindingObserver {
  bool _loading = true;
  String? _groupCode; // grupo em que este aparelho está (null = ainda não entrou)
  bool _unlocked = false; // tela de gerenciamento aberta nesta sessão

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Ao voltar para o app, mostra a pergunta pendente (se houver).
    if (state == AppLifecycleState.resumed) {
      checkPendingQuestion();
      // A câmera pode ter sido desligada pela notificação enquanto o app estava fechado.
      CameraMonitor.instance.refresh();
    }
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _groupCode = prefs.getString('groupCode');
    // Já faz parte de um grupo: cadastra no fundo (mesmo ficando na tela branca).
    if (_groupCode != null) {
      registerDevice(_groupCode!);
    }
    setState(() => _loading = false);
    // O serviço da câmera pode seguir rodando em nativo: confere o estado real.
    CameraMonitor.instance.refresh();
    // Se o app abriu por causa de uma pergunta, mostra o diálogo.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => checkPendingQuestion());
  }

  /// Chamado pela tela branca quando a senha é digitada.
  /// Retorna true se destravou (abre o gerenciamento).
  Future<bool> _unlock(String code) async {
    final prefs = await SharedPreferences.getInstance();
    if (_groupCode == null) {
      // Primeira vez neste aparelho: entra no grupo.
      await prefs.setString('groupCode', code);
      _groupCode = code;
      await registerDevice(code);
      setState(() => _unlocked = true);
      return true;
    }
    // Já está num grupo: só abre o gerenciamento se a senha bater.
    if (code == _groupCode) {
      setState(() => _unlocked = true);
      return true;
    }
    return false; // senha errada → continua na tela branca
  }

  Future<void> _leaveGroup() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('groupCode');
    setState(() {
      _groupCode = null;
      _unlocked = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Serviços do sistema',
      navigatorKey: navigatorKey,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: _loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : (!_unlocked || _groupCode == null)
              ? GatePage(onUnlock: _unlock)
              : HomePage(
                  key: ValueKey(_groupCode),
                  groupCode: _groupCode!,
                  onLock: () => setState(() => _unlocked = false),
                  onLeave: _leaveGroup,
                ),
    );
  }
}

// ---------------------------------------------------------------------------
// Entrada discreta: tela branca. 5 toques revelam o campo de senha.
// A senha é a chave do grupo: use a MESMA senha nos três celulares para que
// eles apareçam na mesma lista. Trate-a como senha (8 a 32 letras/números).
// ---------------------------------------------------------------------------

class GatePage extends StatefulWidget {
  const GatePage({super.key, required this.onUnlock});

  /// Recebe a senha digitada; retorna true se destravou.
  final Future<bool> Function(String code) onUnlock;

  @override
  State<GatePage> createState() => _GatePageState();
}

class _GatePageState extends State<GatePage> {
  final _password = TextEditingController();
  int _taps = 0;
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);
  bool _revealed = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Redesenha quando a câmera liga/desliga (pra mostrar/esconder o aviso).
    CameraMonitor.instance.addListener(_onMonitorChange);
  }

  @override
  void dispose() {
    CameraMonitor.instance.removeListener(_onMonitorChange);
    _password.dispose();
    super.dispose();
  }

  void _onMonitorChange() {
    if (mounted) setState(() {});
  }

  void _onTap() {
    // Conta 5 toques seguidos (reinicia se demorar mais de 2s entre eles).
    final now = DateTime.now();
    _taps = now.difference(_lastTap) > const Duration(seconds: 2) ? 1 : _taps + 1;
    _lastTap = now;
    if (_taps >= 5 && !_revealed) setState(() => _revealed = true);
  }

  Future<void> _enter() async {
    // A senha vira o código do grupo. Precisa ser igual em todos os aparelhos.
    final code =
        _password.text.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (code.length < 8 || code.length > 32) {
      setState(() => _error = 'Use de 8 a 32 letras ou números.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.onUnlock(code);
    if (!ok && mounted) {
      setState(() {
        _busy = false;
        _error = 'Senha incorreta.';
        _password.clear();
      });
    }
    // Se destravou, o app troca de tela sozinho.
  }

  Widget _recordingNotice(CameraMonitor monitor) {
    // Aviso bem visível de que a câmera está sendo coletada. Nada escondido.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.videocam, color: Colors.red, size: 48),
        const SizedBox(height: 12),
        const Text('GRAVANDO',
            style: TextStyle(
                color: Colors.red,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 2)),
        const SizedBox(height: 8),
        const Text('Câmera ativa — este aparelho está transmitindo.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Idle: tela branca (aparelho que só envia/visualiza). Quando a câmera está
    // ativa, mostra o aviso "GRAVANDO" em vez do branco.
    final monitor = CameraMonitor.instance;
    final recording = monitor.active;
    return Scaffold(
      backgroundColor: recording ? Colors.black : Colors.white,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onTap,
        child: Center(
          child: !_revealed
              ? (recording
                  ? _recordingNotice(monitor)
                  : const SizedBox.expand())
              : Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: _password,
                        obscureText: true,
                        autofocus: true,
                        enabled: !_busy,
                        textCapitalization: TextCapitalization.characters,
                        onSubmitted: (_) => _enter(),
                        decoration: InputDecoration(
                          labelText: 'Senha',
                          border: const OutlineInputBorder(),
                          errorText: _error,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _busy ? null : _enter,
                        child: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Entrar'),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tela principal: registra este aparelho e envia para os selecionados.
// ---------------------------------------------------------------------------

enum ConnStatus { conectando, conectado, desconectado, erro }

enum RespType { nenhuma, simNao, personalizada }

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.groupCode,
    required this.onLock,
    required this.onLeave,
  });

  final String groupCode;
  final VoidCallback onLock; // volta à tela branca SEM remover o aparelho
  final VoidCallback onLeave; // remove o aparelho do grupo

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _options = TextEditingController();
  final _selected = <String>{};
  RespType _respType = RespType.nenhuma;

  late final TabController _tabs = TabController(length: 2, vsync: this);
  String? _deviceId;
  String? _deviceName;
  String? _token;
  String _backendUrl = defaultBackendUrl;
  ConnStatus _status = ConnStatus.conectando;
  String _statusDetail = '';
  bool _sending = false;
  bool _overlayOk = true; // permissão "sobrepor a outros apps"
  Map<String, String> _lastResults = {};

  CollectionReference<Map<String, dynamic>> get _devicesRef =>
      FirebaseFirestore.instance.collection('groups/${widget.groupCode}/devices');

  CollectionReference<Map<String, dynamic>> get _messagesRef =>
      FirebaseFirestore.instance.collection('groups/${widget.groupCode}/messages');

  @override
  void initState() {
    super.initState();
    _setup();
    // Ao tocar na notificação, abre a aba Mensagens.
    FirebaseMessaging.instance.getInitialMessage().then((m) {
      if (m != null && mounted) _tabs.animateTo(1);
    });
    FirebaseMessaging.onMessageOpenedApp.listen((_) {
      if (mounted) _tabs.animateTo(1);
    });
  }

  Future<void> _setup() async {
    final prefs = await SharedPreferences.getInstance();
    _deviceId = prefs.getString('deviceId');
    if (_deviceId == null) {
      _deviceId = const Uuid().v4();
      await prefs.setString('deviceId', _deviceId!);
    }
    _backendUrl = prefs.getString('backendUrl') ?? defaultBackendUrl;
    _deviceName = prefs.getString('deviceName');
    setState(() {});

    if (_deviceName == null && mounted) {
      final name = await _askText('Nome deste aparelho', 'Ex.: Celular João');
      _deviceName = (name == null || name.isEmpty) ? 'Aparelho' : name;
      await prefs.setString('deviceName', _deviceName!);
    }

    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        _setStatus(ConnStatus.erro, 'Permissão de notificação negada');
        return;
      }
      _token = await FirebaseMessaging.instance.getToken();
      await _registerDevice(); // (o refresh de token é tratado globalmente)
    } catch (e) {
      _setStatus(ConnStatus.erro, 'FCM: $e');
      return;
    }
    await _refreshOverlayPermission();
    await _checkBackend();
  }

  Future<void> _refreshOverlayPermission() async {
    try {
      final ok = await FlutterOverlayWindow.isPermissionGranted();
      if (mounted) setState(() => _overlayOk = ok);
    } catch (_) {}
  }

  Future<void> _askOverlayPermission() async {
    try {
      await FlutterOverlayWindow.requestPermission();
    } catch (_) {}
    await _refreshOverlayPermission();
  }

  Future<void> _registerDevice() async {
    if (_token == null || _deviceId == null) return;
    await _devicesRef.doc(_deviceId).set({
      'name': _deviceName,
      'token': _token,
      'platform': 'android',
      'updatedAt': FieldValue.serverTimestamp(),
    });
    if (mounted) setState(() {});
  }

  Future<void> _checkBackend() async {
    _setStatus(ConnStatus.conectando, _backendUrl);
    try {
      final r = await http
          .get(Uri.parse('$_backendUrl/health'))
          .timeout(const Duration(seconds: 60)); // Render free "acorda" devagar
      if (r.statusCode == 200) {
        _setStatus(ConnStatus.conectado, _backendUrl);
      } else {
        _setStatus(ConnStatus.erro, 'Backend respondeu ${r.statusCode}');
      }
    } catch (e) {
      _setStatus(ConnStatus.desconectado, 'Backend inacessível: $_backendUrl');
    }
  }

  void _setStatus(ConnStatus s, String detail) {
    if (!mounted) return;
    setState(() {
      _status = s;
      _statusDetail = detail;
    });
  }

  List<String> _buildOptions() {
    switch (_respType) {
      case RespType.nenhuma:
        return const [];
      case RespType.simNao:
        return const ['Sim', 'Não'];
      case RespType.personalizada:
        return _options.text
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
    }
  }

  Future<void> _send() async {
    if (_selected.isEmpty || _body.text.trim().isEmpty) {
      _snack('Escolha ao menos um aparelho e escreva a mensagem.');
      return;
    }
    final options = _buildOptions();
    if (_respType == RespType.personalizada && options.length < 2) {
      _snack('Escreva ao menos 2 opções separadas por vírgula.');
      return;
    }
    setState(() => _sending = true);
    try {
      final title = _title.text.trim().isEmpty
          ? 'Mensagem de $_deviceName'
          : _title.text.trim();
      final body = _body.text.trim();

      // 1) Guarda a mensagem no Firestore (histórico + base para as respostas).
      final msg = await _messagesRef.add({
        'title': title,
        'body': body,
        'options': options,
        'fromDeviceId': _deviceId,
        'fromName': _deviceName,
        'toDeviceIds': _selected.toList(),
        'createdAt': FieldValue.serverTimestamp(),
      });

      // 2) Dispara a notificação via backend.
      final idToken = await FirebaseAuth.instance.currentUser!.getIdToken();
      final r = await http
          .post(
            Uri.parse('$_backendUrl/send'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $idToken',
            },
            body: jsonEncode({
              'groupCode': widget.groupCode,
              'deviceIds': _selected.toList(),
              'title': title,
              'body': body,
              'fromDeviceId': _deviceId,
              'fromName': _deviceName,
              'messageId': msg.id,
              'options': options,
            }),
          )
          .timeout(const Duration(seconds: 60));
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) throw Exception(data['error'] ?? r.statusCode);
      final results = (data['results'] as List).cast<Map<String, dynamic>>();
      setState(() {
        _lastResults = {
          for (final x in results)
            x['deviceId'] as String: x['ok'] == true ? 'enviado' : '${x['error']}'
        };
        _status = ConnStatus.conectado;
        _statusDetail = _backendUrl;
      });
      final ok = results.where((x) => x['ok'] == true).length;
      _snack('Enviado para $ok de ${results.length} aparelho(s).');
      _body.clear();
    } catch (e) {
      _setStatus(ConnStatus.erro, 'Falha ao enviar: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _editBackendUrl() async {
    final url = await _askText('URL do backend', _backendUrl,
        initial: _backendUrl);
    if (url == null || url.isEmpty) return;
    _backendUrl = url.replaceAll(RegExp(r'/+$'), '');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('backendUrl', _backendUrl);
    await _checkBackend();
  }

  Future<void> _renameDevice() async {
    final name = await _askText('Nome deste aparelho', _deviceName ?? '',
        initial: _deviceName);
    if (name == null || name.isEmpty) return;
    _deviceName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('deviceName', name);
    await _registerDevice();
  }

  Future<void> _leaveGroup() async {
    // Pede confirmação: isso REMOVE o aparelho do grupo (some da lista dos
    // outros). Para só fechar o app, use o botão Home do celular.
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remover este aparelho do grupo?'),
        content: const Text(
            'Ele vai sumir da lista dos outros e parar de receber mensagens. '
            'Você precisará digitar a senha de novo para voltar.\n\n'
            'Para apenas fechar o app, use o botão Início (Home) do celular.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remover')),
        ],
      ),
    );
    if (ok != true) return;
    if (_deviceId != null) await _devicesRef.doc(_deviceId).delete();
    widget.onLeave();
  }

  Future<String?> _askText(String title, String hint, {String? initial}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('OK')),
        ],
      ),
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_deviceName ?? 'Notificador'),
        bottom: TabBar(controller: _tabs, tabs: const [
          Tab(icon: Icon(Icons.send), text: 'Enviar'),
          Tab(icon: Icon(Icons.inbox), text: 'Mensagens'),
        ]),
        actions: [
          IconButton(
              tooltip: 'Fechar gerenciamento (volta à tela branca)',
              icon: const Icon(Icons.lock),
              onPressed: widget.onLock),
          IconButton(
              tooltip: 'Renomear aparelho',
              icon: const Icon(Icons.edit),
              onPressed: _renameDevice),
          IconButton(
              tooltip: 'URL do backend',
              icon: const Icon(Icons.settings),
              onPressed: _editBackendUrl),
          IconButton(
              tooltip: 'Remover este aparelho do grupo',
              icon: const Icon(Icons.person_remove),
              onPressed: _leaveGroup),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_buildCompose(), _buildInbox()],
      ),
    );
  }

  Widget _buildCompose() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _StatusCard(
            status: _status, detail: _statusDetail, onRetry: _checkBackend),
        if (!_overlayOk) ...[
          const SizedBox(height: 8),
          Card(
            color: Colors.amber.shade100,
            child: ListTile(
              leading: const Icon(Icons.layers, color: Colors.orange),
              title: const Text('Ativar "sobrepor a outros apps"'),
              subtitle: const Text(
                  'Sem isso, a pergunta não abre por cima dos outros apps. '
                  'Toque para liberar neste aparelho.'),
              trailing: FilledButton(
                onPressed: _askOverlayPermission,
                child: const Text('Liberar'),
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Card(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                secondary: Icon(
                  CameraMonitor.instance.active
                      ? Icons.videocam
                      : Icons.videocam_off,
                  color: CameraMonitor.instance.active ? Colors.red : null,
                ),
                title: const Text('Usar este aparelho como câmera (monitor)'),
                subtitle: Text(CameraMonitor.instance.error ??
                    (CameraMonitor.instance.active
                        ? 'Gravando. Uma notificação fixa avisa que a câmera está ativa.'
                        : 'Liga a câmera e mantém em segundo plano, com aviso visível.')),
                value: CameraMonitor.instance.active,
                onChanged: (v) async {
                  if (v) {
                    await CameraMonitor.instance.start();
                  } else {
                    await CameraMonitor.instance.stop();
                  }
                  final prefs = await SharedPreferences.getInstance();
                  await prefs
                      .setBool('cameraMode', CameraMonitor.instance.active);
                  if (mounted) setState(() {});
                },
              ),
              ListTile(
                leading: const Icon(Icons.battery_saver),
                title: const Text('Bateria sem restrição'),
                subtitle: const Text(
                    'Ajuda a câmera a continuar com o app fechado. Pode ser desfeito nas configurações do Android.'),
                onTap: CameraMonitor.requestBatteryExemption,
              ),
              if (CameraMonitor.instance.active)
                ListTile(
                  leading: const Icon(Icons.cameraswitch),
                  title: const Text('Trocar câmera'),
                  subtitle: Text(
                      'Usando a câmera ${CameraMonitor.instance.facingLabel}'),
                  trailing: FilledButton.tonalIcon(
                    icon: const Icon(Icons.flip_camera_android),
                    label: Text(CameraMonitor.instance.isFrontCamera
                        ? 'Traseira'
                        : 'Frontal'),
                    onPressed: () async {
                      await CameraMonitor.instance.switchCamera();
                      if (mounted) setState(() {});
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _TokenCard(token: _token),
        const SizedBox(height: 16),
        Row(
          children: [
            Text('Enviar para', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            TextButton(
              onPressed: () => setState(_selected.clear),
              child: const Text('Limpar'),
            ),
          ],
        ),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _devicesRef.orderBy('name').snapshots(),
          builder: (context, snap) {
            if (snap.hasError) return Text('Erro: ${snap.error}');
            if (!snap.hasData) return const LinearProgressIndicator();
            final docs = snap.data!.docs;
            if (docs.isEmpty) {
              return const Text(
                  'Nenhum aparelho. Instale o app em outro celular e entre com a mesma senha.');
            }
            return Card(
              child: Column(
                children: [
                  for (final d in docs)
                    CheckboxListTile(
                      value: _selected.contains(d.id),
                      onChanged: (v) => setState(() =>
                          v == true ? _selected.add(d.id) : _selected.remove(d.id)),
                      title: Text(
                          '${d['name']}${d.id == _deviceId ? ' (este)' : ''}'),
                      subtitle: _lastResults[d.id] == null
                          ? null
                          : Text(_lastResults[d.id]!,
                              style: TextStyle(
                                  color: _lastResults[d.id] == 'enviado'
                                      ? Colors.green
                                      : Colors.red)),
                      secondary: d.id == _deviceId
                          ? const Icon(Icons.phone_android)
                          : IconButton(
                              tooltip: 'Ver câmera',
                              icon: const Icon(Icons.videocam),
                              onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => CameraViewPage(
                                    groupCode: widget.groupCode,
                                    targetId: d.id,
                                    targetName: '${d['name']}',
                                  ),
                                ),
                              ),
                            ),
                    ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _title,
          decoration: const InputDecoration(
              labelText: 'Título (opcional)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _body,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
              labelText: 'Mensagem / Pergunta', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 16),
        Text('Resposta', style: Theme.of(context).textTheme.titleMedium),
        SegmentedButton<RespType>(
          segments: const [
            ButtonSegment(value: RespType.nenhuma, label: Text('Aviso')),
            ButtonSegment(value: RespType.simNao, label: Text('Sim/Não')),
            ButtonSegment(value: RespType.personalizada, label: Text('Opções')),
          ],
          selected: {_respType},
          onSelectionChanged: (s) => setState(() => _respType = s.first),
        ),
        if (_respType == RespType.personalizada) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _options,
            decoration: const InputDecoration(
              labelText: 'Opções separadas por vírgula',
              hintText: 'Ex.: Pizza, Hambúrguer, Sushi',
              border: OutlineInputBorder(),
            ),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _sending ? null : _send,
          icon: _sending
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.send),
          label: Text('Enviar (${_selected.length})'),
        ),
      ],
    );
  }

  Widget _buildInbox() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _messagesRef
          .orderBy('createdAt', descending: true)
          .limit(100)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('Erro: ${snap.error}'));
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        // Mostra só o que eu enviei ou recebi.
        final docs = snap.data!.docs.where((d) {
          final to = (d.data()['toDeviceIds'] as List?)?.cast<String>() ?? [];
          return d.data()['fromDeviceId'] == _deviceId || to.contains(_deviceId);
        }).toList();
        if (docs.isEmpty) {
          return const Center(child: Text('Nenhuma mensagem ainda.'));
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final d in docs)
              _MessageCard(
                groupCode: widget.groupCode,
                messageId: d.id,
                data: d.data(),
                myDeviceId: _deviceId ?? '',
                myName: _deviceName ?? 'Aparelho',
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Cartão de mensagem: mostra a pergunta, deixa o destinatário responder e
// exibe as respostas de todos (guardadas no Firestore).
// ---------------------------------------------------------------------------

class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.groupCode,
    required this.messageId,
    required this.data,
    required this.myDeviceId,
    required this.myName,
  });

  final String groupCode;
  final String messageId;
  final Map<String, dynamic> data;
  final String myDeviceId;
  final String myName;

  @override
  Widget build(BuildContext context) {
    final options = (data['options'] as List?)?.cast<String>() ?? [];
    final to = (data['toDeviceIds'] as List?)?.cast<String>() ?? [];
    final isRecipient = to.contains(myDeviceId);
    final isMine = data['fromDeviceId'] == myDeviceId;
    final responsesRef = FirebaseFirestore.instance
        .collection('groups/$groupCode/messages/$messageId/responses');

    Future<void> respond(String option) =>
        responsesRef.doc(myDeviceId).set({
          'option': option,
          'name': myName,
          'at': FieldValue.serverTimestamp(),
        });

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(isMine ? Icons.north_east : Icons.south_west,
                    size: 16,
                    color: isMine ? Colors.blue : Colors.green),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    isMine ? 'Você enviou' : 'De: ${data['fromName'] ?? '?'}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            if ((data['title'] ?? '').toString().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(data['title'],
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(data['body'] ?? ''),
            ),
            StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              stream: responsesRef.doc(myDeviceId).snapshots(),
              builder: (context, mySnap) {
                final myAnswer = mySnap.data?.data()?['option'] as String?;
                // Destinatário responde tocando numa opção.
                if (isRecipient && options.isNotEmpty) {
                  return Wrap(
                    spacing: 8,
                    children: [
                      for (final opt in options)
                        ChoiceChip(
                          label: Text(opt),
                          selected: myAnswer == opt,
                          onSelected: (_) => respond(opt),
                        ),
                    ],
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            if (options.isNotEmpty) ...[
              const Divider(),
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: responsesRef.snapshots(),
                builder: (context, rs) {
                  if (!rs.hasData) return const SizedBox.shrink();
                  final answers = rs.data!.docs;
                  if (answers.isEmpty) {
                    return const Text('Sem respostas ainda.',
                        style: TextStyle(color: Colors.grey));
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final opt in options)
                        () {
                          final who = answers
                              .where((a) => a['option'] == opt)
                              .map((a) => a['name'] ?? '?')
                              .join(', ');
                          if (who.isEmpty) return const SizedBox.shrink();
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text('• $opt: $who'),
                          );
                        }(),
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard(
      {required this.status, required this.detail, required this.onRetry});

  final ConnStatus status;
  final String detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final (color, label, icon) = switch (status) {
      ConnStatus.conectando => (Colors.orange, 'Conectando…', Icons.sync),
      ConnStatus.conectado => (Colors.green, 'Conectado', Icons.cloud_done),
      ConnStatus.desconectado =>
        (Colors.grey, 'Desconectado', Icons.cloud_off),
      ConnStatus.erro => (Colors.red, 'Erro', Icons.error),
    };
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(label, style: TextStyle(color: color)),
        subtitle: Text(detail),
        trailing: IconButton(icon: const Icon(Icons.refresh), onPressed: onRetry),
      ),
    );
  }
}

class _TokenCard extends StatelessWidget {
  const _TokenCard({required this.token});

  final String? token;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.key),
        title: const Text('Token FCM deste aparelho'),
        subtitle: Text(token == null ? 'obtendo…' : 'registrado no grupo'),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SelectableText(token ?? '-',
                style: const TextStyle(fontSize: 12)),
          ),
          TextButton.icon(
            onPressed: token == null
                ? null
                : () => Clipboard.setData(ClipboardData(text: token!)),
            icon: const Icon(Icons.copy),
            label: const Text('Copiar'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// OVERLAY: janela de sistema que aparece por cima de qualquer app.
// Roda em um isolate próprio (entry point overlayMain). Lê a pergunta pendente
// do SharedPreferences, mostra as opções e só fecha quando a pessoa responde.
// ---------------------------------------------------------------------------

@pragma('vm:entry-point')
void overlayMain() {
  runApp(const _OverlayApp());
}

class _OverlayApp extends StatelessWidget {
  const _OverlayApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      // Tema padrão do Material 3 (cores/disposição nativas do Android).
      theme: ThemeData(useMaterial3: true),
      darkTheme: ThemeData.dark(useMaterial3: true),
      home: const _OverlayQuestion(),
    );
  }
}

class _OverlayQuestion extends StatefulWidget {
  const _OverlayQuestion();

  @override
  State<_OverlayQuestion> createState() => _OverlayQuestionState();
}

class _OverlayQuestionState extends State<_OverlayQuestion> {
  String _title = '';
  String _body = '';
  List<String> _options = [];
  String? _groupCode;
  String? _messageId;
  bool _ready = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform);
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('pendingMessage');
    if (raw != null) {
      try {
        final d = (jsonDecode(raw) as Map).cast<String, dynamic>();
        _title = d['title']?.toString() ?? 'Mensagem';
        _body = d['body']?.toString() ?? '';
        _options = _parseOptions(d['options']);
        _groupCode = d['groupCode']?.toString();
        _messageId = d['messageId']?.toString();
      } catch (_) {}
    }
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _answer(String option) async {
    if (_saving || _groupCode == null || _messageId == null) return;
    setState(() => _saving = true);
    try {
      await _saveResponse(_groupCode!, _messageId!, option);
    } catch (_) {}
    await FlutterOverlayWindow.closeOverlay();
  }

  @override
  Widget build(BuildContext context) {
    // Caixa de diálogo padrão do Android: título em cima, texto, e os botões
    // na parte de baixo à direita. Fundo escurecido; "voltar" não fecha.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.black54,
        body: Center(
          child: !_ready
              ? const CircularProgressIndicator()
              : AlertDialog(
                  title: _title.isEmpty ? null : Text(_title),
                  content: Text(_body),
                  actions: _saving
                      ? const [
                          Padding(
                            padding: EdgeInsets.all(8),
                            child: SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                          )
                        ]
                      : [
                          for (final opt in _options)
                            TextButton(
                              onPressed: () => _answer(opt),
                              child: Text(opt),
                            ),
                        ],
                ),
        ),
      ),
    );
  }
}
