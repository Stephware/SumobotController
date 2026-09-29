import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

void main() {
  runApp(const SumobotApp());
}

class SumobotApp extends StatelessWidget {
  const SumobotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Sumobot Controller',
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0B0D10),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1976D2),
          brightness: Brightness.dark,
        ),
      ),
      home: const SumobotControllerPage(),
    );
  }
}

enum ControlMode { manual, automatic }
enum DriveDirection { stopped, forward, reverse }
enum SteeringDirection { center, left, right }

class SumobotControllerPage extends StatefulWidget {
  const SumobotControllerPage({super.key});

  @override
  State<SumobotControllerPage> createState() =>
      _SumobotControllerPageState();
}

class _SumobotControllerPageState extends State<SumobotControllerPage> {
  static const String _ssid = 'ESP32-ROBOT';
  static const String _baseUrl = 'http://192.168.4.1';

  static const int _enemyDistanceMm = 200;
  static const int _noDetectionMm = 8190;
  static const int _unknownEdgeValue = -1;

  static const double _joystickSize = 220;
  static const double _joystickKnobSize = 72;
  static const double _joystickDeadZone = 24;

  ControlMode mode = ControlMode.manual;
  DriveDirection driveDirection = DriveDirection.stopped;
  SteeringDirection steeringDirection = SteeringDirection.center;

  bool isConnected = false;
  bool isCheckingConnection = false;
  bool _statusRequestInFlight = false;

  String connectionMessage =
      'Connect to ESP32-ROBOT, then test the connection.';
  String lastCommand = 'NONE';

  String espMode = 'MANUAL';
  String robotState = 'IDLE';

  int tofNW = _noDetectionMm;
  int tofNE = _noDetectionMm;
  bool opponentLocated = false;

  int edgeFrontLeft = _unknownEdgeValue;
  int edgeFrontRight = _unknownEdgeValue;
  bool edgeFrontLeftDetected = false;
  bool edgeFrontRightDetected = false;

  DateTime? lastStatusUpdate;

  Offset _joystickOffset = Offset.zero;
  Future<void> _commandTail = Future<void>.value();
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();

    _statusTimer = Timer.periodic(
      const Duration(milliseconds: 700),
      (_) {
        if (isConnected) {
          unawaited(_fetchStatus());
        }
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _testConnection(showFeedback: false);
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<String?> _get(
    String path, {
    bool updateCommand = false,
    bool affectConnection = true,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);

    try {
      final request = await client.getUrl(Uri.parse('$_baseUrl$path'));
      request.persistentConnection = false;

      final response = await request.close().timeout(
            const Duration(seconds: 3),
          );
      final body = await utf8.decoder.bind(response).join();
      final success = response.statusCode == HttpStatus.ok;

      if (!mounted) return success ? body : null;

      if (affectConnection || success) {
        setState(() {
          if (affectConnection) {
            isConnected = success;
            connectionMessage = success
                ? 'Connected to ESP32 at 192.168.4.1'
                : 'ESP32 responded with HTTP ${response.statusCode}.';
          }

          if (success && updateCommand) {
            lastCommand = path;
          }
        });
      }

      return success ? body : null;
    } catch (_) {
      if (mounted && affectConnection) {
        setState(() {
          isConnected = false;
          connectionMessage =
              'No response. Make sure the phone is connected to $_ssid.';
        });
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _queueCommand(String path) {
    final completer = Completer<bool>();

    _commandTail = _commandTail.then((_) async {
      final body = await _get(path, updateCommand: true);
      if (!completer.isCompleted) {
        completer.complete(body != null);
      }
    });

    return completer.future;
  }

  Future<void> _testConnection({required bool showFeedback}) async {
    if (isCheckingConnection) return;

    setState(() {
      isCheckingConnection = true;
      connectionMessage = 'Checking ESP32 connection...';
    });

    final body = await _get('/');
    final success = body != null;

    if (!mounted) return;

    setState(() {
      isCheckingConnection = false;
    });

    if (success) {
      await _fetchStatus();
    }

    if (showFeedback && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? 'ESP32 connected successfully.'
                : 'ESP32 not found. Connect to $_ssid first.',
          ),
        ),
      );
    }
  }

  Future<void> _fetchStatus() async {
    if (_statusRequestInFlight || !isConnected) return;

    _statusRequestInFlight = true;

    try {
      final body = await _get('/status', affectConnection: false);
      if (body == null || !mounted) return;

      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return;

      final tof = decoded['tof'];
      final dynamic edgeData = decoded['edge'] ?? decoded['tcrt'];
      final dynamic edgeDetectedData = decoded['edgeDetected'];

      setState(() {
        espMode = decoded['mode']?.toString() ?? espMode;
        robotState = decoded['state']?.toString() ?? robotState;
        opponentLocated = _asBool(decoded['opponentLocated'], opponentLocated);

        if (tof is Map<String, dynamic>) {
          tofNW = _asInt(tof['nw'] ?? tof['left'], tofNW);
          tofNE = _asInt(tof['ne'] ?? tof['right'], tofNE);
        }

        if (edgeData is Map<String, dynamic>) {
          edgeFrontLeft = _asInt(
            edgeData['frontLeft'] ?? edgeData['fl'] ?? edgeData['left'],
            edgeFrontLeft,
          );
          edgeFrontRight = _asInt(
            edgeData['frontRight'] ?? edgeData['fr'] ?? edgeData['right'],
            edgeFrontRight,
          );

          edgeFrontLeftDetected = _asBool(
            edgeData['frontLeftDetected'] ??
                edgeData['flDetected'] ??
                edgeData['leftDetected'],
            edgeFrontLeftDetected,
          );
          edgeFrontRightDetected = _asBool(
            edgeData['frontRightDetected'] ??
                edgeData['frDetected'] ??
                edgeData['rightDetected'],
            edgeFrontRightDetected,
          );
        }

        if (edgeDetectedData is Map<String, dynamic>) {
          edgeFrontLeftDetected = _asBool(
            edgeDetectedData['frontLeft'] ??
                edgeDetectedData['fl'] ??
                edgeDetectedData['left'],
            edgeFrontLeftDetected,
          );
          edgeFrontRightDetected = _asBool(
            edgeDetectedData['frontRight'] ??
                edgeDetectedData['fr'] ??
                edgeDetectedData['right'],
            edgeFrontRightDetected,
          );
        }

        lastStatusUpdate = DateTime.now();
      });
    } catch (_) {
      // Keep the latest valid values when a response is incomplete.
    } finally {
      _statusRequestInFlight = false;
    }
  }

  int _asInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  bool _asBool(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value?.toString().toLowerCase() == 'true') return true;
    if (value?.toString().toLowerCase() == 'false') return false;
    return fallback;
  }

  bool _targetDetected(int distance) {
    return distance > 0 && distance <= _enemyDistanceMm;
  }

  bool get _anyEdgeDetected =>
      edgeFrontLeftDetected || edgeFrontRightDetected;

  Future<void> _stopAll() async {
    if (mounted) {
      setState(() {
        driveDirection = DriveDirection.stopped;
        steeringDirection = SteeringDirection.center;
        _joystickOffset = Offset.zero;
      });
    }

    if (isConnected) {
      await _queueCommand('/s');
      await _fetchStatus();
    }
  }

  Future<void> _changeMode(ControlMode newMode) async {
    if (newMode == mode) return;

    if (newMode == ControlMode.manual) {
      if (isConnected) {
        await _queueCommand('/auto/stop');
      }

      if (!mounted) return;
      setState(() {
        mode = ControlMode.manual;
        driveDirection = DriveDirection.stopped;
        steeringDirection = SteeringDirection.center;
        _joystickOffset = Offset.zero;
      });
      await _fetchStatus();
      return;
    }

    await _stopAll();

    if (!mounted) return;
    setState(() {
      mode = ControlMode.automatic;
    });
    await _fetchStatus();
  }

  Future<void> _startAuto() async {
    if (!isConnected) return;

    final success = await _queueCommand('/auto/start');
    if (!success || !mounted) return;

    setState(() {
      espMode = 'AUTO';
      robotState = 'SEARCHING';
    });

    await _fetchStatus();
  }

  Future<void> _stopAuto() async {
    if (!isConnected) return;

    final success = await _queueCommand('/auto/stop');
    if (!success || !mounted) return;

    setState(() {
      espMode = 'MANUAL';
      robotState = 'IDLE';
    });

    await _fetchStatus();
  }

  String? _driveEndpoint(DriveDirection direction) {
    return switch (direction) {
      DriveDirection.forward => '/b',
      DriveDirection.reverse => '/f',
      DriveDirection.stopped => null,
    };
  }

  String? _steeringEndpoint(SteeringDirection direction) {
    return switch (direction) {
      SteeringDirection.left => '/r',
      SteeringDirection.right => '/l',
      SteeringDirection.center => null,
    };
  }

  String? _diagonalEndpoint(
    DriveDirection drive,
    SteeringDirection steering,
  ) {
    if (drive == DriveDirection.forward &&
        steering == SteeringDirection.left) {
      return '/rr';
    }
    if (drive == DriveDirection.forward &&
        steering == SteeringDirection.right) {
      return '/rl';
    }
    if (drive == DriveDirection.reverse &&
        steering == SteeringDirection.left) {
      return '/fr';
    }
    if (drive == DriveDirection.reverse &&
        steering == SteeringDirection.right) {
      return '/fl';
    }
    return null;
  }

  void _updateJoystick(Offset localPosition) {
    if (!isConnected || mode != ControlMode.manual) return;

    const center = Offset(_joystickSize / 2, _joystickSize / 2);
    const maxTravel = (_joystickSize - _joystickKnobSize) / 2;

    var offset = localPosition - center;
    final distance = offset.distance;

    if (distance > maxTravel && distance > 0) {
      offset = offset * (maxTravel / distance);
    }

    final newDrive = offset.dy < -_joystickDeadZone
        ? DriveDirection.forward
        : offset.dy > _joystickDeadZone
            ? DriveDirection.reverse
            : DriveDirection.stopped;

    final newSteering = offset.dx < -_joystickDeadZone
        ? SteeringDirection.left
        : offset.dx > _joystickDeadZone
            ? SteeringDirection.right
            : SteeringDirection.center;

    final oldDrive = driveDirection;
    final oldSteering = steeringDirection;

    setState(() {
      _joystickOffset = offset;
      driveDirection = newDrive;
      steeringDirection = newSteering;
    });

    if (oldDrive != newDrive || oldSteering != newSteering) {
      unawaited(
        _sendJoystickTransition(
          oldDrive: oldDrive,
          oldSteering: oldSteering,
          newDrive: newDrive,
          newSteering: newSteering,
        ),
      );
    }
  }

  void _releaseJoystick() {
    if (mode != ControlMode.manual) return;

    final wasMoving = driveDirection != DriveDirection.stopped ||
        steeringDirection != SteeringDirection.center;

    setState(() {
      _joystickOffset = Offset.zero;
      driveDirection = DriveDirection.stopped;
      steeringDirection = SteeringDirection.center;
    });

    if (isConnected && wasMoving) {
      unawaited(_queueCommand('/s'));
    }
  }

  Future<void> _sendJoystickTransition({
    required DriveDirection oldDrive,
    required SteeringDirection oldSteering,
    required DriveDirection newDrive,
    required SteeringDirection newSteering,
  }) async {
    final diagonal = _diagonalEndpoint(newDrive, newSteering);
    if (diagonal != null) {
      await _queueCommand(diagonal);
      return;
    }

    final oldWasDiagonal = oldDrive != DriveDirection.stopped &&
        oldSteering != SteeringDirection.center;
    final driveWasReleased = oldDrive != DriveDirection.stopped &&
        newDrive == DriveDirection.stopped;
    final steeringWasReleased = oldSteering != SteeringDirection.center &&
        newSteering == SteeringDirection.center;

    if (oldWasDiagonal || driveWasReleased || steeringWasReleased) {
      final stopped = await _queueCommand('/s');
      if (!stopped || !mounted) return;

      final driveEndpoint = _driveEndpoint(newDrive);
      if (driveEndpoint != null) await _queueCommand(driveEndpoint);

      final steeringEndpoint = _steeringEndpoint(newSteering);
      if (steeringEndpoint != null) await _queueCommand(steeringEndpoint);
      return;
    }

    if (newDrive != oldDrive) {
      final endpoint = _driveEndpoint(newDrive);
      if (endpoint != null) await _queueCommand(endpoint);
    }

    if (newSteering != oldSteering) {
      final endpoint = _steeringEndpoint(newSteering);
      if (endpoint != null) await _queueCommand(endpoint);
    }
  }

  String get driveText => switch (driveDirection) {
        DriveDirection.forward => 'FORWARD',
        DriveDirection.reverse => 'REVERSE',
        DriveDirection.stopped => 'STOPPED',
      };

  String get steeringText => switch (steeringDirection) {
        SteeringDirection.left => 'LEFT',
        SteeringDirection.right => 'RIGHT',
        SteeringDirection.center => 'CENTER',
      };

  String get movementText {
    if (driveDirection == DriveDirection.stopped &&
        steeringDirection == SteeringDirection.center) {
      return 'STOPPED';
    }
    if (driveDirection == DriveDirection.forward &&
        steeringDirection == SteeringDirection.left) {
      return 'FORWARD LEFT';
    }
    if (driveDirection == DriveDirection.forward &&
        steeringDirection == SteeringDirection.right) {
      return 'FORWARD RIGHT';
    }
    if (driveDirection == DriveDirection.reverse &&
        steeringDirection == SteeringDirection.left) {
      return 'REVERSE LEFT';
    }
    if (driveDirection == DriveDirection.reverse &&
        steeringDirection == SteeringDirection.right) {
      return 'REVERSE RIGHT';
    }
    if (driveDirection == DriveDirection.forward) return 'FORWARD';
    if (driveDirection == DriveDirection.reverse) return 'REVERSE';
    if (steeringDirection == SteeringDirection.left) return 'LEFT';
    return 'RIGHT';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildModeSelector(),
            Expanded(
              child: mode == ControlMode.manual
                  ? _buildManualScreen()
                  : _buildAutomaticScreen(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
      child: Row(
        children: [
          Container(
            height: 44,
            width: 44,
            decoration: BoxDecoration(
              color: const Color(0xFF1E88E5).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(
              Icons.smart_toy_rounded,
              color: Color(0xFF42A5F5),
              size: 27,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SUMOBOT',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                  ),
                ),
                Text(
                  '2× VL53L0X + 2× TCRT5000L',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),
          _connectionBadge(),
        ],
      ),
    );
  }

  Widget _connectionBadge() {
    final color = isConnected ? Colors.greenAccent : Colors.redAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            isConnected ? 'Connected' : 'Offline',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: const Color(0xFF15181D),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Expanded(
              child: _modeButton(
                'MANUAL',
                Icons.gamepad_rounded,
                mode == ControlMode.manual,
                () => unawaited(_changeMode(ControlMode.manual)),
              ),
            ),
            Expanded(
              child: _modeButton(
                'AUTOMATIC',
                Icons.auto_mode_rounded,
                mode == ControlMode.automatic,
                () => unawaited(_changeMode(ControlMode.automatic)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeButton(
    String title,
    IconData icon,
    bool selected,
    VoidCallback onTap,
  ) {
    return Material(
      color: selected ? const Color(0xFF1565C0) : Colors.transparent,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: selected ? Colors.white : Colors.white54),
              const SizedBox(width: 7),
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: selected ? Colors.white : Colors.white54,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildManualScreen() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Column(
        children: [
          _buildConnectionBar(),
          const SizedBox(height: 8),
          _buildTcrtStrip(),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF14171C),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.055)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  const Text(
                    'MANUAL JOYSTICK',
                    style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      letterSpacing: 1.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'TCRT status remains visible while you drive manually',
                    style: TextStyle(color: Colors.white38, fontSize: 10.5),
                  ),
                  const Spacer(),
                  _buildJoystick(),
                  const Spacer(),
                  _buildMovementStatus(),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFD32F2F),
                foregroundColor: Colors.white,
              ),
              onPressed: isConnected ? () => unawaited(_stopAll()) : null,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('STOP ALL'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionBar() {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF14171C),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            Icons.wifi_rounded,
            color: isConnected ? Colors.greenAccent : Colors.white38,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              isConnected ? 'ESP32-ROBOT ready' : 'ESP32-ROBOT not connected',
              style: const TextStyle(fontSize: 11),
            ),
          ),
          IconButton(
            onPressed: isCheckingConnection
                ? null
                : () => _testConnection(showFeedback: true),
            icon: isCheckingConnection
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildTcrtStrip() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: _anyEdgeDetected
            ? Colors.redAccent.withValues(alpha: 0.10)
            : const Color(0xFF14171C),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _anyEdgeDetected
              ? Colors.redAccent.withValues(alpha: 0.45)
              : Colors.white.withValues(alpha: 0.055),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.border_outer_rounded,
            size: 19,
            color: _anyEdgeDetected ? Colors.redAccent : Colors.white38,
          ),
          const SizedBox(width: 9),
          const Text(
            'TCRT',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _miniEdgeStatus(
              'FL',
              edgeFrontLeft,
              edgeFrontLeftDetected,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _miniEdgeStatus(
              'FR',
              edgeFrontRight,
              edgeFrontRightDetected,
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniEdgeStatus(String label, int value, bool detected) {
    final known = value >= 0;
    final color = detected
        ? Colors.redAccent
        : known
            ? Colors.greenAccent
            : Colors.white30;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 10),
        ),
        const SizedBox(width: 5),
        Text(
          known ? '$value' : '--',
          style: const TextStyle(fontSize: 10, color: Colors.white60),
        ),
        const SizedBox(width: 5),
        Text(
          detected ? 'EDGE' : (known ? 'SAFE' : 'WAIT'),
          style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildMovementStatus() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF101318),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    movementText,
                    style: const TextStyle(
                      color: Colors.lightBlueAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  Text(
                    'Drive: $driveText • Steering: $steeringText',
                    style: const TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                ],
              ),
            ),
            Text(
              lastCommand,
              style: const TextStyle(color: Colors.white30, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildJoystick() {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 120),
      opacity: isConnected ? 1 : 0.35,
      child: SizedBox(
        width: _joystickSize,
        height: _joystickSize,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanDown: isConnected
              ? (details) => _updateJoystick(details.localPosition)
              : null,
          onPanUpdate: isConnected
              ? (details) => _updateJoystick(details.localPosition)
              : null,
          onPanEnd: isConnected ? (_) => _releaseJoystick() : null,
          onPanCancel: isConnected ? _releaseJoystick : null,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF101318),
                  border: Border.all(color: Colors.white12, width: 2),
                ),
              ),
              const Positioned(
                top: 14,
                child: Icon(Icons.keyboard_arrow_up_rounded,
                    color: Colors.white30, size: 32),
              ),
              const Positioned(
                bottom: 14,
                child: Icon(Icons.keyboard_arrow_down_rounded,
                    color: Colors.white30, size: 32),
              ),
              const Positioned(
                left: 14,
                child: Icon(Icons.keyboard_arrow_left_rounded,
                    color: Colors.white30, size: 32),
              ),
              const Positioned(
                right: 14,
                child: Icon(Icons.keyboard_arrow_right_rounded,
                    color: Colors.white30, size: 32),
              ),
              Transform.translate(
                offset: _joystickOffset,
                child: Container(
                  width: _joystickKnobSize,
                  height: _joystickKnobSize,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF42A5F5), Color(0xFF1565C0)],
                    ),
                  ),
                  child: const Icon(Icons.control_camera_rounded, size: 30),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAutomaticScreen() {
    final nwDetected = _targetDetected(tofNW);
    final neDetected = _targetDetected(tofNE);

    return RefreshIndicator(
      onRefresh: _fetchStatus,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        child: Column(
          children: [
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader(
                    Icons.auto_mode_rounded,
                    'Autonomous Test',
                    'Opponent tracking + TCRT boundary monitoring',
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF101318),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: _stateColor().withValues(alpha: 0.4),
                      ),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'ROBOT STATE',
                          style: TextStyle(color: Colors.white38, fontSize: 10),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          robotState,
                          style: TextStyle(
                            color: _stateColor(),
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _anyEdgeDetected
                              ? 'BOUNDARY DETECTED'
                              : 'Opponent located: ${opponentLocated ? 'YES' : 'NO'}',
                          style: TextStyle(
                            color: _anyEdgeDetected
                                ? Colors.redAccent
                                : Colors.white54,
                            fontSize: 11,
                            fontWeight: _anyEdgeDetected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: isConnected && espMode != 'AUTO'
                              ? () => unawaited(_startAuto())
                              : null,
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('START AUTO'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFD32F2F),
                          ),
                          onPressed: isConnected && espMode == 'AUTO'
                              ? () => unawaited(_stopAuto())
                              : null,
                          icon: const Icon(Icons.stop_rounded),
                          label: const Text('STOP AUTO'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader(
                    Icons.radar_rounded,
                    'VL53L0X Sensors',
                    'Opponent threshold: $_enemyDistanceMm mm',
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: _tofSensorTile('NW / LEFT', tofNW, nwDetected),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _tofSensorTile('NE / RIGHT', tofNE, neDetected),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _decisionBox(nwDetected, neDetected),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader(
                    Icons.border_outer_rounded,
                    'TCRT5000L Edge Sensors',
                    'Front-left and front-right boundary detection',
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: _edgeSensorTile(
                          'FRONT LEFT',
                          edgeFrontLeft,
                          edgeFrontLeftDetected,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _edgeSensorTile(
                          'FRONT RIGHT',
                          edgeFrontRight,
                          edgeFrontRightDetected,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: (_anyEdgeDetected
                              ? Colors.redAccent
                              : Colors.greenAccent)
                          .withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _anyEdgeDetected
                          ? 'EDGE PRIORITY: the ESP32 should override search / align / attack and perform its escape routine.'
                          : 'EDGE STATUS: clear. Normal search / align / attack logic may continue.',
                      style: TextStyle(
                        color: _anyEdgeDetected
                            ? Colors.redAccent
                            : Colors.greenAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader(
                    Icons.account_tree_rounded,
                    'Autonomous Priority',
                    'Boundary safety takes priority over opponent tracking',
                  ),
                  const SizedBox(height: 14),
                  _logicRow('TCRT edge', 'EDGE ESCAPE • highest priority'),
                  _logicRow('NW + NE', 'ATTACK straight'),
                  _logicRow('NW only', 'ALIGN toward opponent'),
                  _logicRow('NE only', 'ALIGN toward opponent'),
                  _logicRow('Neither', 'SEARCH'),
                  const Divider(height: 24),
                  const Text(
                    'Status API',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  _endpointRow('/status', 'Mode, state, VL53 and TCRT values'),
                  _endpointRow('/auto/start', 'Start autonomous state machine'),
                  _endpointRow('/auto/stop', 'Stop autonomous state machine'),
                  _endpointRow('/f /b /l /r /s', 'Manual single-axis controls'),
                  _endpointRow('/fl /fr /rl /rr', 'Manual diagonal controls'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              lastStatusUpdate == null
                  ? 'Waiting for ESP32 status...'
                  : 'Last status: ${_timeText(lastStatusUpdate!)}',
              style: const TextStyle(color: Colors.white38, fontSize: 10.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tofSensorTile(String label, int value, bool detected) {
    final display = value >= 8000 ? '--' : '$value';
    final color = detected ? Colors.greenAccent : Colors.white38;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            display,
            style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
          ),
          Text(
            value >= 8000 ? 'NO READING' : 'mm',
            style: const TextStyle(color: Colors.white38, fontSize: 9),
          ),
          const SizedBox(height: 7),
          Text(
            detected ? 'DETECTED' : 'CLEAR',
            style: TextStyle(
              color: detected ? Colors.greenAccent : Colors.white30,
              fontSize: 9,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _edgeSensorTile(String label, int value, bool detected) {
    final known = value >= 0;
    final color = detected
        ? Colors.redAccent
        : known
            ? Colors.greenAccent
            : Colors.white38;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            known ? '$value' : '--',
            style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
          ),
          const Text(
            'ADC',
            style: TextStyle(color: Colors.white38, fontSize: 9),
          ),
          const SizedBox(height: 7),
          Text(
            detected ? 'EDGE' : (known ? 'SAFE' : 'WAITING'),
            style: TextStyle(
              color: color,
              fontSize: 9,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _decisionBox(bool nw, bool ne) {
    late final String title;
    late final String detail;
    late final Color color;

    if (_anyEdgeDetected) {
      title = 'EDGE ESCAPE';
      detail = 'TCRT boundary detection overrides the VL53 opponent decision.';
      color = Colors.redAccent;
    } else if (nw && ne) {
      title = 'ATTACK';
      detail = 'Both VL53 sensors see the opponent.';
      color = Colors.redAccent;
    } else if (nw) {
      title = 'ALIGNING';
      detail = 'Left opponent sensor only.';
      color = Colors.lightBlueAccent;
    } else if (ne) {
      title = 'ALIGNING';
      detail = 'Right opponent sensor only.';
      color = Colors.lightBlueAccent;
    } else {
      title = 'SEARCHING';
      detail = 'No opponent detected within $_enemyDistanceMm mm.';
      color = Colors.amberAccent;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _logicRow(String condition, String action) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 88,
            child: Text(
              condition,
              style: const TextStyle(
                color: Colors.lightBlueAccent,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: Text(
              action,
              style: const TextStyle(color: Colors.white60, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _endpointRow(String endpoint, String description) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 122,
            child: Text(
              endpoint,
              style: const TextStyle(
                color: Colors.lightBlueAccent,
                fontWeight: FontWeight.bold,
                fontSize: 10.5,
              ),
            ),
          ),
          Expanded(
            child: Text(
              description,
              style: const TextStyle(color: Colors.white54, fontSize: 10.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(IconData icon, String title, String subtitle) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0xFF1565C0).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, color: const Color(0xFF42A5F5), size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Color _stateColor() {
    if (robotState == 'EDGE_ESCAPE' ||
        robotState == 'ESCAPING' ||
        robotState == 'EDGE ESCAPE') {
      return Colors.purpleAccent;
    }
    if (robotState == 'ATTACKING') return Colors.redAccent;
    if (robotState == 'ALIGNING') return Colors.lightBlueAccent;
    if (robotState == 'SEARCHING') return Colors.amberAccent;
    return Colors.white54;
  }

  String _timeText(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF14171C),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.055)),
      ),
      child: child,
    );
  }
}
