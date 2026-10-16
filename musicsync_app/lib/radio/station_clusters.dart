import 'dart:math';

import 'radio_station.dart';

/// Un grup de posturi apropiate, afișat ca un singur punct pe hartă (ca
/// orașele din Radio Garden). La zoom mare grupurile se despart.
class StationCluster {
  final List<RadioStation> stations;
  final double lat;
  final double lon;

  const StationCluster(this.stations, this.lat, this.lon);

  /// Numele locului: orașul cel mai frecvent din grup, altfel țara.
  String get placeName {
    final counts = <String, int>{};
    for (final s in stations) {
      final key = s.state.isNotEmpty ? s.state : s.country;
      if (key.isEmpty) continue;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    if (counts.isEmpty) return '';
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  String get countryCode => stations.first.countryCode;
}

/// Grupează posturile vizibile într-o grilă de ~[cellPx] pixeli pe ecran la
/// zoom-ul dat (tile-uri de 256 px). Posturile din afara zonei (cu o
/// margine de o celulă) sunt ignorate, ca harta să rămână fluidă.
List<StationCluster> clusterStations(
  Iterable<RadioStation> stations, {
  required double zoom,
  required double south,
  required double west,
  required double north,
  required double east,
  double cellPx = 56,
}) {
  final cellDeg = 360 / (256 * pow(2, zoom)) * cellPx;
  final cells = <(int, int), List<RadioStation>>{};

  for (final s in stations) {
    final lat = s.lat, lon = s.lon;
    if (lat == null || lon == null) continue;
    if (lat < south - cellDeg || lat > north + cellDeg) continue;
    if (west <= east) {
      if (lon < west - cellDeg || lon > east + cellDeg) continue;
    } else if (lon < west - cellDeg && lon > east + cellDeg) {
      continue; // zona vizibilă trece peste meridianul 180
    }
    final key = ((lat / cellDeg).floor(), (lon / cellDeg).floor());
    (cells[key] ??= []).add(s);
  }

  return cells.values.map((members) {
    members.sort((a, b) => b.clickCount.compareTo(a.clickCount));
    final lat = members.map((s) => s.lat!).reduce((a, b) => a + b) / members.length;
    final lon = members.map((s) => s.lon!).reduce((a, b) => a + b) / members.length;
    return StationCluster(members, lat, lon);
  }).toList();
}
