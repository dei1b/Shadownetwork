enum CampusAffiliation {
  student,
  staff;

  String get label => switch (this) {
    CampusAffiliation.student => 'Student',
    CampusAffiliation.staff => 'Staff',
  };

  static CampusAffiliation fromCode(String? code) {
    return switch (code?.trim().toLowerCase()) {
      'staff' => CampusAffiliation.staff,
      _ => CampusAffiliation.student,
    };
  }
}

class CampusIdentityFields {
  const CampusIdentityFields({
    this.affiliation = CampusAffiliation.student,
    this.displayName = '',
    this.studentNumber = '',
    this.course = '',
    this.yearLevel = '',
    this.sectionSet = '',
    this.employeeId = '',
    this.unit = '',
    this.legacyCourseYear = '',
    this.phone = '',
    this.address = '',
  });

  final CampusAffiliation affiliation;
  final String displayName;
  final String studentNumber;
  final String course;
  final String yearLevel;
  final String sectionSet;
  final String employeeId;
  final String unit;
  final String legacyCourseYear;
  final String phone;
  final String address;

  String get schoolId =>
      affiliation == CampusAffiliation.staff ? employeeId.trim() : studentNumber.trim();

  String get formattedCourseYear {
    if (affiliation == CampusAffiliation.staff) {
      final trimmedUnit = unit.trim();
      return trimmedUnit.isNotEmpty ? trimmedUnit : legacyCourseYear.trim();
    }
    final normalizedYear = _normalizeYear(yearLevel.trim());
    final normalizedSet = _normalizeSet(sectionSet.trim());
    final parts = [
      if (course.trim().isNotEmpty) course.trim(),
      if (normalizedYear.isNotEmpty) normalizedYear,
      if (normalizedSet.isNotEmpty) normalizedSet,
    ];
    if (parts.isNotEmpty) return parts.join(' · ');
    return legacyCourseYear.trim();
  }

  String get summarySubtitle {
    final parts = [
      if (schoolId.isNotEmpty) schoolId,
      if (formattedCourseYear.isNotEmpty) formattedCourseYear,
    ];
    return parts.join(' · ');
  }

  CampusIdentityFields copyWith({
    CampusAffiliation? affiliation,
    String? displayName,
    String? studentNumber,
    String? course,
    String? yearLevel,
    String? sectionSet,
    String? employeeId,
    String? unit,
    String? legacyCourseYear,
    String? phone,
    String? address,
  }) {
    return CampusIdentityFields(
      affiliation: affiliation ?? this.affiliation,
      displayName: displayName ?? this.displayName,
      studentNumber: studentNumber ?? this.studentNumber,
      course: course ?? this.course,
      yearLevel: yearLevel ?? this.yearLevel,
      sectionSet: sectionSet ?? this.sectionSet,
      employeeId: employeeId ?? this.employeeId,
      unit: unit ?? this.unit,
      legacyCourseYear: legacyCourseYear ?? this.legacyCourseYear,
      phone: phone ?? this.phone,
      address: address ?? this.address,
    );
  }

  Map<String, String> validateRequired() {
    final errors = <String, String>{};
    if (displayName.trim().isEmpty) {
      errors['displayName'] = 'Enter your full name.';
    }
    if (affiliation == CampusAffiliation.student) {
      if (studentNumber.trim().isEmpty) {
        errors['studentNumber'] = 'Enter your student number.';
      }
      if (course.trim().isEmpty) {
        errors['course'] = 'Enter your course.';
      }
      if (yearLevel.trim().isEmpty) {
        errors['yearLevel'] = 'Enter your year level.';
      }
      if (sectionSet.trim().isEmpty) {
        errors['sectionSet'] = 'Enter your set or section.';
      }
    } else {
      if (employeeId.trim().isEmpty) {
        errors['employeeId'] = 'Enter your employee ID.';
      }
      if (unit.trim().isEmpty) {
        errors['unit'] = 'Enter your unit or office.';
      }
    }
    return errors;
  }

  Map<String, String> toFirestoreFields() {
    final courseYear = formattedCourseYear;
    if (affiliation == CampusAffiliation.staff) {
      return {
        'affiliation': 'staff',
        'displayName': displayName.trim(),
        'employeeId': employeeId.trim(),
        'unit': unit.trim(),
        'studentNumber': employeeId.trim(),
        'courseYear': courseYear,
        'phone': phone.trim(),
        'address': address.trim(),
      };
    }
    return {
      'affiliation': 'student',
      'displayName': displayName.trim(),
      'studentNumber': studentNumber.trim(),
      'course': course.trim(),
      'yearLevel': yearLevel.trim(),
      'sectionSet': sectionSet.trim(),
      'courseYear': courseYear,
      'phone': phone.trim(),
      'address': address.trim(),
    };
  }

  Map<String, Object?> toJson() => {
    'affiliation': affiliation.name,
    'display_name': displayName.trim(),
    'student_number': studentNumber.trim(),
    'course': course.trim(),
    'year_level': yearLevel.trim(),
    'section_set': sectionSet.trim(),
    'employee_id': employeeId.trim(),
    'unit': unit.trim(),
    'course_year': formattedCourseYear,
    'phone': phone.trim(),
    'address': address.trim(),
  };

  factory CampusIdentityFields.fromJson(Map<String, Object?> json) {
    final affiliation = CampusAffiliation.fromCode(
      json['affiliation'] as String?,
    );
    return CampusIdentityFields(
      affiliation: affiliation,
      displayName: (json['display_name'] as String? ?? '').trim(),
      studentNumber: (json['student_number'] as String? ?? '').trim(),
      course: (json['course'] as String? ?? '').trim(),
      yearLevel: (json['year_level'] as String? ?? '').trim(),
      sectionSet: (json['section_set'] as String? ?? '').trim(),
      employeeId: (json['employee_id'] as String? ?? '').trim(),
      unit: (json['unit'] as String? ?? '').trim(),
      legacyCourseYear: (json['course_year'] as String? ?? '').trim(),
      phone: (json['phone'] as String? ?? '').trim(),
      address: (json['address'] as String? ?? '').trim(),
    );
  }

  factory CampusIdentityFields.fromFirestoreFields(Map<String, dynamic> fields) {
    final affiliation = CampusAffiliation.fromCode(
      fields['affiliation'] as String?,
    );
    final displayName = (fields['displayName'] as String? ?? '').trim();
    final rawCourseYear = (fields['courseYear'] as String? ?? '').trim();
    final phone = (fields['phone'] as String? ?? '').trim();
    final address = (fields['address'] as String? ?? '').trim();

    if (affiliation == CampusAffiliation.staff) {
      final employeeId =
          ((fields['employeeId'] as String?) ??
                  (fields['studentNumber'] as String?) ??
                  '')
              .trim();
      final unit =
          ((fields['unit'] as String?) ?? rawCourseYear).trim();
      return CampusIdentityFields(
        affiliation: CampusAffiliation.staff,
        displayName: displayName,
        employeeId: employeeId,
        unit: unit,
        legacyCourseYear: rawCourseYear,
        phone: phone,
        address: address,
      );
    }

    final studentNumber = (fields['studentNumber'] as String? ?? '').trim();
    var course = (fields['course'] as String? ?? '').trim();
    var yearLevel = (fields['yearLevel'] as String? ?? '').trim();
    var sectionSet = (fields['sectionSet'] as String? ?? '').trim();
    if (course.isEmpty &&
        yearLevel.isEmpty &&
        sectionSet.isEmpty &&
        rawCourseYear.isNotEmpty) {
      final parsed = parseLegacyCourseYear(rawCourseYear);
      course = parsed.course;
      yearLevel = parsed.yearLevel;
      sectionSet = parsed.sectionSet;
    }
    return CampusIdentityFields(
      affiliation: CampusAffiliation.student,
      displayName: displayName,
      studentNumber: studentNumber,
      course: course,
      yearLevel: yearLevel,
      sectionSet: sectionSet,
      legacyCourseYear: rawCourseYear,
      phone: phone,
      address: address,
    );
  }

  List<String> diffKeysFrom(CampusIdentityFields original) {
    final changed = <String>[];
    if (affiliation != original.affiliation) changed.add('affiliation');
    if (displayName.trim() != original.displayName.trim()) {
      changed.add('displayName');
    }
    if (schoolId != original.schoolId) {
      changed.add(
        affiliation == CampusAffiliation.staff ? 'employeeId' : 'studentNumber',
      );
    }
    if (formattedCourseYear != original.formattedCourseYear) {
      changed.add(
        affiliation == CampusAffiliation.staff ? 'unit' : 'courseYear',
      );
    }
    if (phone.trim() != original.phone.trim()) changed.add('phone');
    if (address.trim() != original.address.trim()) changed.add('address');
    return changed;
  }

  static ({String course, String yearLevel, String sectionSet})
  parseLegacyCourseYear(String raw) {
    final segments = raw
        .split(RegExp(r'\s*[·|]\s*'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (segments.length >= 3) {
      return (
        course: segments[0],
        yearLevel: segments[1].replaceFirst(
          RegExp(r'^year\s+', caseSensitive: false),
          '',
        ),
        sectionSet: segments[2].replaceFirst(
          RegExp(r'^set\s+', caseSensitive: false),
          '',
        ),
      );
    }
    if (segments.length == 2) {
      return (
        course: segments[0],
        yearLevel: segments[1].replaceFirst(
          RegExp(r'^year\s+', caseSensitive: false),
          '',
        ),
        sectionSet: '',
      );
    }
    return (course: raw.trim(), yearLevel: '', sectionSet: '');
  }

  static String _normalizeYear(String value) {
    if (value.isEmpty) return '';
    return RegExp(r'^year\b', caseSensitive: false).hasMatch(value)
        ? value
        : 'Year $value';
  }

  static String _normalizeSet(String value) {
    if (value.isEmpty) return '';
    return RegExp(r'^set\b', caseSensitive: false).hasMatch(value)
        ? value
        : 'Set $value';
  }
}
