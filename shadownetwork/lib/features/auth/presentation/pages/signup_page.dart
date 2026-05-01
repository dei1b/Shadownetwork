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

class SignUpPage extends ConsumerStatefulWidget {
  const SignUpPage({super.key});

  @override
  ConsumerState<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends ConsumerState<SignUpPage> {
  late final TextEditingController _fullNameController;
  late final TextEditingController _emailController;
  late final TextEditingController _passwordController;
  late final TextEditingController _confirmPasswordController;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _fullNameController = TextEditingController();
    _emailController = TextEditingController();
    _passwordController = TextEditingController();
    _confirmPasswordController = TextEditingController();
  }

  @override
  void dispose() {
    _fullNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _createAccountWithEmail() async {
    if (_isSubmitting) {
      return;
    }

    final fullName = _fullNameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (fullName.isEmpty ||
        email.isEmpty ||
        password.isEmpty ||
        confirmPassword.isEmpty) {
      _showMessage('Please complete all fields.');
      return;
    }

    if (password != confirmPassword) {
      _showMessage('Password and confirm password do not match.');
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      await ref
          .read(authRepositoryProvider)
          .createUserWithEmailPassword(
            fullName: fullName,
            email: email,
            password: password,
          );

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
                  left: 121 * scaleX,
                  top: 51 * scaleY,
                  width: AuthTokens.logoWidthSignup * scaleX,
                  height: AuthTokens.logoHeightSignup * scaleY,
                  child: const AuthLogo(
                    width: AuthTokens.logoWidthSignup,
                    height: AuthTokens.logoHeightSignup,
                  ),
                ),
                Positioned(
                  left: 19 * scaleX,
                  top: 155 * scaleY,
                  width: 327 * scaleX,
                  height: 523 * scaleY,
                  child: AuthCard(
                    height: 523 * scaleY,
                    child: Stack(
                      children: [
                        Positioned(
                          top: 30 * scaleY,
                          left: 0,
                          right: 0,
                          child: Text(
                            'Create account',
                            style: AuthTextStyles.signupTitle(scale),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        Positioned(
                          top: 66 * scaleY,
                          left: 0,
                          right: 0,
                          child: Text(
                            'Build Trust with verified details.',
                            style: AuthTextStyles.signupSubtitle(scale),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        AuthButton(
                          label: 'Sign up with Google',
                          left: 26 * scaleX,
                          top: 93.54 * scaleY,
                          width: 274.964 * scaleX,
                          height: 50.504 * scaleY,
                          scale: scale,
                          color: AuthTokens.primary,
                          radius: AuthTokens.cardRadius,
                          textStyle: AuthTextStyles.signupButton,
                          onPressed: _signInWithGoogle,
                        ),
                        AuthField(
                          hintText: 'Full name',
                          left: 26 * scaleX,
                          top: 178.74 * scaleY,
                          width: 274.964 * scaleX,
                          height: 43.022 * scaleY,
                          scale: scale,
                          controller: _fullNameController,
                        ),
                        AuthField(
                          hintText: 'Email address',
                          left: 26 * scaleX,
                          top: 231.12 * scaleY,
                          width: 274.964 * scaleX,
                          height: 43.022 * scaleY,
                          scale: scale,
                          controller: _emailController,
                        ),
                        AuthField(
                          hintText: 'Password',
                          left: 26 * scaleX,
                          top: 286.22 * scaleY,
                          width: 274.964 * scaleX,
                          height: 43.022 * scaleY,
                          scale: scale,
                          obscureText: true,
                          showEyeIcon: true,
                          controller: _passwordController,
                        ),
                        AuthField(
                          hintText: 'Confirm Password',
                          left: 26 * scaleX,
                          top: 338.22 * scaleY,
                          width: 274.964 * scaleX,
                          height: 43.022 * scaleY,
                          scale: scale,
                          obscureText: true,
                          showEyeIcon: true,
                          controller: _confirmPasswordController,
                        ),
                        AuthButton(
                          label: 'Create account',
                          left: 25 * scaleX,
                          top: 405.74 * scaleY,
                          width: 274.964 * scaleX,
                          height: 43.022 * scaleY,
                          scale: scale,
                          color: AuthTokens.primaryDark,
                          radius: AuthTokens.buttonRadius,
                          textStyle: AuthTextStyles.signupButton,
                          onPressed: _createAccountWithEmail,
                        ),
                        Positioned(
                          left: 17 * scaleX,
                          top: 466 * scaleY,
                          width: 294 * scaleX,
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            children: [
                              Text(
                                'Already have an account? ',
                                style: AuthTextStyles.signupCta(scale),
                              ),
                              GestureDetector(
                                onTap: () {
                                  final navigator = Navigator.of(context);
                                  if (navigator.canPop()) {
                                    navigator.pop();
                                    return;
                                  }

                                  navigator.pushReplacementNamed('/login');
                                },
                                child: Text(
                                  'Log in',
                                  style: AuthTextStyles.signupCta(scale)
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
