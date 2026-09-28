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
  static const String _password = '12345678';
  static const String _baseUrl = 'http://192.168.4.1';

  static const int _opponentDetectionDistanceMm = 700;
  static const int _edgeThreshold = 1800;
  static const bool _edgeIsHigh = true;

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

  int tofLeft = 8190;
  int tofCenter = 8190;
  int tofRight = 8190;

  int edgeFrontLeft = 0;
  int edgeFrontRight = 0;
  int edgeRearLeft = 0;
  int edgeRearRight = 0;

  DateTime? lastStatusUpdate;

  Offset _joystickOffset = Offset.zero;
  Future<void> _commandTail = Future<void>.value();
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();

    _statusTimer = Timer.periodic(
      const Duration(milliseconds: 900),
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
      final edge = decoded['edge'];

      setState(() {
        espMode = decoded['mode']?.toString() ?? espMode;
        robotState = decoded['state']?.toString() ?? robotState;

        if (tof is Map<String, dynamic>) {
          tofLeft = _asInt(tof['left'], tofLeft);
          tofCenter = _asInt(tof['center'], tofCenter);
          tofRight = _asInt(tof['right'], tofRight);
        }

        if (edge is Map<String, dynamic>) {
          edgeFrontLeft = _asInt(edge['frontLeft'], edgeFrontLeft);
          edgeFrontRight = _asInt(edge['frontRight'], edgeFrontRight);
          edgeRearLeft = _asInt(edge['rearLeft'], edgeRearLeft);
          edgeRearRight = _asInt(edge['rearRight'], edgeRearRight);
        }

        lastStatusUpdate = DateTime.now();
      });
    } catch (_) {
      // Keep the last valid sensor values if a status response is incomplete.
    } finally {
      _statusRequestInFlight = false;
    }
  }

  int _asInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  bool _targetDetected(int distance) {
    return distance > 0 && distance <= _opponentDetectionDistanceMm;
  }

  bool _edgeDetected(int value) {
    return _edgeIsHigh
        ? value >= _edgeThreshold
        : value <= _edgeThreshold;
  }

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

  // Your chassis is physically reversed, so the single-axis commands remain
  // inverted relative to the labels shown to the user.
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

  // Combined Arduino endpoints:
  // /fl = Arduino forward + left
  // /fr = Arduino forward + right
  // /rl = Arduino reverse + left
  // /rr = Arduino reverse + right
  //
  // Since BOTH axes are inverted for this chassis, the joystick mapping is:
  // UI forward-left  -> Arduino reverse-right -> /rr
  // UI forward-right -> Arduino reverse-left  -> /rl
  // UI reverse-left  -> Arduino forward-right -> /fr
  // UI reverse-right -> Arduino forward-left  -> /fl
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
    // If both joystick axes are active, send ONE combined endpoint instead of
    // separate drive + steering requests. This prevents the two commands from
    // fighting each other or arriving out of order.
    final diagonalEndpoint = _diagonalEndpoint(newDrive, newSteering);
    if (diagonalEndpoint != null) {
      await _queueCommand(diagonalEndpoint);
      return;
    }

    final oldWasDiagonal = oldDrive != DriveDirection.stopped &&
        oldSteering != SteeringDirection.center;

    final driveWasReleased = oldDrive != DriveDirection.stopped &&
        newDrive == DriveDirection.stopped;
    final steeringWasReleased = oldSteering != SteeringDirection.center &&
        newSteering == SteeringDirection.center;

    // When leaving a diagonal state, or when one axis returns to neutral,
    // clear both motors first. Then restore only the axis still requested.
    if (oldWasDiagonal || driveWasReleased || steeringWasReleased) {
      final stopped = await _queueCommand('/s');
      if (!stopped || !mounted) return;

      final driveEndpoint = _driveEndpoint(newDrive);
      if (driveEndpoint != null) {
        await _queueCommand(driveEndpoint);
      }

      final steeringEndpoint = _steeringEndpoint(newSteering);
      if (steeringEndpoint != null) {
        await _queueCommand(steeringEndpoint);
      }
      return;
    }

    if (newDrive != oldDrive) {
      final endpoint = _driveEndpoint(newDrive);
      if (endpoint != null) {
        await _queueCommand(endpoint);
      }
    }

    if (newSteering != oldSteering) {
      final endpoint = _steeringEndpoint(newSteering);
      if (endpoint != null) {
        await _queueCommand(endpoint);
      }
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
                  ? _buildFixedManualScreen()
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
                  'ESP32 Robot Controller',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                  ),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: (isConnected ? Colors.green : Colors.red)
            .withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: isConnected ? Colors.greenAccent : Colors.redAccent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            isConnected ? 'Connected' : 'Offline',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isConnected ? Colors.greenAccent : Colors.redAccent,
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
                title: 'MANUAL',
                icon: Icons.gamepad_rounded,
                selected: mode == ControlMode.manual,
                onTap: () => unawaited(_changeMode(ControlMode.manual)),
              ),
            ),
            Expanded(
              child: _modeButton(
                title: 'AUTOMATIC',
                icon: Icons.auto_mode_rounded,
                selected: mode == ControlMode.automatic,
                onTap: () => unawaited(_changeMode(ControlMode.automatic)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeButton({
    required String title,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
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
              Icon(
                icon,
                size: 18,
                color: selected ? Colors.white : Colors.white54,
              ),
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

  Widget _buildFixedManualScreen() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Column(
        children: [
          _buildCompactConnectionBar(),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF14171C),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.055),
                ),
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
                  Text(
                    isConnected
                        ? 'Diagonal movement now uses FL / FR / RL / RR routes'
                        : 'Connect to ESP32-ROBOT to enable control',
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 10.5,
                    ),
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
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: isConnected ? () => unawaited(_stopAll()) : null,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text(
                'STOP ALL',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactConnectionBar() {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF14171C),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.055),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.wifi_rounded,
            size: 19,
            color: isConnected ? Colors.greenAccent : Colors.white38,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'ESP32-ROBOT • 192.168.4.1',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  isConnected ? 'Ready for commands' : 'Not connected',
                  style: TextStyle(
                    fontSize: 10,
                    color: isConnected ? Colors.greenAccent : Colors.white38,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Test connection',
            onPressed: isCheckingConnection
                ? null
                : () => _testConnection(showFeedback: true),
            icon: isCheckingConnection
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded, size: 22),
          ),
        ],
      ),
    );
  }

  Widget _buildMovementStatus() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                    style: TextStyle(
                      color: isConnected
                          ? Colors.lightBlueAccent
                          : Colors.white38,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.7,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Drive: $driveText • Steering: $steeringText',
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              lastCommand,
              style: const TextStyle(
                color: Colors.white30,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
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
                width: _joystickSize,
                height: _joystickSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF101318),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 18,
                      spreadRadius: 3,
                    ),
                  ],
                ),
              ),
              const Positioned(
                top: 14,
                child: Icon(
                  Icons.keyboard_arrow_up_rounded,
                  color: Colors.white30,
                  size: 32,
                ),
              ),
              const Positioned(
                bottom: 14,
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: Colors.white30,
                  size: 32,
                ),
              ),
              const Positioned(
                left: 14,
                child: Icon(
                  Icons.keyboard_arrow_left_rounded,
                  color: Colors.white30,
                  size: 32,
                ),
              ),
              const Positioned(
                right: 14,
                child: Icon(
                  Icons.keyboard_arrow_right_rounded,
                  color: Colors.white30,
                  size: 32,
                ),
              ),
              Container(
                width: 74,
                height: 74,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.05),
                  ),
                ),
              ),
              Transform.translate(
                offset: _joystickOffset,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 45),
                  width: _joystickKnobSize,
                  height: _joystickKnobSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF42A5F5), Color(0xFF1565C0)],
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.18),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF1976D2)
                            .withValues(alpha: 0.35),
                        blurRadius: 18,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.control_camera_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAutomaticScreen() {
    return RefreshIndicator(
      onRefresh: _fetchStatus,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        child: Column(
          children: [
            _buildConnectionCard(),
            const SizedBox(height: 14),
            _buildAutoControlCard(),
            const SizedBox(height: 14),
            _buildOpponentSensorsCard(),
            const SizedBox(height: 14),
            _buildEdgeSensorsCard(),
            const SizedBox(height: 14),
            _buildAutoLogicCard(),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            icon: Icons.wifi_rounded,
            title: 'ESP32 Connection',
            subtitle: 'Live data comes from /status',
          ),
          const SizedBox(height: 16),
          _infoRow('Wi-Fi', _ssid),
          _infoRow('Password', _password),
          _infoRow('ESP32 IP', '192.168.4.1'),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF101318),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              connectionMessage,
              style: TextStyle(
                color: isConnected ? Colors.greenAccent : Colors.white60,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: isCheckingConnection
                  ? null
                  : () => _testConnection(showFeedback: true),
              icon: isCheckingConnection
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded),
              label: Text(
                isCheckingConnection ? 'CHECKING...' : 'TEST CONNECTION',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAutoControlCard() {
    final autoRunning = espMode == 'AUTO';

    return _card(
      child: Column(
        children: [
          _sectionHeader(
            icon: Icons.auto_mode_rounded,
            title: 'Automatic Mode',
            subtitle: 'Acquire → align → center → attack',
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF101318),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _stateColor().withValues(alpha: 0.35),
              ),
            ),
            child: Column(
              children: [
                const Text(
                  'ROBOT STATE',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.3,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  robotState.replaceAll('_', ' '),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _stateColor(),
                    fontWeight: FontWeight.bold,
                    fontSize: 21,
                    letterSpacing: 0.7,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  'ESP32 mode: $espMode',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: autoRunning
                    ? const Color(0xFFD32F2F)
                    : const Color(0xFF1565C0),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: !isConnected
                  ? null
                  : autoRunning
                      ? () => unawaited(_stopAuto())
                      : () => unawaited(_startAuto()),
              icon: Icon(
                autoRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
              ),
              label: Text(
                autoRunning ? 'STOP AUTONOMOUS' : 'START AUTONOMOUS',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            lastStatusUpdate == null
                ? 'Waiting for sensor status...'
                : 'Live status updated ${_timeText(lastStatusUpdate!)}',
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOpponentSensorsCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            icon: Icons.radar_rounded,
            title: 'Opponent Tracking',
            subtitle: '3× VL53L0X on the spare-tire attack side',
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _tofTile(
                  label: 'LEFT',
                  value: tofLeft,
                  emphasized: robotState == 'ALIGN_LEFT',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _tofTile(
                  label: 'CENTER',
                  value: tofCenter,
                  emphasized: robotState == 'ATTACKING',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _tofTile(
                  label: 'RIGHT',
                  value: tofRight,
                  emphasized: robotState == 'ALIGN_RIGHT',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF101318),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              'Center sensor has priority: once CENTER detects the opponent, the robot straightens and attacks. LEFT/RIGHT align the chassis first.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tofTile({
    required String label,
    required int value,
    required bool emphasized,
  }) {
    final detected = _targetDetected(value);
    final display = value >= 8000 ? '--' : '$value';

    final color = emphasized
        ? Colors.orangeAccent
        : detected
            ? Colors.greenAccent
            : Colors.white38;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: emphasized ? 0.13 : 0.07),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: color.withValues(alpha: emphasized ? 0.65 : 0.22),
        ),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 10,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            display,
            style: TextStyle(
              color: detected ? Colors.white : Colors.white54,
              fontWeight: FontWeight.bold,
              fontSize: 20,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value >= 8000 ? 'OUT' : 'mm',
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 9,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            detected ? 'DETECTED' : 'CLEAR',
            style: TextStyle(
              color: detected ? Colors.greenAccent : Colors.white30,
              fontWeight: FontWeight.bold,
              fontSize: 9,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEdgeSensorsCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            icon: Icons.border_outer_rounded,
            title: 'Ring Edge Sensors',
            subtitle: '4× TCRT5000L relative to the NEW front',
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(child: _edgeTile('FRONT LEFT', edgeFrontLeft)),
              const SizedBox(width: 8),
              Expanded(child: _edgeTile('FRONT RIGHT', edgeFrontRight)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _edgeTile('REAR LEFT', edgeRearLeft)),
              const SizedBox(width: 8),
              Expanded(child: _edgeTile('REAR RIGHT', edgeRearRight)),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Current firmware threshold: $_edgeThreshold ADC • Edge priority overrides attack and alignment.',
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 10.5,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _edgeTile(String label, int value) {
    final edge = _edgeDetected(value);
    final color = edge ? Colors.redAccent : Colors.greenAccent;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withValues(alpha: edge ? 0.60 : 0.16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                edge ? 'EDGE' : 'SAFE',
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 9.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$value',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 19,
            ),
          ),
          const Text(
            'ADC',
            style: TextStyle(
              color: Colors.white30,
              fontSize: 9,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAutoLogicCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            icon: Icons.account_tree_rounded,
            title: 'Autonomous Priority',
            subtitle: 'Matches the ESP32 state logic',
          ),
          const SizedBox(height: 16),
          _logicRow('1', 'EDGE', 'Escape immediately', Colors.redAccent),
          _logicRow('2', 'CENTER', 'Attack straight', Colors.orangeAccent),
          _logicRow('3', 'LEFT', 'Align left', Colors.lightBlueAccent),
          _logicRow('4', 'RIGHT', 'Align right', Colors.lightBlueAccent),
          _logicRow('5', 'NONE', 'Search / sweep', Colors.white54),
          const Divider(height: 24),
          const Text(
            'Current HTTP routes',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          _endpointRow('/f  /b  /l  /r  /s', 'Single-axis manual control'),
          _endpointRow('/fl  /fr  /rl  /rr', 'Combined diagonal control'),
          _endpointRow('/auto/start', 'Start autonomous mode'),
          _endpointRow('/auto/stop', 'Stop autonomous mode'),
          _endpointRow('/status', 'Mode, state, ToF and edge readings'),
        ],
      ),
    );
  }

  Widget _logicRow(
    String number,
    String condition,
    String action,
    Color color,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 25,
            height: 25,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Text(
              number,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 60,
            child: Text(
              condition,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: Text(
              action,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _stateColor() {
    if (robotState == 'ATTACKING') return Colors.redAccent;
    if (robotState == 'EDGE_ESCAPE') return Colors.orangeAccent;
    if (robotState == 'ALIGN_LEFT' || robotState == 'ALIGN_RIGHT') {
      return Colors.lightBlueAccent;
    }
    if (robotState == 'SEARCHING') return Colors.amberAccent;
    return Colors.white54;
  }

  String _timeText(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  Widget _sectionHeader({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0xFF1565C0).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(
            icon,
            color: const Color(0xFF42A5F5),
            size: 22,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _endpointRow(String endpoint, String description) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 124,
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
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 10.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF14171C),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.055),
        ),
      ),
      child: child,
    );
  }
}
