import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

const String apiUrl = 'https://SEU-SERVIDOR.com/localizacao';
const String deviceId = 'celular-01';

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
      isForegroundMode: true,
      notificationChannelId: 'localizacao_service',
      initialNotificationTitle: 'Localização ativa',
      initialNotificationContent: 'Monitoramento de localização em execução',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  const locationSettings = LocationSettings(
    accuracy: LocationAccuracy.high,
    distanceFilter: 20,
  );

  Geolocator.getPositionStream(
    locationSettings: locationSettings,
  ).listen((Position position) async {
    try {
      await http.post(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
        },
        body: '''
        {
          "device_id": "$deviceId",
          "latitude": ${position.latitude},
          "longitude": ${position.longitude},
          "accuracy": ${position.accuracy},
          "speed": ${position.speed},
          "timestamp": "${DateTime.now().toUtc().toIso8601String()}"
        }
        ''',
      );

      debugPrint(
        'Localização enviada: '
        '${position.latitude}, ${position.longitude}',
      );
    } catch (e) {
      debugPrint('Erro ao enviar localização: $e');
    }
  });
}

class MeuApp extends StatelessWidget {
  const MeuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: TelaInicial(),
    );
  }
}

class TelaInicial extends StatefulWidget {
  const TelaInicial({super.key});

  @override
  State<TelaInicial> createState() => _TelaInicialState();
}

class _TelaInicialState extends State<TelaInicial> {
  String status = 'Toque para ativar';

  Future<void> ativarMonitoramento() async {
    final gpsAtivo = await Geolocator.isLocationServiceEnabled();

    if (!gpsAtivo) {
      setState(() {
        status = 'Ative o GPS do celular';
      });

      await Geolocator.openLocationSettings();
      return;
    }

    var permissao = await Geolocator.checkPermission();

    if (permissao == LocationPermission.denied) {
      permissao = await Geolocator.requestPermission();
    }

    if (permissao == LocationPermission.denied ||
        permissao == LocationPermission.deniedForever) {
      setState(() {
        status = 'Permissão negada';
      });

      return;
    }

    final service = FlutterBackgroundService();

    await service.startService();

    setState(() {
      status = 'Monitoramento ativo';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: ativarMonitoramento,
          child: Text(status),
        ),
      ),
    );
  }
}