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
  final String refreshToken;
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
      final response = await http.post(
        Uri.parse('$supabaseUrl/auth/v1/token?grant_type=password'),
        headers: {
          'apikey': supabaseAnonKey,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'email': email.text.trim(),
          'password': senha.text,
        }),
      ).timeout(const Duration(seconds: 20));

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
  int? ultimoId;
  bool carregando = true;
  bool atualizando = false;
  String? erro;

  @override
  void initState() {
    super.initState();
    atualizar();
    timer = Timer.periodic(const Duration(seconds: 10), (_) => atualizar());
  }

  Future<bool> renovarSessao() async {
    try {
      final response = await http.post(
        Uri.parse('$supabaseUrl/auth/v1/token?grant_type=refresh_token'),
        headers: {
          'apikey': supabaseAnonKey,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'refresh_token': widget.session.refreshToken}),
      ).timeout(const Duration(seconds: 20));

      if (response.statusCode < 200 || response.statusCode >= 300) return false;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final token = data['access_token']?.toString() ?? '';
      if (token.isEmpty) return false;
      widget.session.accessToken = token;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<http.Response> consultar() {
    final uri = Uri.parse(
      '$supabaseUrl/rest/v1/locations'
      '?select=id,device_id,latitude,longitude,accuracy,speed,event,client_time,created_at'
      '&device_id=eq.$trackedDeviceId'
      '&order=created_at.desc'
      '&limit=100',
    );

    return http.get(
      uri,
      headers: {
        'apikey': supabaseAnonKey,
        'Authorization': 'Bearer ${widget.session.accessToken}',
      },
    ).timeout(const Duration(seconds: 20));
  }

  Future<void> atualizar() async {
    if (atualizando) return;
    atualizando = true;

    try {
      var response = await consultar();
      if (response.statusCode == 401 && await renovarSessao()) {
        response = await consultar();
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (!mounted) return;
        setState(() {
          erro = response.statusCode == 401
              ? 'Sessão expirada. Entre novamente.'
              : 'Falha ao consultar localização (${response.statusCode}).';
          carregando = false;
        });
        return;
      }

      final raw = jsonDecode(response.body) as List<dynamic>;
      final novos = raw
          .map((e) => LocationRecord.fromJson(e as Map<String, dynamic>))
          .toList();

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
        erro = null;
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

  @override
  void dispose() {
    timer?.cancel();
    mapController.dispose();
    super.dispose();
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
                FilledButton(onPressed: atualizar, child: const Text('Tentar novamente')),
              ],
            ),
          ),
        ),
      );
    }

    if (historico.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Painel de localização')),
        body: const Center(child: Text('Nenhuma localização recebida ainda.')),
      );
    }

    final atual = historico.first;
    final rota = historico
        .reversed
        .where((e) => e.event != 'heartbeat')
        .map((e) => LatLng(e.latitude, e.longitude))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(trackedDeviceId),
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
          SizedBox(
            height: 310,
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
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.timeline),
                const SizedBox(width: 8),
                Text('Linha do tempo', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                Text('${historico.length} registros'),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: atualizar,
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: historico.length,
                itemBuilder: (context, index) => TimelineItem(
                  item: historico[index],
                  isLast: index == historico.length - 1,
                ),
              ),
            ),
          ),
        ],
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
      'heartbeat' => 'Sinal de atividade',
      _ => 'Movimento detectado',
    };
    final movimento = item.event == 'movement';

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 56,
            child: Column(
              children: [
                const SizedBox(height: 12),
                Icon(movimento ? Icons.directions_walk : Icons.circle, size: movimento ? 24 : 14),
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
                        Expanded(child: Text(titulo, style: Theme.of(context).textTheme.titleMedium)),
                        Text(formatarData(item.time)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('${item.latitude.toStringAsFixed(6)}, ${item.longitude.toStringAsFixed(6)}'),
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

class LocationRecord {
  const LocationRecord({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.event,
    required this.time,
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

  factory LocationRecord.fromJson(Map<String, dynamic> json) {
    double? number(dynamic value) => value == null
        ? null
        : value is num
            ? value.toDouble()
            : double.tryParse(value.toString());

    return LocationRecord(
      id: (json['id'] as num).toInt(),
      latitude: number(json['latitude'])!,
      longitude: number(json['longitude'])!,
      accuracy: number(json['accuracy']),
      speed: number(json['speed']),
      event: json['event']?.toString() ?? 'movement',
      time: DateTime.parse((json['client_time'] ?? json['created_at']).toString()),
    );
  }
}
