import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/widgets/native_activity_scope.dart';

class StartupGate extends StatefulWidget {
  const StartupGate({
    super.key,
    required this.initialization,
    required this.child,
  });

  final Future<void> initialization;
  final Widget child;

  @override
  State<StartupGate> createState() => StartupGateState();
}

class StartupGateState extends State<StartupGate> with WidgetsBindingObserver {
  static const _visibilityChannel = MethodChannel(
    'shadow_network/app_visibility',
  );
  bool _initialized = false;
  bool _showSplash = true;
  bool _activityVisible = false;
  Future<void>? _imageReady;
  int _visibilityRevision = 0;
  int _activityGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _activityVisible =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _visibilityChannel.setMethodCallHandler((call) async {
      if (!mounted) return;
      switch (call.method) {
        case 'opened':
          // Android reports creation before the new activity resumes.
          _activityVisible = false;
          _visibilityRevision++;
          setState(() {
            _activityGeneration++;
            _showSplash = true;
          });
        case 'reattached':
          setState(() => _activityGeneration++);
        case 'visible':
          _activityVisible = true;
          _scheduleDismissal();
      }
    });
    widget.initialization.whenComplete(() {
      if (!mounted) return;
      setState(() => _initialized = true);
      _scheduleDismissal();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _imageReady ??= precacheImage(
      const AssetImage('assets/home/startup_splash.png'),
      context,
    );
    _scheduleDismissal();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _activityVisible = state == AppLifecycleState.resumed;
    _visibilityRevision++;
    if (_activityVisible) {
      _scheduleDismissal();
    }
  }

  Future<void> _scheduleDismissal() async {
    if (!_showSplash ||
        !_initialized ||
        !_activityVisible ||
        _imageReady == null) {
      return;
    }
    final revision = ++_visibilityRevision;
    await _imageReady;
    if (!mounted || revision != _visibilityRevision) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _visibilityRevision || !_activityVisible) {
        return;
      }
      // Paint the splash in this frame and expose the child in the next one.
      setState(() => _showSplash = false);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _visibilityRevision++;
    _visibilityChannel.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (_initialized)
        NativeActivityScope(
          generation: _activityGeneration,
          child: widget.child,
        ),
      if (_showSplash) const Positioned.fill(child: StartupSplashPage()),
    ],
  );
}

class StartupSplashPage extends StatelessWidget {
  const StartupSplashPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFD9DCE3),
    body: SizedBox.expand(
      child: Image.asset(
        'assets/home/startup_splash.png',
        fit: MediaQuery.orientationOf(context) == Orientation.portrait
            ? BoxFit.cover
            : BoxFit.contain,
        alignment: Alignment.center,
        semanticLabel: 'Starting ShadowNetwork',
      ),
    ),
  );
}
