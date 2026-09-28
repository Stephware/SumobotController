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
          seedColor: const Color(0xFF1E88E5),
          brightness: Brightness.dark,
        ),
      ),
      home: const SumobotControllerPage(),
    );
  }
}

enum ControlMode {
  manual,
  automatic,
}

enum DriveDirection {
  stopped,
  forward,
  reverse,
}

enum SteeringDirection {
  center,
  left,
  right,
}

class SumobotControllerPage extends StatefulWidget {
  const SumobotControllerPage({super.key});

  @override
  State<SumobotControllerPage> createState() =>
      _SumobotControllerPageState();
}

class _SumobotControllerPageState extends State<SumobotControllerPage> {
  ControlMode mode = ControlMode.manual;

  DriveDirection driveDirection = DriveDirection.stopped;
  SteeringDirection steeringDirection = SteeringDirection.center;

  double driveSpeed = 80;

  bool isConnected = true;
  bool autoRunning = false;

  double attackDistance = 400;
  double searchSpeed = 55;
  double attackSpeed = 90;
  double escapeSpeed = 75;

  // Temporary / dummy sensor values.
  int frontLeftValue = 735;
  int frontRightValue = 720;
  int rearLeftValue = 710;
  int rearRightValue = 745;

  bool frontLeftEdge = false;
  bool frontRightEdge = false;
  bool rearLeftEdge = false;
  bool rearRightEdge = false;

  int opponentDistance = 327;

  String get robotState {
    if (!isConnected) {
      return 'DISCONNECTED';
    }

    if (mode == ControlMode.manual) {
      if (driveDirection == DriveDirection.stopped &&
          steeringDirection == SteeringDirection.center) {
        return 'IDLE';
      }

      return 'MANUAL';
    }

    if (!autoRunning) {
      return 'AUTO READY';
    }

    if (frontLeftEdge ||
        frontRightEdge ||
        rearLeftEdge ||
        rearRightEdge) {
      return 'EDGE ESCAPE';
    }

    if (opponentDistance <= attackDistance) {
      return 'ATTACKING';
    }

    return 'SEARCHING';
  }

  void emergencyStop() {
    setState(() {
      driveDirection = DriveDirection.stopped;
      steeringDirection = SteeringDirection.center;
      autoRunning = false;
    });
  }

  void setDrive(DriveDirection direction) {
    if (mode != ControlMode.manual) return;

    setState(() {
      driveDirection = direction;
    });
  }

  void releaseDrive() {
    if (mode != ControlMode.manual) return;

    setState(() {
      driveDirection = DriveDirection.stopped;
    });
  }

  void setSteering(SteeringDirection direction) {
    if (mode != ControlMode.manual) return;

    setState(() {
      steeringDirection = direction;
    });
  }

  void releaseSteering() {
    if (mode != ControlMode.manual) return;

    setState(() {
      // Steering motor receives no power.
      // The RC steering mechanism automatically centers itself.
      steeringDirection = SteeringDirection.center;
    });
  }

  void changeMode(ControlMode newMode) {
    emergencyStop();

    setState(() {
      mode = newMode;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      safeArea: true,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildModeSelector(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                child: Column(
                  children: [
                    if (mode == ControlMode.manual)
                      _buildManualController()
                    else
                      _buildAutomaticController(),

                    const SizedBox(height: 16),

                    _buildSensorMonitor(),

                    const SizedBox(height: 16),

                    _buildRobotStatus(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      child: Row(
        children: [
          Container(
            height: 48,
            width: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF1E88E5).withOpacity(0.15),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.smart_toy_rounded,
              color: Color(0xFF42A5F5),
              size: 29,
            ),
          ),

          const SizedBox(width: 14),

          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SUMOBOT',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'ESP32 Robot Controller',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),

          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 11,
              vertical: 7,
            ),
            decoration: BoxDecoration(
              color: isConnected
                  ? Colors.green.withOpacity(0.13)
                  : Colors.red.withOpacity(0.13),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color:
                    isConnected ? Colors.greenAccent : Colors.redAccent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  isConnected ? 'Connected' : 'Offline',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color:
                    isConnected ? Colors.greenAccent : Colors.redAccent,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: const Color(0xFF15181D),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Row(
          children: [
            Expanded(
              child: _modeButton(
                title: 'MANUAL',
                icon: Icons.gamepad_rounded,
                selected: mode == ControlMode.manual,
                onTap: () => changeMode(ControlMode.manual),
              ),
            ),
            Expanded(
              child: _modeButton(
                title: 'AUTOMATIC',
                icon: Icons.auto_mode_rounded,
                selected: mode == ControlMode.automatic,
                onTap: () => changeMode(ControlMode.automatic),
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
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 19,
                color: selected ? Colors.white : Colors.white54,
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: selected ? Colors.white : Colors.white54,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildManualController() {
    return _card(
      child: Column(
        children: [
          _sectionHeader(
            icon: Icons.gamepad_rounded,
            title: 'Manual Control',
            subtitle: 'Hold buttons to control the robot',
          ),

          const SizedBox(height: 26),

          _holdButton(
            icon: Icons.keyboard_arrow_up_rounded,
            label: 'FORWARD',
            active: driveDirection == DriveDirection.forward,
            onPressed: () => setDrive(DriveDirection.forward),
            onReleased: releaseDrive,
            width: 145,
          ),

          const SizedBox(height: 16),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _holdButton(
                icon: Icons.keyboard_arrow_left_rounded,
                label: 'LEFT',
                active: steeringDirection == SteeringDirection.left,
                onPressed: () =>
                    setSteering(SteeringDirection.left),
                onReleased: releaseSteering,
                width: 125,
              ),

              const SizedBox(width: 18),

              _holdButton(
                icon: Icons.keyboard_arrow_right_rounded,
                label: 'RIGHT',
                active: steeringDirection == SteeringDirection.right,
                onPressed: () =>
                    setSteering(SteeringDirection.right),
                onReleased: releaseSteering,
                width: 125,
              ),
            ],
          ),

          const SizedBox(height: 16),

          _holdButton(
            icon: Icons.keyboard_arrow_down_rounded,
            label: 'REVERSE',
            active: driveDirection == DriveDirection.reverse,
            onPressed: () => setDrive(DriveDirection.reverse),
            onReleased: releaseDrive,
            width: 145,
          ),

          const SizedBox(height: 28),

          SizedBox(
            width: double.infinity,
            height: 53,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFD32F2F),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: emergencyStop,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text(
                'STOP',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),

          const SizedBox(height: 28),

          _sliderHeader(
            title: 'Drive Speed',
            value: '${driveSpeed.round()}%',
          ),

          Slider(
            value: driveSpeed,
            min: 0,
            max: 100,
            divisions: 20,
            label: '${driveSpeed.round()}%',
            onChanged: (value) {
              setState(() {
                driveSpeed = value;
              });
            },
          ),

          const SizedBox(height: 8),

          _manualCommandIndicator(),
        ],
      ),
    );
  }

  Widget _manualCommandIndicator() {
    String driveText;

    switch (driveDirection) {
      case DriveDirection.forward:
        driveText = 'FORWARD';
        break;
      case DriveDirection.reverse:
        driveText = 'REVERSE';
        break;
      case DriveDirection.stopped:
        driveText = 'STOPPED';
        break;
    }

    String steeringText;

    switch (steeringDirection) {
      case SteeringDirection.left:
        steeringText = 'LEFT';
        break;
      case SteeringDirection.right:
        steeringText = 'RIGHT';
        break;
      case SteeringDirection.center:
        steeringText = 'CENTER';
        break;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF101318),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.memory_rounded,
            color: Colors.white38,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Drive: $driveText   •   Steering: $steeringText',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAutomaticController() {
    return _card(
      child: Column(
        children: [
          _sectionHeader(
            icon: Icons.auto_mode_rounded,
            title: 'Automatic Mode',
            subtitle: 'ESP32 autonomous Sumobot control',
          ),

          const SizedBox(height: 22),

          _autoStatusPanel(),

          const SizedBox(height: 25),

          _sliderHeader(
            title: 'Attack Distance',
            value: '${attackDistance.round()} mm',
          ),

          Slider(
            value: attackDistance,
            min: 100,
            max: 1000,
            divisions: 18,
            label: '${attackDistance.round()} mm',
            onChanged: autoRunning
                ? null
                : (value) {
              setState(() {
                attackDistance = value;
              });
            },
          ),

          const SizedBox(height: 8),

          _sliderHeader(
            title: 'Search Speed',
            value: '${searchSpeed.round()}%',
          ),

          Slider(
            value: searchSpeed,
            min: 20,
            max: 100,
            divisions: 16,
            onChanged: autoRunning
                ? null
                : (value) {
              setState(() {
                searchSpeed = value;
              });
            },
          ),

          const SizedBox(height: 8),

          _sliderHeader(
            title: 'Attack Speed',
            value: '${attackSpeed.round()}%',
          ),

          Slider(
            value: attackSpeed,
            min: 20,
            max: 100,
            divisions: 16,
            onChanged: autoRunning
                ? null
                : (value) {
              setState(() {
                attackSpeed = value;
              });
            },
          ),

          const SizedBox(height: 8),

          _sliderHeader(
            title: 'Edge Escape Speed',
            value: '${escapeSpeed.round()}%',
          ),

          Slider(
            value: escapeSpeed,
            min: 20,
            max: 100,
            divisions: 16,
            onChanged: autoRunning
                ? null
                : (value) {
              setState(() {
                escapeSpeed = value;
              });
            },
          ),

          const SizedBox(height: 24),

          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: autoRunning
                    ? const Color(0xFFD32F2F)
                    : const Color(0xFF1565C0),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () {
                setState(() {
                  autoRunning = !autoRunning;

                  if (!autoRunning) {
                    driveDirection = DriveDirection.stopped;
                    steeringDirection = SteeringDirection.center;
                  }
                });
              },
              icon: Icon(
                autoRunning
                    ? Icons.stop_rounded
                    : Icons.play_arrow_rounded,
              ),
              label: Text(
                autoRunning
                    ? 'STOP AUTONOMOUS'
                    : 'START AUTONOMOUS',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          SizedBox(
            width: double.infinity,
            height: 51,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.redAccent,
                side: const BorderSide(
                  color: Colors.redAccent,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: emergencyStop,
              icon: const Icon(Icons.warning_amber_rounded),
              label: const Text(
                'EMERGENCY STOP',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _autoStatusPanel() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF101318),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: autoRunning
              ? const Color(0xFF1565C0).withOpacity(0.65)
              : Colors.white10,
        ),
      ),
      child: Column(
        children: [
          const Text(
            'CURRENT STATE',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            robotState,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _stateColor(),
              fontSize: 21,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            autoRunning
                ? 'Autonomous control is active'
                : 'Robot is waiting to start',
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSensorMonitor() {
    return _card(
      child: Column(
        children: [
          _sectionHeader(
            icon: Icons.sensors_rounded,
            title: 'Live Sensors',
            subtitle: 'Temporary simulated sensor readings',
          ),

          const SizedBox(height: 20),

          Row(
            children: [
              Expanded(
                child: _sensorTile(
                  label: 'Front Left',
                  shortLabel: 'FL',
                  value: frontLeftValue,
                  edgeDetected: frontLeftEdge,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _sensorTile(
                  label: 'Front Right',
                  shortLabel: 'FR',
                  value: frontRightValue,
                  edgeDetected: frontRightEdge,
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          Row(
            children: [
              Expanded(
                child: _sensorTile(
                  label: 'Rear Left',
                  shortLabel: 'RL',
                  value: rearLeftValue,
                  edgeDetected: rearLeftEdge,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _sensorTile(
                  label: 'Rear Right',
                  shortLabel: 'RR',
                  value: rearRightValue,
                  edgeDetected: rearRightEdge,
                ),
              ),
            ],
          ),

          const SizedBox(height: 18),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(17),
            decoration: BoxDecoration(
              color: const Color(0xFF101318),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Container(
                  height: 45,
                  width: 45,
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.radar_rounded,
                    color: Colors.lightBlueAccent,
                  ),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'VL53L0X',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Opponent Distance',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '$opponentDistance mm',
                  style: const TextStyle(
                    color: Colors.lightBlueAccent,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sensorTile({
    required String label,
    required String shortLabel,
    required int value,
    required bool edgeDetected,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF101318),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: edgeDetected
              ? Colors.redAccent.withOpacity(0.7)
              : Colors.greenAccent.withOpacity(0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                height: 30,
                width: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: edgeDetected
                      ? Colors.red.withOpacity(0.15)
                      : Colors.green.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  shortLabel,
                  style: TextStyle(
                    color: edgeDetected
                        ? Colors.redAccent
                        : Colors.greenAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                edgeDetected ? 'EDGE' : 'SAFE',
                style: TextStyle(
                  color: edgeDetected
                      ? Colors.redAccent
                      : Colors.greenAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 13),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '$value',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 19,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRobotStatus() {
    return _card(
      child: Column(
        children: [
          _sectionHeader(
            icon: Icons.info_outline_rounded,
            title: 'Robot Status',
            subtitle: 'Current control output',
          ),

          const SizedBox(height: 18),

          _statusRow(
            'Mode',
            mode == ControlMode.manual ? 'MANUAL' : 'AUTOMATIC',
          ),

          _statusRow(
            'Robot State',
            robotState,
            valueColor: _stateColor(),
          ),

          _statusRow(
            'Drive',
            driveDirection.name.toUpperCase(),
          ),

          _statusRow(
            'Steering',
            steeringDirection.name.toUpperCase(),
          ),

          _statusRow(
            'Drive Speed',
            '${driveSpeed.round()}%',
          ),
        ],
      ),
    );
  }

  Color _stateColor() {
    switch (robotState) {
      case 'ATTACKING':
        return Colors.redAccent;
      case 'EDGE ESCAPE':
        return Colors.orangeAccent;
      case 'SEARCHING':
        return Colors.lightBlueAccent;
      case 'MANUAL':
        return Colors.greenAccent;
      case 'AUTO READY':
        return Colors.amberAccent;
      case 'DISCONNECTED':
        return Colors.redAccent;
      default:
        return Colors.white70;
    }
  }

  Widget _statusRow(
      String label,
      String value, {
        Color valueColor = Colors.white,
      }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 13,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _holdButton({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onPressed,
    required VoidCallback onReleased,
    required double width,
  }) {
    return GestureDetector(
      onTapDown: (_) => onPressed(),
      onTapUp: (_) => onReleased(),
      onTapCancel: onReleased,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        width: width,
        height: 67,
        decoration: BoxDecoration(
          color: active
              ? const Color(0xFF1976D2)
              : const Color(0xFF171B20),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active
                ? const Color(0xFF42A5F5)
                : Colors.white12,
          ),
          boxShadow: active
              ? [
            BoxShadow(
              color: const Color(0xFF1976D2).withOpacity(0.25),
              blurRadius: 15,
              spreadRadius: 1,
            ),
          ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 27,
              color: active ? Colors.white : Colors.white70,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                letterSpacing: 0.4,
                color: active ? Colors.white : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sliderHeader({
    required String title,
    required String value,
  }) {
    return Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(
            color: Colors.lightBlueAccent,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ],
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
            color: const Color(0xFF1565C0).withOpacity(0.15),
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

  Widget _card({
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF14171C),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withOpacity(0.055),
        ),
      ),
      child: child,
    );
  }
}