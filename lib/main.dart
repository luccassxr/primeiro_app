import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  runApp(const LocalizadorApp());
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
      initialNotificationTitle: 'Localizador ativo',
      initialNotificationContent: 'Compartilhamento de localização em execução',
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
      title: 'Localizador ativo',
      content: 'Compartilhamento de localização em execução',
    );
  }

  StreamSubscription<Position>? subscription;
  Timer? heartbeatTimer;
  Timer? commandTimer;
  Position? ultimaPosicao;
  var encerrando = false;
  var processandoComandos = false;

  // A chave publishable identifica o app via apikey. Ela NÃO deve ser enviada
  // como Bearer token, pois sb_publishable_* não é um JWT.
  final headers = <String, String>{
    'apikey': supabaseAnonKey,
    'Content-Type': 'application/json',
  };

  Future<void> encerrar() async {
    if (encerrando) return;
    encerrando = true;
    heartbeatTimer?.cancel();
    commandTimer?.cancel();
    await subscription?.cancel();
    await service.stopSelf();
  }

  service.on('stop').listen((_) => encerrar());

  if (!backendConfigurado) {
    debugPrint('Backend não configurado. Encerrando serviço.');
    await encerrar();
    return;
  }

  Future<bool> enviarPosicao(Position position, String evento) async {
    if (encerrando) return false;
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
            headers: {...headers, 'Prefer': 'return=minimal'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint(
          'Falha ao enviar localização: ${response.statusCode} ${response.body}',
        );
        return false;
      }

      debugPrint(
        'Localização enviada ($evento): ${position.latitude}, ${position.longitude}',
      );
      return true;
    } catch (e) {
      debugPrint('Erro de rede ao enviar localização: $e');
      return false;
    }
  }

  Future<void> concluirComando(
    int commandId, {
    required bool sucesso,
    String? erro,
  }) async {
    final uri = Uri.parse(
      '$supabaseUrl/rest/v1/location_commands?id=eq.$commandId&status=eq.pending',
    );

    try {
      final response = await http
          .patch(
            uri,
            headers: {...headers, 'Prefer': 'return=minimal'},
            body: jsonEncode({
              'status': sucesso ? 'completed' : 'failed',
              'processed_at': DateTime.now().toUtc().toIso8601String(),
              'error': sucesso ? null : (erro ?? 'Não foi possível obter a posição.'),
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint(
          'Falha ao concluir comando $commandId: '
          '${response.statusCode} ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('Falha ao concluir comando $commandId: $e');
    }
  }

  Future<void> verificarComandos() async {
    if (encerrando || processandoComandos) return;
    processandoComandos = true;

    try {
      final uri = Uri.parse(
        '$supabaseUrl/rest/v1/location_commands'
        '?select=id'
        '&device_id=eq.$deviceId'
        '&command=eq.locate_now'
        '&status=eq.pending'
        '&order=requested_at.asc'
        '&limit=3',
      );

      final response = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint(
          'Falha ao consultar comandos: ${response.statusCode} ${response.body}',
        );
        return;
      }

      final lista = jsonDecode(response.body) as List<dynamic>;
      for (final raw in lista) {
        if (encerrando) break;
        final item = raw as Map<String, dynamic>;
        final commandId = (item['id'] as num).toInt();

        try {
          final position = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
            ),
          ).timeout(const Duration(seconds: 25));

          final enviado = await enviarPosicao(position, 'manual');
          await concluirComando(
            commandId,
            sucesso: enviado,
            erro: enviado ? null : 'A posição foi obtida, mas não pôde ser enviada.',
          );
        } on TimeoutException {
          await concluirComando(
            commandId,
            sucesso: false,
            erro: 'Tempo limite para obter a localização.',
          );
        } catch (e) {
          await concluirComando(
            commandId,
            sucesso: false,
            erro: 'Erro ao obter localização: $e',
          );
        }
      }
    } catch (e) {
      debugPrint('Erro ao verificar comandos: $e');
    } finally {
      processandoComandos = false;
    }
  }

  try {
    final inicial = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
    ).timeout(const Duration(seconds: 30));
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

  heartbeatTimer = Timer.periodic(const Duration(minutes: 1), (_) async {
    final position = ultimaPosicao;
    if (position != null && !encerrando) {
      await enviarPosicao(position, 'heartbeat');
    }
  });

  commandTimer = Timer.periodic(
    const Duration(seconds: 5),
    (_) => verificarComandos(),
  );
  await verificarComandos();
}

class LocalizadorApp extends StatelessWidget {
  const LocalizadorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Localizador',
      theme: ThemeData(useMaterial3: true),
      home: const TelaAtivacao(),
    );
  }
}

class TelaAtivacao extends StatefulWidget {
  const TelaAtivacao({super.key});

  @override
  State<TelaAtivacao> createState() => _TelaAtivacaoState();
}

class _TelaAtivacaoState extends State<TelaAtivacao> {
  bool processando = true;
  String titulo = 'Verificando configuração';
  String detalhe = 'Aguarde um instante…';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _verificarAoAbrir());
  }

  Future<void> _fecharApp() async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    await SystemNavigator.pop();
  }

  Future<void> _verificarAoAbrir() async {
    if (!backendConfigurado) {
      _estado(
        'Configuração incompleta',
        'Este APK foi gerado sem acesso ao servidor. Instale uma versão atualizada.',
        false,
      );
      return;
    }

    final localizacaoAtiva = await Geolocator.isLocationServiceEnabled();
    final permissao = await Geolocator.checkPermission();

    if (localizacaoAtiva && permissao == LocationPermission.always) {
      final service = FlutterBackgroundService();
      if (!await service.isRunning()) {
        await service.startService();
      }

      if (!mounted) return;
      _estado(
        'Localização ativa',
        'O serviço está funcionando em segundo plano.',
        true,
      );
      await _fecharApp();
      return;
    }

    _estado(
      'Ativar localização',
      'Faça a configuração uma única vez. Depois, o serviço funciona em segundo plano.',
      false,
    );
  }

  void _estado(String novoTitulo, String novoDetalhe, bool carregando) {
    if (!mounted) return;
    setState(() {
      titulo = novoTitulo;
      detalhe = novoDetalhe;
      processando = carregando;
    });
  }

  Future<void> configurar() async {
    if (processando) return;
    setState(() {
      processando = true;
      titulo = 'Configurando';
      detalhe = 'Verificando as permissões necessárias…';
    });

    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _estado(
          'Ative a localização do celular',
          'Ligue a Localização/GPS e volte para este aplicativo.',
          false,
        );
        await Geolocator.openLocationSettings();
        return;
      }

      var permissao = await Geolocator.checkPermission();
      if (permissao == LocationPermission.denied) {
        permissao = await Geolocator.requestPermission();
      }

      if (permissao == LocationPermission.deniedForever) {
        _estado(
          'Permissão bloqueada',
          'Abra as configurações e permita o acesso à localização.',
          false,
        );
        await Geolocator.openAppSettings();
        return;
      }

      if (permissao == LocationPermission.denied) {
        _estado(
          'Permissão necessária',
          'O aplicativo precisa da localização para funcionar.',
          false,
        );
        return;
      }

      if (permissao != LocationPermission.always) {
        _estado(
          'Permita o tempo todo',
          'Na tela que será aberta, entre em Localização e escolha “Permitir o tempo todo”. Depois volte para o app.',
          false,
        );
        await Geolocator.openAppSettings();
        return;
      }

      final service = FlutterBackgroundService();
      if (!await service.isRunning()) {
        await service.startService();
      }

      if (!mounted) return;
      _estado(
        'Pronto',
        'Localização ativada. Você não precisa manter este aplicativo aberto.',
        true,
      );
      await _fecharApp();
    } catch (e) {
      _estado(
        'Não foi possível ativar',
        'Tente novamente. Detalhe: $e',
        false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.my_location_rounded, size: 76),
                  const SizedBox(height: 22),
                  const Text(
                    'Localizador',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    titulo,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    detalhe,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 28),
                  if (processando)
                    const CircularProgressIndicator()
                  else
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: configurar,
                        icon: const Icon(Icons.location_on_outlined),
                        label: const Text('Configurar localização'),
                      ),
                    ),
                  const SizedBox(height: 18),
                  Text(
                    'Quando estiver ativo, o Android mostrará uma notificação permanente enquanto a localização estiver sendo compartilhada.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
