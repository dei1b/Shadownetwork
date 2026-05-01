abstract class AuthRepository {
  Future<void> signInWithEmailPassword({
    required String email,
    required String password,
  });

  Future<void> createUserWithEmailPassword({
    required String fullName,
    required String email,
    required String password,
  });

  Future<void> signInWithGoogle();

  Future<void> signOut();
}
