class UserInformation {
  const UserInformation({
    required this.fullName,
    required this.phoneNumber,
    required this.address,
  });

  final String fullName;
  final String phoneNumber;
  final String address;

  Map<String, Object?> toJson() => {
    'full_name': fullName,
    'phone_number': phoneNumber,
    'address': address,
  };

  factory UserInformation.fromJson(Map<String, Object?> json) {
    String field(String key, int limit) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty || value.length > limit) {
        throw const FormatException(
          'Enter your full name, phone number and address.',
        );
      }
      return value.trim();
    }

    return UserInformation(
      fullName: field('full_name', 100),
      phoneNumber: field('phone_number', 50),
      address: field('address', 300),
    );
  }
}
