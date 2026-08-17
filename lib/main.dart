import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const String supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
const String deviceId = String.fromEnvironment(
  'DEVICE_ID',
  defaultValue: 'celular-01',
);

bool get backendConfigurado =>
    supabaseUrl.trim().isNotEmpty && supabaseAnonKey.trim().isNotEmpty;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configurarServico();
  runApp(const MeuApp());
}

Future<void> configurarServico() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      autoStartOnBoot: true,
      isForegroundMode: true,
      notificationChannelId: 'localizacao_service',
      initialNotificationTitle: 'Localização ativa',
      initialNotificationContent: 'Monitoramento autorizado em execução',
      foregroundServiceNotificationId: 888,
      foregroundServiceTypes: const [AndroidForegroundType.location],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
    ),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    await service.setAsForegroundService();
    await service.setForegroundNotificationInfo(
      title: 'Localização ativa',
      content: 'Monitoramento autorizado em execução',
    );
  }

  StreamSubscription<Position>? subscription;
  Timer? heartbeatTimer;
  Position? ultimaPosicao;
  var encerrando = false;

  Future<void> encerrar() async {
    if (encerrando) return;
    encerrando = true;
    heartbeatTimer?.cancel();
    await subscription?.cancel();
    await service.stopSelf();
  }

  service.on('stop').listen((_) => encerrar());

  if (!backendConfigurado) {
    debugPrint('Backend não configurado. Encerrando serviço.');
    await encerrar();
    return;
  }

  Future<void> enviarPosicao(Position position, String evento) async {
    if (encerrando) return;
    ultimaPosicao = position;

    final uri = Uri.parse('$supabaseUrl/rest/v1/locations');
    final payload = <String, dynamic>{
      'device_id': deviceId,
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracy': position.accuracy,
      'speed': position.speed,
      'altitude': position.altitude,
      'event': evento,
      'client_time': DateTime.now().toUtc().toIso8601String(),
    };

    try {
      final response = await http
          .post(
            uri,
            headers: {
              'apikey': supabaseAnonKey,
              'Authorization': 'Bearer $supabaseAnonKey',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('Falha ao enviar localização: ${response.statusCode} ${response.body}');
      } else {
        debugPrint('Localização enviada ($evento): ${position.latitude}, ${position.longitude}');
      }
    } catch (e) {
      debugPrint('Erro de rede ao enviar localização: $e');
    }
  }

  try {
    final inicial = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    await enviarPosicao(inicial, 'startup');
  } catch (e) {
    debugPrint('Não foi possível obter a posição inicial: $e');
  }

  subscription = Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 25,
    ),
  ).listen(
    (position) => enviarPosicao(position, 'movement'),
    onError: (Object erro) => debugPrint('Erro no fluxo de localização: $erro'),
  );

  heartbeatTimer = Timer.periodic(const Duration(minutes: 15), (_) async {
    final position = ultimaPosicao;
    if (position != null && !encerrando) {
      await enviarPosicao(position, 'heartbeat');
    }
  });
}

class MeuApp extends StatelessWidget {
  const MeuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Rastreador interno',
      theme: ThemeData(useMaterial3: true),
      home: const TelaConfiguracao(),
    );
  }
}

class TelaConfiguracao extends StatefulWidget {
  const TelaConfiguracao({super.key});

  @override
  State<TelaConfiguracao> createState() => _TelaConfiguracaoState();
}

class _TelaConfiguracaoState extends State<TelaConfiguracao> {
  String status = 'Aguardando autorização';
  bool processando = false;
  bool ativo = false;

  @override
  void initState() {
    super.initState();
    _carregarStatus();
  }

  Future<void> _carregarStatus() async {
    final executando = await FlutterBackgroundService().isRunning();
    if (!mounted) return;
    setState(() {
      ativo = executando;
      status = executando ? 'Monitoramento ativo' : 'Aguardando autorização';
    });
  }

  Future<void> ativarMonitoramento() async {
    if (processando) return;
    setState(() => processando = true);

    try {
      if (!backendConfigurado) {
        _mostrar(
          'Este APK foi compilado sem SUPABASE_URL/SUPABASE_ANON_KEY. '
          'Configure os secrets do GitHub e gere outro APK.',
        );
        return;
      }

      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) setState(() => status = 'Ative a localização do celular');
        await Geolocator.openLocationSettings();
        return;
      }

      var permissao = await Geolocator.checkPermission();
      if (permissao == LocationPermission.denied) {
        permissao = await Geolocator.requestPermission();
      }

      if (permissao == LocationPermission.deniedForever) {
        if (mounted) setState(() => status = 'Permissão bloqueada');
        _mostrar('Abra as configurações do app e permita localização.');
        await Geolocator.openAppSettings();
        return;
      }

      if (permissao == LocationPermission.denied) {
        if (mounted) setState(() => status = 'Permissão negada');
        return;
      }

      if (permissao != LocationPermission.always) {
        if (mounted) setState(() => status = 'Falta permitir em segundo plano');
        _mostrar(
          'Nas configurações do app, escolha Localização > Permitir o tempo todo. '
          'Depois volte e toque em Ativar novamente.',
        );
        await Geolocator.openAppSettings();
        return;
      }

      final service = FlutterBackgroundService();
      if (!await service.isRunning()) {
        await service.startService();
      }

      if (!mounted) return;
      setState(() {
        ativo = true;
        status = 'Monitoramento ativo';
      });
    } finally {
      if (mounted) setState(() => processando = false);
    }
  }

  Future<void> desativarMonitoramento() async {
    FlutterBackgroundService().invoke('stop');
    if (!mounted) return;
    setState(() {
      ativo = false;
      status = 'Monitoramento desativado';
    });
  }

  void _mostrar(String mensagem) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(mensagem)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.location_on, size: 64),
                const SizedBox(height: 16),
                Text(
                  status,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 24),
                if (!ativo)
                  FilledButton(
                    onPressed: processando ? null : ativarMonitoramento,
                    child: Text(processando ? 'Configurando...' : 'Ativar'),
                  )
                else
                  OutlinedButton(
                    onPressed: desativarMonitoramento,
                    child: const Text('Desativar'),
                  ),
                const SizedBox(height: 12),
                const Text(
                  'Após a autorização, o serviço continua em segundo plano e '
                  'mantém uma notificação do Android enquanto estiver ativo.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
