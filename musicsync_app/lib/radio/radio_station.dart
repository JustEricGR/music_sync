import 'geo.dart';

final RegExp _fmFrequency = RegExp(r'(?<![\d.,])(8[7-9]|9\d|10[0-8])[.,](\d)(?!\d)');

/// Cât de exactă e poziția postului pe hartă.
enum LocationPrecision {
  /// Coordonate reale din Radio Browser.
  exact,

  /// Plasat după orașul/regiunea declarată (centrul orașului).
  city,

  /// Fără oraș cunoscut (post național / online) — pus la capitală.
  country,
}

class RadioStation {
  final String uuid;
  final String name;
  final String streamUrl;
  final String homepage;
  final String favicon;
  final String countryCode;
  final String country;

  /// Orașul / regiunea (din Radio Browser), dacă există.
  final String state;
  final String tags;
  final String codec;
  final int bitrate;
  final bool isHls;
  final int votes;
  final int clickCount;
  final int clickTrend;
  final double? lat;
  final double? lon;

  /// Adăugat manual de utilizator (nu vine din Radio Browser).
  final bool isManual;

  final LocationPrecision precision;

  const RadioStation({
    required this.uuid,
    required this.name,
    required this.streamUrl,
    this.homepage = '',
    this.favicon = '',
    this.countryCode = '',
    this.country = '',
    this.state = '',
    this.tags = '',
    this.codec = '',
    this.bitrate = 0,
    this.isHls = false,
    this.votes = 0,
    this.clickCount = 0,
    this.clickTrend = 0,
    this.lat,
    this.lon,
    this.isManual = false,
    this.precision = LocationPrecision.exact,
  });

  /// Copie plasată pe hartă (pentru posturile fără coordonate).
  RadioStation withLocation(double lat, double lon, LocationPrecision precision) => RadioStation(
        uuid: uuid,
        name: name,
        streamUrl: streamUrl,
        homepage: homepage,
        favicon: favicon,
        countryCode: countryCode,
        country: country,
        state: state,
        tags: tags,
        codec: codec,
        bitrate: bitrate,
        isHls: isHls,
        votes: votes,
        clickCount: clickCount,
        clickTrend: clickTrend,
        lat: lat,
        lon: lon,
        isManual: isManual,
        precision: precision,
      );

  bool get hasLocation => lat != null && lon != null;

  /// Frecvența FM, dacă apare în numele postului (ex. "Republic 100.3").
  String? get fmFrequency {
    final m = _fmFrequency.firstMatch(name);
    return m == null ? null : '${m.group(1)}.${m.group(2)} FM';
  }

  /// Distanța doar când poziția înseamnă ceva (nu pentru posturile
  /// naționale puse la capitală).
  double? distanceKmFrom(double? fromLat, double? fromLon) {
    if (!hasLocation || precision == LocationPrecision.country || fromLat == null || fromLon == null) return null;
    return haversineKm(fromLat, fromLon, lat!, lon!);
  }

  static double? _toDouble(dynamic v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
  static int _toInt(dynamic v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) ?? 0 : 0);

  /// Din răspunsul API-ului Radio Browser.
  factory RadioStation.fromRadioBrowser(Map<String, dynamic> j) {
    final resolved = (j['url_resolved'] as String?) ?? '';
    return RadioStation(
      uuid: j['stationuuid'] as String? ?? '',
      name: ((j['name'] as String?) ?? '').trim(),
      streamUrl: resolved.isNotEmpty ? resolved : (j['url'] as String? ?? ''),
      homepage: j['homepage'] as String? ?? '',
      favicon: j['favicon'] as String? ?? '',
      countryCode: (j['countrycode'] as String? ?? '').toUpperCase(),
      country: j['country'] as String? ?? '',
      state: (j['state'] as String? ?? '').trim(),
      tags: j['tags'] as String? ?? '',
      codec: j['codec'] as String? ?? '',
      bitrate: _toInt(j['bitrate']),
      isHls: _toInt(j['hls']) == 1,
      votes: _toInt(j['votes']),
      clickCount: _toInt(j['clickcount']),
      clickTrend: _toInt(j['clicktrend']),
      lat: _toDouble(j['geo_lat']),
      lon: _toDouble(j['geo_long']),
    );
  }

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'name': name,
        'streamUrl': streamUrl,
        'homepage': homepage,
        'favicon': favicon,
        'countryCode': countryCode,
        'country': country,
        'state': state,
        'tags': tags,
        'codec': codec,
        'bitrate': bitrate,
        'isHls': isHls,
        'votes': votes,
        'clickCount': clickCount,
        'clickTrend': clickTrend,
        'lat': lat,
        'lon': lon,
        'isManual': isManual,
        if (precision != LocationPrecision.exact) 'precision': precision.name,
      };

  factory RadioStation.fromJson(Map<String, dynamic> j) => RadioStation(
        uuid: j['uuid'] as String? ?? '',
        name: j['name'] as String? ?? '',
        streamUrl: j['streamUrl'] as String? ?? '',
        homepage: j['homepage'] as String? ?? '',
        favicon: j['favicon'] as String? ?? '',
        countryCode: j['countryCode'] as String? ?? '',
        country: j['country'] as String? ?? '',
        state: j['state'] as String? ?? '',
        tags: j['tags'] as String? ?? '',
        codec: j['codec'] as String? ?? '',
        bitrate: _toInt(j['bitrate']),
        isHls: j['isHls'] == true,
        votes: _toInt(j['votes']),
        clickCount: _toInt(j['clickCount']),
        clickTrend: _toInt(j['clickTrend']),
        lat: _toDouble(j['lat']),
        lon: _toDouble(j['lon']),
        isManual: j['isManual'] == true,
        precision: LocationPrecision.values.asNameMap()[j['precision']] ?? LocationPrecision.exact,
      );
}
