import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/auth_error_mapper.dart';
import '../../data/repositories/firebase_auth_repository.dart';
import '../providers/auth_provider.dart';
import '../theme/auth_text_styles.dart';
import '../theme/auth_tokens.dart';
import '../widgets/auth_background.dart';
import '../widgets/auth_button.dart';
import '../widgets/auth_card.dart';
import '../widgets/auth_field.dart';
import '../widgets/auth_logo.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  late final TextEditingController _emailController;
  late final TextEditingController _passwordController;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController();
    _passwordController = TextEditingController();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signInWithEmail() async {
    if (_isSubmitting) {
      return;
    }

    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      _showMessage('Please enter email and password.');
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      await ref
          .read(authRepositoryProvider)
          .signInWithEmailPassword(email: email, password: password);

      if (!mounted) {
        return;
      }
      Navigator.of(context).pushReplacementNamed('/app');
    } on AuthFailure catch (error) {
      _showMessage(error.message);
    } catch (error) {
      _showMessage(mapAuthError(error));
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<void> _signInWithGoogle() async {
    if (_isSubmitting) {
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      await ref.read(authRepositoryProvider).signInWithGoogle();

      if (!mounted) {
        return;
      }
      Navigator.of(context).pushReplacementNamed('/app');
    } on AuthFailure catch (error) {
      _showMessage(error.message);
    } catch (error) {
      _showMessage(mapAuthError(error));
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final scaleX = constraints.maxWidth / AuthTokens.designWidth;
          final scaleY = constraints.maxHeight / AuthTokens.designHeight;
          final scale = scaleX;

          return AuthBackground(
            child: Stack(
              children: [
                Positioned(
                  left: 112 * scaleX,
                  top: 95 * scaleY,
                  width: AuthTokens.logoWidthLogin * scaleX,
                  height: AuthTokens.logoHeightLogin * scaleY,
                  child: const AuthLogo(
                    width: AuthTokens.logoWidthLogin,
                    height: AuthTokens.logoHeightLogin,
                  ),
                ),
                Positioned(
                  left: 24 * scaleX,
                  top: 220 * scaleY,
                  width: 327 * scaleX,
                  height: 398 * scaleY,
                  child: AuthCard(
                    height: 398 * scaleY,
                    child: Stack(
                      children: [
                        Positioned(
                          top: 28 * scaleY,
                          left: 0,
                          right: 0,
                          child: Text(
                            'Log in',
                            style: AuthTextStyles.loginTitle(scale),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        Positioned(
                          top: 58 * scaleY,
                          left: 0,
                          right: 0,
                          child: Text(
                            'Sign in with email and password',
                            style: AuthTextStyles.loginSubtitle(scale),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        AuthButton(
                          label: 'Continue with Google',
                          left: 20.53 * scaleX,
                          top: 93.41 * scaleY,
                          width: 286.476 * scaleX,
                          height: 48.192 * scaleY,
                          scale: scale,
                          color: AuthTokens.primary,
                          radius: AuthTokens.googleButtonRadius,
                          textStyle: AuthTextStyles.loginGoogleButton,
                          onPressed: _signInWithGoogle,
                        ),
                        AuthField(
                          hintText: 'Email address',
                          left: 20.53 * scaleX,
                          top: 176.4 * scaleY,
                          width: 286.476 * scaleX,
                          height: 41.945 * scaleY,
                          scale: scale,
                          controller: _emailController,
                        ),
                        AuthField(
                          hintText: 'Password',
                          left: 19.63 * scaleX,
                          top: 228.16 * scaleY,
                          width: 286.476 * scaleX,
                          height: 42.609 * scaleY,
                          scale: scale,
                          obscureText: true,
                          showEyeIcon: true,
                          controller: _passwordController,
                        ),
                        AuthButton(
                          label: 'Log in',
                          left: 21.42 * scaleX,
                          top: 285.28 * scaleY,
                          width: 283.799 * scaleX,
                          height: 37.483 * scaleY,
                          scale: scale,
                          color: AuthTokens.primaryDark,
                          radius: AuthTokens.buttonRadius,
                          textStyle: AuthTextStyles.loginButton,
                          onPressed: _signInWithEmail,
                        ),
                        Positioned(
                          left: 36 * scaleX,
                          top: 349 * scaleY,
                          width: 254 * scaleX,
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            children: [
                              Text(
                                'New to Shadow Network? ',
                                style: AuthTextStyles.loginCta(scale),
                              ),
                              GestureDetector(
                                onTap: () {
                                  Navigator.of(context).pushNamed('/signup');
                                },
                                child: Text(
                                  'Create an account',
                                  style: AuthTextStyles.loginCta(scale)
                                      .copyWith(
                                        color: AuthTokens.primaryDark,
                                        decoration: TextDecoration.underline,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
