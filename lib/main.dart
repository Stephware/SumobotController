import 'dart:async';
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

  static const double _joystickSize = 220;
  static const double _joystickKnobSize = 72;
  static const double _joystickDeadZone = 24;

  ControlMode mode = ControlMode.manual;
  DriveDirection driveDirection = DriveDirection.stopped;
  SteeringDirection steeringDirection = SteeringDirection.center;

  bool isConnected = false;
  bool isCheckingConnection = false;
  String connectionMessage =
      'Connect to ESP32-ROBOT, then test the connection.';
  String lastCommand = 'NONE';

  Offset _joystickOffset = Offset.zero;
  Future<void> _commandTail = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _testConnection(showFeedback: false);
    });
  }

  Future<bool> _request(
    String path, {
    bool updateCommand = false,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2);

    try {
      final request = await client.getUrl(Uri.parse('$_baseUrl$path'));
      request.persistentConnection = false;

      final response = await request.close().timeout(
            const Duration(seconds: 2),
          );
      await response.drain();

      final success = response.statusCode == HttpStatus.ok;

      if (!mounted) return success;

      setState(() {
        isConnected = success;
        connectionMessage = success
            ? 'Connected to ESP32 at 192.168.4.1'
            : 'ESP32 responded with HTTP ${response.statusCode}.';

        if (success && updateCommand) {
          lastCommand = path;
        }
      });

      return success;
    } catch (_) {
      if (mounted) {
        setState(() {
          isConnected = false;
          connectionMessage =
              'No response. Make sure the phone is connected to $_ssid.';
        });
      }
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _queueCommand(String path) {
    final completer = Completer<bool>();

    _commandTail = _commandTail.then((_) async {
      final success = await _request(path, updateCommand: true);
      if (!completer.isCompleted) {
        completer.complete(success);
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

    final success = await _request('/');

    if (!mounted) return;

    setState(() {
      isCheckingConnection = false;
    });

    if (showFeedback) {
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
    }
  }

  void _changeMode(ControlMode newMode) {
    unawaited(_stopAll());
    setState(() {
      mode = newMode;
    });
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
    final driveWasReleased = oldDrive != DriveDirection.stopped &&
        newDrive == DriveDirection.stopped;
    final steeringWasReleased = oldSteering != SteeringDirection.center &&
        newSteering == SteeringDirection.center;

    // Current ESP32 firmware only has /s, so if either joystick axis returns
    // to neutral we stop both motors, then restore the other active axis.
    if (driveWasReleased || steeringWasReleased) {
      final stopped = await _queueCommand('/s');
      if (!stopped || !mounted) return;

      if (newDrive == DriveDirection.forward) {
        await _queueCommand('/f');
      } else if (newDrive == DriveDirection.reverse) {
        await _queueCommand('/b');
      }

      if (newSteering == SteeringDirection.left) {
        await _queueCommand('/l');
      } else if (newSteering == SteeringDirection.right) {
        await _queueCommand('/r');
      }
      return;
    }

    if (newDrive != oldDrive) {
      if (newDrive == DriveDirection.forward) {
        await _queueCommand('/f');
      } else if (newDrive == DriveDirection.reverse) {
        await _queueCommand('/b');
      }
    }

    if (newSteering != oldSteering) {
      if (newSteering == SteeringDirection.left) {
        await _queueCommand('/l');
      } else if (newSteering == SteeringDirection.right) {
        await _queueCommand('/r');
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
                  : _buildScrollableAutomaticScreen(),
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
                onTap: () => _changeMode(ControlMode.manual),
              ),
            ),
            Expanded(
              child: _modeButton(
                title: 'AUTOMATIC',
                icon: Icons.auto_mode_rounded,
                selected: mode == ControlMode.automatic,
                onTap: () => _changeMode(ControlMode.automatic),
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

  // Manual mode deliberately contains no ScrollView so dragging the joystick
  // cannot move the page while the robot is being controlled.
  Widget _buildFixedManualScreen() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Column(
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
                            ? 'Drag and hold to control the Sumobot'
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
                  onPressed:
                      isConnected ? () => unawaited(_stopAll()) : null,
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
          );
        },
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

  Widget _buildScrollableAutomaticScreen() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      child: Column(
        children: [
          _buildConnectionCard(),
          const SizedBox(height: 16),
          _buildAutomaticPlaceholder(),
          const SizedBox(height: 16),
          _buildFirmwareStatus(),
        ],
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
            subtitle: 'Connect the phone to the ESP32 access point first',
          ),
          const SizedBox(height: 18),
          _infoRow('Wi-Fi', _ssid),
          _infoRow('Password', _password),
          _infoRow('ESP32 IP', '192.168.4.1'),
          const SizedBox(height: 12),
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
          const SizedBox(height: 14),
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

  Widget _buildAutomaticPlaceholder() {
    return _card(
      child: Column(
        children: [
          _sectionHeader(
            icon: Icons.auto_mode_rounded,
            title: 'Automatic Mode',
            subtitle: 'Reserved for the autonomous Sumobot firmware',
          ),
          const SizedBox(height: 22),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.amber.withValues(alpha: 0.25),
              ),
            ),
            child: const Column(
              children: [
                Icon(
                  Icons.construction_rounded,
                  color: Colors.amberAccent,
                  size: 34,
                ),
                SizedBox(height: 12),
                Text(
                  'NOT YET SUPPORTED BY THE CURRENT ESP32 CODE',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.amberAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Automatic mode will be enabled when the TCRT5000L and VL53L0X logic is added to the ESP32 firmware.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white60,
                    height: 1.45,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFirmwareStatus() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            icon: Icons.route_rounded,
            title: 'Current ESP32 Endpoints',
            subtitle: 'Matches the Arduino WebServer code',
          ),
          const SizedBox(height: 18),
          _endpointRow('GET /', 'Connection test / ESP32 web page'),
          _endpointRow('GET /f', 'Rear drive forward'),
          _endpointRow('GET /b', 'Rear drive reverse'),
          _endpointRow('GET /l', 'Steering left'),
          _endpointRow('GET /r', 'Steering right'),
          _endpointRow('GET /s', 'Stop both motors'),
          const Divider(height: 28),
          const Text(
            'Current firmware limitation',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.orangeAccent,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'There is no separate drive-stop or steering-stop endpoint yet. When one joystick axis returns to center, Flutter uses /s and then restores the other active motor.',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
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
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              endpoint,
              style: const TextStyle(
                color: Colors.lightBlueAccent,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              description,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 12,
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
