enum Category {
  rescue,
  food,
  water,
  medical,
  shelter,
  transport,
  information,
  other,
  // Append codes: existing enum positions are persisted as lookup IDs.
  fireElectrical,
  safetyThreat,
  publicHazard;

  static const sosCategories = [
    medical,
    fireElectrical,
    safetyThreat,
    rescue,
    publicHazard,
    other,
  ];

  // Retired categories remain readable but share the Other filter in the new UI.
  Category get sosCategory => switch (this) {
    food || water || shelter || transport || information => other,
    _ => this,
  };

  String get label => switch (this) {
    medical => 'Medical Assistance',
    fireElectrical => 'Fire & Electrical Danger',
    safetyThreat => 'Safety Threat',
    rescue => 'Flood & Rescue',
    publicHazard => 'Immediate Public Hazard',
    other => 'Other Urgent Assistance',
    food => 'Food',
    water => 'Water',
    shelter => 'Shelter',
    transport => 'Transport',
    information => 'Information',
  };
}
