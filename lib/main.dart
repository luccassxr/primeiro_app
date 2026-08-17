import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const String supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
const String deviceId = String.fromEnvironment(
  'DEVICE_ID',
  defaultValue: 'celular-01',
);

bool get backendConfigurado =>
    supabaseUrl.trim().isNotEmpty && supabaseAnonKey.trim().isNotEmpty;

Map<String, String> get apiHeaders => <String, String>{
      'apikey': supabaseAnonKey,
      'Content-Type': 'application/json',
    };

Map<String, dynamic> payloadDaPosicao(Position position, String evento) =>
    <String, dynamic>{
      'device_id': deviceId,
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracy': position.accuracy,
      'speed': position.speed,
      'altitude': position.altitude,
      'event': evento,
      'client_time': DateTime.now().toUtc().toIso8601String(),
    };

Future<EnvioResultado> enviarPayload(Map<String, dynamic> payload) async {
  if (!backendConfigurado) {
    return const EnvioResultado(false, 'Backend não configurado.');
  }

  try {
    final response = await http
        .post(
          Uri.parse('$supabaseUrl/rest/v1/locations'),
          headers: {...apiHeaders, 'Prefer': 'return=minimal'},
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return const EnvioResultado(true, 'Localização recebida pelo servidor.');
    }

    final corpo = response.body.trim();
    return EnvioResultado(
      false,
      'Servidor recusou o envio (${response.statusCode})'
      '${corpo.isEmpty ? '' : ': $corpo'}',
    );
  } on TimeoutException {
    return const EnvioResultado(false, 'Tempo limite ao acessar o servidor.');
  } catch (e) {
    return EnvioResultado(false, 'Falha de rede: $e');
  }
}

Future<Database> abrirFilaOffline() async {
  final pasta = await getDatabasesPath();
  return openDatabase(
    '$pasta/localizador_fila.db',
    version: 1,
    onCreate: (db, _) async {
      await db.execute('''
        CREATE TABLE fila_localizacoes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          payload TEXT NOT NULL,
          criado_em INTEGER NOT NULL
        )
      ''');
    },
  );
}

Future<void> salvarNaFila(
  Database db,
  Map<String, dynamic> payload,
) async {
  await db.insert('fila_localizacoes', {
    'payload': jsonEncode(payload),
    'criado_em': DateTime.now().millisecondsSinceEpoch,
  });

  final count = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM fila_localizacoes'),
      ) ??
      0;
  if (count > 1000) {
    await db.rawDelete(
      'DELETE FROM fila_localizacoes WHERE id IN '
      '(SELECT id FROM fila_localizacoes ORDER BY id ASC LIMIT ?)',
      [count - 1000],
    );
  }
}

Future<void> descarregarFila(Database db) async {
  final itens = await db.query(
    'fila_localizacoes',
    orderBy: 'id ASC',
    limit: 50,
  );

  for (final item in itens) {
    final id = item['id'] as int;
    final payload = jsonDecode(item['payload'] as String) as Map<String, dynamic>;
    final resultado = await enviarPayload(payload);
    if (!resultado.sucesso) return;
    await db.delete('fila_localizacoes', where: 'id = ?', whereArgs: [id]);
  }
}

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

  final db = await abrirFilaOffline();
  StreamSubscription<Position>? subscription;
  Timer? heartbeatTimer;
  Timer? commandTimer;
  Timer? retryTimer;
  Position? ultimaPosicao;
  bool encerrando = false;
  bool processandoComandos = false;

  Future<void> encerrar() async {
    if (encerrando) return;
    encerrando = true;
    heartbeatTimer?.cancel();
    commandTimer?.cancel();
    retryTimer?.cancel();
    await subscription?.cancel();
    await db.close();
    await service.stopSelf();
  }

  service.on('stop').listen((_) => encerrar());

  if (!backendConfigurado) {
    debugPrint('Backend não configurado.');
    await encerrar();
    return;
  }

  Future<bool> registrar(Position position, String evento) async {
    if (encerrando) return false;
    ultimaPosicao = position;
    final payload = payloadDaPosicao(position, evento);

    await descarregarFila(db);
    final resultado = await enviarPayload(payload);
    if (resultado.sucesso) {
      debugPrint('Localização enviada: $evento');
      return true;
    }

    debugPrint('Envio falhou e foi enfileirado: ${resultado.mensagem}');
    await salvarNaFila(db, payload);
    return false;
  }

  Future<void> concluirComando(
    int commandId, {
    required bool sucesso,
    String? erro,
  }) async {
    try {
      final response = await http
          .patch(
            Uri.parse(
              '$supabaseUrl/rest/v1/location_commands'
              '?id=eq.$commandId&status=eq.pending',
            ),
            headers: {...apiHeaders, 'Prefer': 'return=minimal'},
            body: jsonEncode({
              'status': sucesso ? 'completed' : 'failed',
              'processed_at': DateTime.now().toUtc().toIso8601String(),
              'error': sucesso ? null : erro,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('Falha ao concluir comando: ${response.statusCode} ${response.body}');
      }
    } catch (e) {
      debugPrint('Falha ao concluir comando: $e');
    }
  }

  Future<void> verificarComandos() async {
    if (encerrando || processandoComandos) return;
    processandoComandos = true;
    try {
      final response = await http
          .get(
            Uri.parse(
              '$supabaseUrl/rest/v1/location_commands'
              '?select=id&device_id=eq.$deviceId&command=eq.locate_now'
              '&status=eq.pending&order=requested_at.asc&limit=3',
            ),
            headers: apiHeaders,
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('Falha ao consultar comandos: ${response.statusCode} ${response.body}');
        return;
      }

      final lista = jsonDecode(response.body) as List<dynamic>;
      for (final raw in lista) {
        final commandId = ((raw as Map<String, dynamic>)['id'] as num).toInt();
        try {
          final position = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
            ),
          ).timeout(const Duration(seconds: 30));
          final enviado = await registrar(position, 'manual');
          await concluirComando(
            commandId,
            sucesso: enviado,
            erro: enviado ? null : 'Sem conexão com o servidor; posição ficou na fila local.',
          );
        } catch (e) {
          await concluirComando(
            commandId,
            sucesso: false,
            erro: 'Falha ao obter posição: $e',
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
    await descarregarFila(db);
    final inicial = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
    ).timeout(const Duration(seconds: 30));
    await registrar(inicial, 'startup');
  } catch (e) {
    debugPrint('Falha na posição inicial: $e');
  }

  subscription = Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.medium,
      distanceFilter: 50,
    ),
  ).listen(
    (position) => registrar(position, 'movement'),
    onError: (Object erro) => debugPrint('Erro no fluxo de localização: $erro'),
  );

  heartbeatTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
    final position = ultimaPosicao;
    if (position != null && !encerrando) {
      await registrar(position, 'heartbeat');
    }
  });

  commandTimer = Timer.periodic(
    const Duration(seconds: 30),
    (_) => verificarComandos(),
  );

  retryTimer = Timer.periodic(const Duration(minutes: 2), (_) async {
    if (!encerrando) await descarregarFila(db);
  });

  await verificarComandos();
}

class EnvioResultado {
  const EnvioResultado(this.sucesso, this.mensagem);

  final bool sucesso;
  final String mensagem;
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

  void _estado(String novoTitulo, String novoDetalhe, bool carregando) {
    if (!mounted) return;
    setState(() {
      titulo = novoTitulo;
      detalhe = novoDetalhe;
      processando = carregando;
    });
  }

  Future<void> _fecharApp() async {
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (mounted) await SystemNavigator.pop();
  }

  Future<bool> _validarEnvioAgora() async {
    _estado('Testando conexão', 'Obtendo uma localização atual…', true);
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(const Duration(seconds: 30));

      _estado('Testando conexão', 'Enviando a localização ao servidor…', true);
      final resultado = await enviarPayload(payloadDaPosicao(position, 'startup'));
      if (!resultado.sucesso) {
        _estado(
          'Não foi possível enviar',
          '${resultado.mensagem}\n\nO aplicativo não será fechado para você conseguir ver o erro.',
          false,
        );
        return false;
      }
      return true;
    } catch (e) {
      _estado(
        'Não foi possível obter a localização',
        'Verifique se o GPS está ligado e tente novamente. Detalhe: $e',
        false,
      );
      return false;
    }
  }

  Future<void> _iniciarEValidar() async {
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      await service.startService();
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }

    if (!await _validarEnvioAgora()) return;

    _estado(
      'Tudo certo',
      'Localização confirmada pelo servidor. O serviço continuará em segundo plano.',
      true,
    );
    await _fecharApp();
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
      await _iniciarEValidar();
      return;
    }

    _estado(
      'Ativar localização',
      'Toque abaixo e conclua a autorização. O app só fechará depois de confirmar que a posição chegou ao servidor.',
      false,
    );
  }

  Future<void> configurar() async {
    if (processando) return;
    _estado('Configurando', 'Verificando as permissões necessárias…', true);

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
          'Na tela que será aberta, entre em Localização e escolha “Permitir o tempo todo”. Depois volte ao app.',
          false,
        );
        await Geolocator.openAppSettings();
        return;
      }

      await _iniciarEValidar();
    } catch (e) {
      _estado('Não foi possível ativar', 'Detalhe: $e', false);
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
                  const SizedBox(height: 10),
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
                        label: const Text('Verificar e ativar'),
                      ),
                    ),
                  const SizedBox(height: 18),
                  Text(
                    'Quando estiver ativo, o Android mantém uma notificação visível enquanto a localização estiver sendo compartilhada.',
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
