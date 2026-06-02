import 'dart:math';

class FaceMatcher {
  static double euclideanDistance(List<double> v1, List<double> v2) {
    if (v1.length != v2.length) return 999.0;
    double sum = 0;
    for (int i = 0; i < v1.length; i++) {
      final diff = v1[i] - v2[i];
      sum += diff * diff;
    }
    return sqrt(sum);
  }

  static bool isMatch(
    List<double> stored,
    List<double> detected, {
    double threshold = 0.6,
  }) {
    if (stored.isEmpty || detected.isEmpty || stored.length != detected.length) return false;
    return euclideanDistance(stored, detected) <= threshold;
  }

  static ({int index, double distance})? findBestMatch(
    List<double> detected,
    List<List<double>> storedVectors, {
    double threshold = 0.6,
  }) {
    if (detected.isEmpty || storedVectors.isEmpty) return null;

    int bestIndex = -1;
    double bestDistance = double.infinity;

    for (int i = 0; i < storedVectors.length; i++) {
      final vector = storedVectors[i];
      if (vector.isEmpty || vector.length != detected.length) continue;
      final distance = euclideanDistance(detected, vector);
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = i;
      }
    }

    if (bestIndex >= 0 && bestDistance <= threshold) {
      return (index: bestIndex, distance: bestDistance);
    }
    return null;
  }

  static double similarityPercent(double distance, {double threshold = 0.6}) {
    if (distance <= 0) return 100.0;
    if (distance >= threshold) return 0.0;
    return ((1 - distance / threshold) * 100).clamp(0.0, 100.0);
  }
}
