import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
const trackedDeviceId = String.fromEnvironment(
  'DEVICE_ID',
  defaultValue: 'celular-01',
);

void main() => runApp(const PainelApp());

class PainelApp extends StatelessWidget {
  const PainelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Painel de Localização',
      theme: ThemeData(useMaterial3: true),
      home: const LoginPage(),
    );
  }
}

class SessionData {
  SessionData({required this.accessToken, required this.refreshToken});

  String accessToken;
  String refreshToken;
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final email = TextEditingController();
  final senha = TextEditingController();
  bool carregando = false;
  String? erro;

  Future<void> entrar() async {
    if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) {
      setState(() => erro = 'APK compilado sem configuração do Supabase.');
      return;
    }

    setState(() {
      carregando = true;
      erro = null;
    });

    try {
      final response = await http
          .post(
            Uri.parse('$supabaseUrl/auth/v1/token?grant_type=password'),
            headers: {
              'apikey': supabaseAnonKey,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'email': email.text.trim(),
              'password': senha.text,
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        if (!mounted) return;
        setState(() {
          erro = (body['msg'] ?? body['error_description'] ?? 'Falha no login')
              .toString();
        });
        return;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final accessToken = data['access_token']?.toString() ?? '';
      final refreshToken = data['refresh_token']?.toString() ?? '';

      if (accessToken.isEmpty || refreshToken.isEmpty) {
        if (mounted) setState(() => erro = 'Sessão não recebida do servidor.');
        return;
      }

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => PainelPage(
            session: SessionData(
              accessToken: accessToken,
              refreshToken: refreshToken,
            ),
          ),
        ),
      );
    } on TimeoutException {
      if (mounted) setState(() => erro = 'O servidor demorou para responder.');
    } catch (e) {
      if (mounted) setState(() => erro = 'Erro de rede: $e');
    } finally {
      if (mounted) setState(() => carregando = false);
    }
  }

  @override
  void dispose() {
    email.dispose();
    senha.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Painel de localização')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              children: [
                const Icon(Icons.location_history, size: 72),
                const SizedBox(height: 24),
                TextField(
                  controller: email,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'E-mail',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: senha,
                  obscureText: true,
                  onSubmitted: (_) => entrar(),
                  decoration: const InputDecoration(
                    labelText: 'Senha',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (erro != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    erro!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: carregando ? null : entrar,
                    child: Text(carregando ? 'Entrando...' : 'Entrar'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PainelPage extends StatefulWidget {
  const PainelPage({super.key, required this.session});

  final SessionData session;

  @override
  State<PainelPage> createState() => _PainelPageState();
}

class _PainelPageState extends State<PainelPage> {
  final mapController = MapController();
  Timer? timer;
  List<LocationRecord> historico = [];
  CommandRecord? ultimoComando;
  int? ultimoId;
  bool carregando = true;
  bool atualizando = false;
  bool solicitando = false;
  String? erro;

  @override
  void initState() {
    super.initState();
    atualizar();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => atualizar());
  }

  Map<String, String> get authHeaders => {
        'apikey': supabaseAnonKey,
        'Authorization': 'Bearer ${widget.session.accessToken}',
        'Content-Type': 'application/json',
      };

  Future<bool> renovarSessao() async {
    try {
      final response = await http
          .post(
            Uri.parse('$supabaseUrl/auth/v1/token?grant_type=refresh_token'),
            headers: {
              'apikey': supabaseAnonKey,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'refresh_token': widget.session.refreshToken}),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode < 200 || response.statusCode >= 300) return false;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final accessToken = data['access_token']?.toString() ?? '';
      final refreshToken = data['refresh_token']?.toString() ?? '';
      if (accessToken.isEmpty) return false;

      widget.session.accessToken = accessToken;
      if (refreshToken.isNotEmpty) widget.session.refreshToken = refreshToken;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<http.Response> getAutenticado(Uri uri) async {
    var response = await http
        .get(uri, headers: authHeaders)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 401 && await renovarSessao()) {
      response = await http
          .get(uri, headers: authHeaders)
          .timeout(const Duration(seconds: 20));
    }
    return response;
  }

  Future<http.Response> postAutenticado(Uri uri, Object body) async {
    var response = await http
        .post(
          uri,
          headers: {...authHeaders, 'Prefer': 'return=representation'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 401 && await renovarSessao()) {
      response = await http
          .post(
            uri,
            headers: {...authHeaders, 'Prefer': 'return=representation'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));
    }
    return response;
  }

  Future<http.Response> consultarLocalizacoes() {
    final uri = Uri.parse(
      '$supabaseUrl/rest/v1/locations'
      '?select=id,device_id,latitude,longitude,accuracy,speed,event,client_time,created_at'
      '&device_id=eq.$trackedDeviceId'
      '&order=created_at.desc'
      '&limit=150',
    );
    return getAutenticado(uri);
  }

  Future<http.Response> consultarUltimoComando() {
    final uri = Uri.parse(
      '$supabaseUrl/rest/v1/location_commands'
      '?select=id,device_id,command,status,requested_at,processed_at,error'
      '&device_id=eq.$trackedDeviceId'
      '&order=requested_at.desc'
      '&limit=1',
    );
    return getAutenticado(uri);
  }

  Future<void> atualizar() async {
    if (atualizando) return;
    atualizando = true;

    try {
      final locationResponse = await consultarLocalizacoes();
      if (locationResponse.statusCode < 200 || locationResponse.statusCode >= 300) {
        if (!mounted) return;
        setState(() {
          erro = locationResponse.statusCode == 401
              ? 'Sessão expirada. Entre novamente.'
              : 'Falha ao consultar localização (${locationResponse.statusCode}).';
          carregando = false;
        });
        return;
      }

      final raw = jsonDecode(locationResponse.body) as List<dynamic>;
      final novos = raw
          .map((e) => LocationRecord.fromJson(e as Map<String, dynamic>))
          .toList();

      CommandRecord? comando;
      final commandResponse = await consultarUltimoComando();
      if (commandResponse.statusCode >= 200 && commandResponse.statusCode < 300) {
        final commandRaw = jsonDecode(commandResponse.body) as List<dynamic>;
        if (commandRaw.isNotEmpty) {
          comando = CommandRecord.fromJson(
            commandRaw.first as Map<String, dynamic>,
          );
        }
      } else if (commandResponse.statusCode == 404) {
        erro = 'A função Localizar agora ainda não foi ativada no Supabase.';
      }

      final idAnterior = ultimoId;
      final novosMovimentos = idAnterior == null
          ? <LocationRecord>[]
          : novos
              .where((e) => e.id > idAnterior && e.event == 'movement')
              .toList();

      final atual = novos.isEmpty ? null : novos.first;
      if (atual != null) ultimoId = atual.id;

      if (!mounted) return;
      setState(() {
        historico = novos;
        ultimoComando = comando;
        if (commandResponse.statusCode != 404) erro = null;
        carregando = false;
      });

      if (atual != null) {
        mapController.move(LatLng(atual.latitude, atual.longitude), 16);
      }

      if (novosMovimentos.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              novosMovimentos.length == 1
                  ? 'Movimento detectado.'
                  : '${novosMovimentos.length} movimentos novos detectados.',
            ),
          ),
        );
      }
    } on TimeoutException {
      if (mounted) {
        setState(() {
          erro = 'O servidor demorou para responder.';
          carregando = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          erro = 'Erro de rede: $e';
          carregando = false;
        });
      }
    } finally {
      atualizando = false;
    }
  }

  Future<void> localizarAgora() async {
    if (solicitando) return;

    setState(() => solicitando = true);
    try {
      final response = await postAutenticado(
        Uri.parse('$supabaseUrl/rest/v1/location_commands'),
        {
          'device_id': trackedDeviceId,
          'command': 'locate_now',
          'status': 'pending',
        },
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (!mounted) return;
        final detalhe = response.statusCode == 404
            ? 'Execute a atualização SQL do recurso Localizar agora no Supabase.'
            : 'Código ${response.statusCode}.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Não foi possível solicitar a localização. $detalhe')),
        );
        return;
      }

      final data = jsonDecode(response.body) as List<dynamic>;
      if (data.isNotEmpty && mounted) {
        setState(() {
          ultimoComando = CommandRecord.fromJson(
            data.first as Map<String, dynamic>,
          );
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Solicitação enviada ao celular.')),
        );
      }
      await atualizar();
    } on TimeoutException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('O servidor demorou para responder.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao solicitar localização: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => solicitando = false);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    mapController.dispose();
    super.dispose();
  }

  bool get dispositivoOnline {
    if (historico.isEmpty) return false;
    final idade = DateTime.now().toUtc().difference(historico.first.createdAt.toUtc());
    return idade <= const Duration(minutes: 2, seconds: 30);
  }

  bool get comandoAguardando {
    final comando = ultimoComando;
    if (comando == null || comando.status != 'pending') return false;
    final idade = DateTime.now().toUtc().difference(comando.requestedAt.toUtc());
    return idade <= const Duration(minutes: 2);
  }

  String get textoComando {
    final comando = ultimoComando;
    if (comando == null) return 'Nenhuma localização manual solicitada ainda.';

    if (comando.status == 'pending') {
      final idade = DateTime.now().toUtc().difference(comando.requestedAt.toUtc());
      if (idade > const Duration(minutes: 2)) {
        return 'O celular não respondeu à última solicitação.';
      }
      return 'Solicitando uma posição nova ao celular...';
    }
    if (comando.status == 'completed') {
      return 'Última localização manual concluída ${tempoRelativo(comando.processedAt ?? comando.requestedAt)}.';
    }
    if (comando.status == 'failed') {
      return 'Última solicitação falhou${comando.error == null ? '.' : ': ${comando.error}'}';
    }
    return 'Status: ${comando.status}';
  }

  @override
  Widget build(BuildContext context) {
    if (carregando) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (erro != null && historico.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Painel de localização')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(erro!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: atualizar,
                  child: const Text('Tentar novamente'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final atual = historico.isEmpty ? null : historico.first;
    final rota = historico
        .reversed
        .where((e) => e.event != 'heartbeat')
        .map((e) => LatLng(e.latitude, e.longitude))
        .toList();
    final linhaDoTempo = historico.where((e) => e.event != 'heartbeat').toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dispositivos'),
        actions: [
          IconButton(
            onPressed: atualizar,
            icon: const Icon(Icons.refresh),
            tooltip: 'Atualizar',
          ),
        ],
      ),
      body: Column(
        children: [
          if (erro != null)
            MaterialBanner(
              content: Text(erro!),
              actions: [
                TextButton(onPressed: atualizar, child: const Text('Tentar')),
              ],
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: DeviceCard(
              deviceId: trackedDeviceId,
              online: dispositivoOnline,
              atual: atual,
              commandText: textoComando,
              locating: solicitando || comandoAguardando,
              onLocate: localizarAgora,
            ),
          ),
          if (atual != null)
            SizedBox(
              height: 245,
              child: FlutterMap(
                mapController: mapController,
                options: MapOptions(
                  initialCenter: LatLng(atual.latitude, atual.longitude),
                  initialZoom: 16,
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.rastreador_painel',
                  ),
                  if (rota.length > 1)
                    PolylineLayer(
                      polylines: [Polyline(points: rota, strokeWidth: 4)],
                    ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: LatLng(atual.latitude, atual.longitude),
                        width: 56,
                        height: 56,
                        child: const Icon(Icons.location_pin, size: 48),
                      ),
                    ],
                  ),
                  RichAttributionWidget(
                    attributions: const [
                      TextSourceAttribution('OpenStreetMap contributors'),
                    ],
                  ),
                ],
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Nenhuma localização recebida ainda.'),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Row(
              children: [
                const Icon(Icons.timeline),
                const SizedBox(width: 8),
                Text(
                  'Linha do tempo',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                Text('${linhaDoTempo.length} eventos'),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: atualizar,
              child: linhaDoTempo.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(height: 48),
                        Center(child: Text('Nenhum evento de trajeto ainda.')),
                      ],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: linhaDoTempo.length,
                      itemBuilder: (context, index) => TimelineItem(
                        item: linhaDoTempo[index],
                        isLast: index == linhaDoTempo.length - 1,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class DeviceCard extends StatelessWidget {
  const DeviceCard({
    super.key,
    required this.deviceId,
    required this.online,
    required this.atual,
    required this.commandText,
    required this.locating,
    required this.onLocate,
  });

  final String deviceId;
  final bool online;
  final LocationRecord? atual;
  final String commandText;
  final bool locating;
  final VoidCallback onLocate;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(child: Icon(Icons.smartphone)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(deviceId, style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(
                            online ? Icons.circle : Icons.circle_outlined,
                            size: 12,
                          ),
                          const SizedBox(width: 5),
                          Text(online ? 'Online' : 'Offline'),
                          if (atual != null) ...[
                            const Text('  •  '),
                            Text('visto ${tempoRelativo(atual!.createdAt)}'),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: locating ? null : onLocate,
                  icon: locating
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.my_location),
                  label: Text(locating ? 'Localizando' : 'Localizar agora'),
                ),
              ],
            ),
            if (atual != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 5,
                children: [
                  Text('Precisão: ${atual!.accuracy?.toStringAsFixed(0) ?? '-'} m'),
                  Text('Velocidade: ${formatarVelocidade(atual!.speed)}'),
                  Text(
                    '${atual!.latitude.toStringAsFixed(5)}, ${atual!.longitude.toStringAsFixed(5)}',
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text(commandText)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class TimelineItem extends StatelessWidget {
  const TimelineItem({super.key, required this.item, required this.isLast});

  final LocationRecord item;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final titulo = switch (item.event) {
      'startup' => 'Monitoramento iniciado',
      'manual' => 'Localização solicitada',
      'heartbeat' => 'Sinal de atividade',
      _ => 'Movimento detectado',
    };
    final destaque = item.event == 'movement' || item.event == 'manual';
    final icon = switch (item.event) {
      'manual' => Icons.my_location,
      'startup' => Icons.play_circle_outline,
      _ => Icons.directions_walk,
    };

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 56,
            child: Column(
              children: [
                const SizedBox(height: 12),
                Icon(icon, size: destaque ? 24 : 18),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Card(
              margin: const EdgeInsets.fromLTRB(0, 6, 12, 6),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            titulo,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        Text(formatarData(item.time)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${item.latitude.toStringAsFixed(6)}, ${item.longitude.toStringAsFixed(6)}',
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Precisão: ${item.accuracy?.toStringAsFixed(0) ?? '-'} m'
                      '  •  Velocidade: ${formatarVelocidade(item.speed)}',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String formatarVelocidade(double? metrosSegundo) {
  if (metrosSegundo == null || metrosSegundo < 0) return '-';
  return '${(metrosSegundo * 3.6).toStringAsFixed(1)} km/h';
}

String formatarData(DateTime data) {
  final local = data.toLocal();
  String d(int n) => n.toString().padLeft(2, '0');
  return '${d(local.day)}/${d(local.month)} ${d(local.hour)}:${d(local.minute)}';
}

String tempoRelativo(DateTime data) {
  final diff = DateTime.now().toUtc().difference(data.toUtc());
  if (diff.isNegative || diff.inSeconds < 10) return 'agora';
  if (diff.inSeconds < 60) return 'há ${diff.inSeconds}s';
  if (diff.inMinutes < 60) return 'há ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'há ${diff.inHours} h';
  return 'há ${diff.inDays} d';
}

class CommandRecord {
  const CommandRecord({
    required this.id,
    required this.status,
    required this.requestedAt,
    this.processedAt,
    this.error,
  });

  final int id;
  final String status;
  final DateTime requestedAt;
  final DateTime? processedAt;
  final String? error;

  factory CommandRecord.fromJson(Map<String, dynamic> json) {
    return CommandRecord(
      id: (json['id'] as num).toInt(),
      status: json['status']?.toString() ?? 'pending',
      requestedAt: DateTime.parse(json['requested_at'].toString()),
      processedAt: json['processed_at'] == null
          ? null
          : DateTime.tryParse(json['processed_at'].toString()),
      error: json['error']?.toString(),
    );
  }
}

class LocationRecord {
  const LocationRecord({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.event,
    required this.time,
    required this.createdAt,
    this.accuracy,
    this.speed,
  });

  final int id;
  final double latitude;
  final double longitude;
  final double? accuracy;
  final double? speed;
  final String event;
  final DateTime time;
  final DateTime createdAt;

  factory LocationRecord.fromJson(Map<String, dynamic> json) {
    double? number(dynamic value) => value == null
        ? null
        : value is num
            ? value.toDouble()
            : double.tryParse(value.toString());

    final createdAt = DateTime.parse(json['created_at'].toString());
    return LocationRecord(
      id: (json['id'] as num).toInt(),
      latitude: number(json['latitude'])!,
      longitude: number(json['longitude'])!,
      accuracy: number(json['accuracy']),
      speed: number(json['speed']),
      event: json['event']?.toString() ?? 'movement',
      time: DateTime.tryParse(json['client_time']?.toString() ?? '') ?? createdAt,
      createdAt: createdAt,
    );
  }
}
