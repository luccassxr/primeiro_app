import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const String supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
const String deviceId = String.fromEnvironment('DEVICE_ID', defaultValue: 'celular-01');

bool get backendConfigurado =>
    supabaseUrl.trim().isNotEmpty && supabaseAnonKey.trim().isNotEmpty;

Map<String, String> get apiHeaders => {
      'apikey': supabaseAnonKey,
      'Content-Type': 'application/json',
    };

Map<String, dynamic> payloadDaPosicao(Position p, String evento) => {
      'device_id': deviceId,
      'latitude': p.latitude,
      'longitude': p.longitude,
      'accuracy': p.accuracy,
      'speed': p.speed,
      'altitude': p.altitude,
      'event': evento,
      'client_time': DateTime.now().toUtc().toIso8601String(),
    };

class EnvioResultado {
  const EnvioResultado(this.sucesso, this.mensagem);
  final bool sucesso;
  final String mensagem;
}

Future<EnvioResultado> enviarPayload(Map<String, dynamic> payload) async {
  if (!backendConfigurado) {
    return const EnvioResultado(false, 'Backend não configurado no APK.');
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
    return EnvioResultado(
      false,
      'Servidor recusou (${response.statusCode}): ${response.body}',
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
    onCreate: (db, _) => db.execute('''
      CREATE TABLE fila_localizacoes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        payload TEXT NOT NULL,
        criado_em INTEGER NOT NULL
      )
    '''),
  );
}

Future<void> salvarNaFila(Database db, Map<String, dynamic> payload) async {
  await db.insert('fila_localizacoes', {
    'payload': jsonEncode(payload),
    'criado_em': DateTime.now().millisecondsSinceEpoch,
  });
  final total = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM fila_localizacoes'),
      ) ??
      0;
  if (total > 1000) {
    await db.rawDelete(
      'DELETE FROM fila_localizacoes WHERE id IN '
      '(SELECT id FROM fila_localizacoes ORDER BY id ASC LIMIT ?)',
      [total - 1000],
    );
  }
}

Future<void> descarregarFila(Database db) async {
  final itens = await db.query('fila_localizacoes', orderBy: 'id ASC', limit: 30);
  for (final item in itens) {
    final payload = jsonDecode(item['payload'] as String) as Map<String, dynamic>;
    final resultado = await enviarPayload(payload);
    if (!resultado.sucesso) return;
    await db.delete('fila_localizacoes', where: 'id = ?', whereArgs: [item['id']]);
  }
}

@pragma('vm:entry-point')
void startCallback() {
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(LocalizadorTaskHandler());
}

class LocalizadorTaskHandler extends TaskHandler {
  Database? _db;
  Position? _ultimaEnviada;
  DateTime? _ultimoHeartbeat;
  bool _ocupado = false;

  Future<bool> _registrar(Position p, String evento) async {
    final db = _db;
    if (db == null) return false;
    await descarregarFila(db);
    final payload = payloadDaPosicao(p, evento);
    final resultado = await enviarPayload(payload);
    if (!resultado.sucesso) {
      await salvarNaFila(db, payload);
      return false;
    }
    _ultimaEnviada = p;
    if (evento == 'heartbeat' || evento == 'startup') {
      _ultimoHeartbeat = DateTime.now();
    }
    return true;
  }

  Future<void> _verificarComandos() async {
    try {
      final response = await http
          .get(
            Uri.parse(
              '$supabaseUrl/rest/v1/location_commands'
              '?select=id&device_id=eq.$deviceId&command=eq.locate_now'
              '&status=eq.pending&order=requested_at.asc&limit=1',
            ),
            headers: apiHeaders,
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) return;
      final lista = jsonDecode(response.body) as List<dynamic>;
      if (lista.isEmpty) return;
      final id = ((lista.first as Map<String, dynamic>)['id'] as num).toInt();

      bool sucesso = false;
      String? erro;
      try {
        final p = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        ).timeout(const Duration(seconds: 25));
        sucesso = await _registrar(p, 'manual');
        if (!sucesso) erro = 'Posição salva localmente; servidor indisponível.';
      } catch (e) {
        erro = 'Falha ao obter posição: $e';
      }

      await http.patch(
        Uri.parse('$supabaseUrl/rest/v1/location_commands?id=eq.$id&status=eq.pending'),
        headers: {...apiHeaders, 'Prefer': 'return=minimal'},
        body: jsonEncode({
          'status': sucesso ? 'completed' : 'failed',
          'processed_at': DateTime.now().toUtc().toIso8601String(),
          'error': sucesso ? null : erro,
        }),
      ).timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _db = await abrirFilaOffline();
    await descarregarFila(_db!);
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 30));
      await _registrar(p, 'startup');
    } catch (_) {}
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_ocupado) return;
    _ocupado = true;
    () async {
      try {
        await _verificarComandos();
        final agora = DateTime.now();
        final heartbeatVencido = _ultimoHeartbeat == null ||
            agora.difference(_ultimoHeartbeat!) >= const Duration(minutes: 5);

        final p = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
        ).timeout(const Duration(seconds: 20));

        final anterior = _ultimaEnviada;
        final moveu = anterior == null ||
            Geolocator.distanceBetween(
                  anterior.latitude,
                  anterior.longitude,
                  p.latitude,
                  p.longitude,
                ) >=
                50;

        if (moveu) {
          await _registrar(p, 'movement');
        } else if (heartbeatVencido) {
          await _registrar(p, 'heartbeat');
        } else if (_db != null) {
          await descarregarFila(_db!);
        }
      } catch (_) {
      } finally {
        _ocupado = false;
      }
    }();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _db?.close();
    _db = null;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'localizacao_service',
      channelName: 'Localização em segundo plano',
      channelDescription: 'Mantém o compartilhamento de localização ativo.',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(30000),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
      allowWakeLock: true,
      allowWifiLock: false,
    ),
  );
  runApp(const LocalizadorApp());
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

  void _estado(String t, String d, bool p) {
    if (!mounted) return;
    setState(() {
      titulo = t;
      detalhe = d;
      processando = p;
    });
  }

  Future<bool> _validarEnvioAgora() async {
    _estado('Testando localização', 'Obtendo posição atual…', true);
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 30));
      _estado('Testando servidor', 'Enviando posição ao servidor…', true);
      final r = await enviarPayload(payloadDaPosicao(p, 'startup'));
      if (!r.sucesso) {
        _estado('Falha no envio', r.mensagem, false);
        return false;
      }
      return true;
    } catch (e) {
      _estado('Falha no GPS', 'Não foi possível obter a posição: $e', false);
      return false;
    }
  }

  Future<bool> _iniciarServico() async {
    try {
      final permissaoNotificacao = await FlutterForegroundTask.checkNotificationPermission();
      if (permissaoNotificacao != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }

      if (!await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.startService(
          serviceId: 888,
          serviceTypes: const [ForegroundServiceTypes.location],
          notificationTitle: 'Localizador ativo',
          notificationText: 'Compartilhamento de localização em execução',
          callback: startCallback,
        );
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      return await FlutterForegroundTask.isRunningService;
    } catch (e) {
      _estado('Falha ao iniciar serviço', '$e', false);
      return false;
    }
  }

  Future<void> _iniciarEValidar() async {
    // Primeiro confirma GPS -> Supabase com o app aberto. Só depois inicia o serviço.
    if (!await _validarEnvioAgora()) return;
    _estado('Localização confirmada', 'Iniciando serviço em segundo plano…', true);
    if (!await _iniciarServico()) {
      _estado(
        'Localização chegou ao servidor',
        'O envio inicial funcionou, mas o serviço em segundo plano não iniciou. Não vou fechar o app.',
        false,
      );
      return;
    }
    _estado(
      'Tudo certo',
      'Localização confirmada e serviço ativo em segundo plano.',
      true,
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    if (mounted) await SystemNavigator.pop();
  }

  Future<void> _verificarAoAbrir() async {
    if (!backendConfigurado) {
      _estado('Configuração incompleta', 'APK sem configuração do servidor.', false);
      return;
    }
    final gps = await Geolocator.isLocationServiceEnabled();
    final permissao = await Geolocator.checkPermission();
    if (gps && permissao == LocationPermission.always) {
      await _iniciarEValidar();
      return;
    }
    _estado(
      'Ativar localização',
      'Permita a localização o tempo todo. O app só fecha depois de confirmar o envio.',
      false,
    );
  }

  Future<void> configurar() async {
    if (processando) return;
    _estado('Configurando', 'Verificando permissões…', true);
    if (!await Geolocator.isLocationServiceEnabled()) {
      _estado('Ative o GPS', 'Ligue a localização do celular e volte.', false);
      await Geolocator.openLocationSettings();
      return;
    }

    var permissao = await Geolocator.checkPermission();
    if (permissao == LocationPermission.denied) {
      permissao = await Geolocator.requestPermission();
    }
    if (permissao == LocationPermission.deniedForever) {
      _estado('Permissão bloqueada', 'Abra as configurações e permita localização.', false);
      await Geolocator.openAppSettings();
      return;
    }
    if (permissao != LocationPermission.always) {
      _estado(
        'Permita o tempo todo',
        'Nas configurações de Localização escolha “Permitir o tempo todo” e volte ao app.',
        false,
      );
      await Geolocator.openAppSettings();
      return;
    }
    await _iniciarEValidar();
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
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 24),
                  Text(titulo, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(detalhe, textAlign: TextAlign.center),
                  const SizedBox(height: 28),
                  if (processando)
                    const CircularProgressIndicator()
                  else
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: configurar,
                        icon: const Icon(Icons.location_on_outlined),
                        label: const Text('Tentar novamente'),
                      ),
                    ),
                  const SizedBox(height: 18),
                  Text(
                    'Quando ativo, o Android mantém uma notificação visível enquanto a localização é compartilhada.',
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
