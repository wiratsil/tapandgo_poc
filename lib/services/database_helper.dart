import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/common_data_model.dart';
import '../models/route_detail_model.dart';
import '../models/price_range_model.dart';
import '../models/bus_trip_model.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;

  factory DatabaseHelper() => _instance;

  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String path = join(await getDatabasesPath(), 'tapandgo.db');
    return await openDatabase(path, version: 1, onCreate: _onCreate);
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE common_data(
        id INTEGER PRIMARY KEY,
        commonCode TEXT,
        commonName TEXT,
        commonType TEXT,
        valuesText TEXT,
        isActive INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE route_details(
        id INTEGER PRIMARY KEY,
        routeId INTEGER,
        seq INTEGER,
        busstopId INTEGER,
        busstopDesc TEXT,
        isExpress INTEGER,
        afterExpressBusstopId INTEGER,
        latitude REAL,
        longitude REAL
      )
    ''');

    await db.execute('''
      CREATE TABLE price_ranges(
        id INTEGER PRIMARY KEY,
        routeDetailStartId INTEGER,
        routeDetailEndId INTEGER,
        price REAL,
        priceGroupId INTEGER,
        routeId INTEGER,
        afterExpressBusstopId INTEGER,
        routeDetailStartSeq INTEGER,
        routeDetailEndSeq INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE bus_trips(
        id INTEGER PRIMARY KEY,
        routeId INTEGER,
        buslineId INTEGER,
        businfoId INTEGER,
        licensePlate TEXT,
        busno TEXT,
        actualDatetimeFromSource TEXT,
        actualDatetimeToDestination TEXT
      )
    ''');
  }

  // Insert methods
  Future<void> insertCommonData(List<CommonDataItem> items) async {
    final db = await database;
    Batch batch = db.batch();
    for (var item in items) {
      batch.insert(
        'common_data',
        item.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> insertRouteDetails(List<RouteDetail> items) async {
    final db = await database;
    Batch batch = db.batch();
    for (var item in items) {
      batch.insert(
        'route_details',
        item.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> insertPriceRanges(List<PriceRange> items) async {
    final db = await database;
    Batch batch = db.batch();
    for (var item in items) {
      batch.insert(
        'price_ranges',
        item.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> insertBusTrips(List<BusTrip> items) async {
    final db = await database;
    Batch batch = db.batch();
    for (var item in items) {
      batch.insert(
        'bus_trips',
        item.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  // Clear data methods
  Future<void> clearAllData() async {
    final db = await database;
    await db.delete('common_data');
    await db.delete('route_details');
    await db.delete('price_ranges');
    await db.delete('bus_trips');
  }

  // Get first routeId from DB (for default/mock usage)
  Future<int?> getFirstRouteId() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      'SELECT DISTINCT routeId FROM route_details LIMIT 1',
    );
    if (maps.isNotEmpty) {
      return maps.first['routeId'] as int?;
    }
    return null;
  }

  // Nearest Bus Stop Logic
  Future<RouteDetail?> getNearestBusStop(
    double lat,
    double lng, {
    int? routeId,
  }) async {
    final db = await database;
    String whereClause = '';
    List<dynamic> args = [];

    if (routeId != null) {
      whereClause = 'WHERE routeId = ?';
      args.add(routeId);
    }

    args.addAll([lat, lat, lng, lng]);

    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT * FROM route_details
      $whereClause
      ORDER BY ((latitude - ?) * (latitude - ?) + (longitude - ?) * (longitude - ?)) ASC
      LIMIT 1
    ''', args);

    if (maps.isNotEmpty) {
      return RouteDetail.fromJson(maps.first);
    }
    return null;
  }

  /// Get the next bus stop by sequence number
  Future<RouteDetail?> getNextBusStop(int currentSeq, {int? routeId}) async {
    final db = await database;
    String whereClause = 'WHERE seq > ?';
    List<dynamic> args = [currentSeq];

    if (routeId != null) {
      whereClause += ' AND routeId = ?';
      args.add(routeId);
    }

    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT * FROM route_details
      $whereClause
      ORDER BY seq ASC
      LIMIT 1
    ''', args);

    if (maps.isNotEmpty) {
      return RouteDetail.fromJson(maps.first);
    }
    return null;
  }

  // Fare Calculation Logic
  // Step 1: กรอง — routeDetailStartSeq <= tapInSeq AND routeDetailEndSeq >= tapOutSeq
  // Step 2: เลือก — startSeq ใกล้ tapIn ที่สุด (primary) → endSeq ใกล้ tapOut ที่สุด (secondary)
  Future<double?> getFare(int tapInSeq, int tapOutSeq, {int? routeId}) async {
    final db = await database;
    print(
      '[DEBUG] 🔍 getFare Query: TapIn=$tapInSeq, TapOut=$tapOutSeq, RouteId=$routeId',
    );

    // Step 1: Filter — containment
    String whereClause =
        'WHERE routeDetailStartSeq <= ? AND routeDetailEndSeq >= ?';
    List<dynamic> args = [tapInSeq, tapOutSeq];

    if (routeId != null) {
      whereClause += ' AND routeId = ?';
      args.add(routeId);
    }

    final List<Map<String, dynamic>> maps = await db.rawQuery(
      'SELECT * FROM price_ranges $whereClause',
      args,
    );

    print('[DEBUG] 🔍 Found ${maps.length} price candidates');

    if (maps.isNotEmpty) {
      // Step 2: เลือกที่ใกล้เคียงสุด
      // 1st priority: minimize |tapInSeq - startSeq| (startSeq ใกล้สุดก่อน)
      // 2nd priority: minimize |tapOutSeq - endSeq| (endSeq ใกล้สุดเป็น tiebreaker)

      Map<String, dynamic>? bestMatch;
      int bestStartDist = 999999;
      int bestEndDist = 999999;

      for (var c in maps) {
        int startSeq = c['routeDetailStartSeq'] as int;
        int endSeq = c['routeDetailEndSeq'] as int;
        int startDist = (tapInSeq - startSeq).abs();
        int endDist = (tapOutSeq - endSeq).abs();

        print(
          '[DEBUG] Candidate ID: ${c['id']}, Start: $startSeq, End: $endSeq, Price: ${c['price']}, StartDist: $startDist, EndDist: $endDist',
        );

        if (startDist < bestStartDist ||
            (startDist == bestStartDist && endDist < bestEndDist)) {
          bestStartDist = startDist;
          bestEndDist = endDist;
          bestMatch = c;
        }
      }

      if (bestMatch != null) {
        print(
          '[DEBUG] ✅ Best Match ID: ${bestMatch['id']}, Price: ${bestMatch['price']}, StartDist: $bestStartDist, EndDist: $bestEndDist',
        );

        var priceVal = bestMatch['price'];
        if (priceVal is num) return priceVal.toDouble();
        if (priceVal is String) return double.tryParse(priceVal);
      }
    }
    return null;
  }

  // Mock Location for Testing
  Future<RouteDetail?> getRandomBusStop({int? minSeq, int? routeId}) async {
    final db = await database;
    List<String> conditions = [];
    List<dynamic> args = [];

    if (minSeq != null) {
      conditions.add('seq > ?');
      args.add(minSeq);
    }

    if (routeId != null) {
      conditions.add('routeId = ?');
      args.add(routeId);
    }

    String whereClause = conditions.isNotEmpty
        ? 'WHERE ${conditions.join(' AND ')}'
        : '';

    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT * FROM route_details 
      $whereClause
      ORDER BY RANDOM() 
      LIMIT 1
    ''', args);

    if (maps.isNotEmpty) {
      return RouteDetail.fromJson(maps.first);
    }
    return null;
  }

  /// Get the active bus trip (actualDatetimeToDestination is NULL)
  Future<BusTrip?> getActiveBusTrip() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT * FROM bus_trips
      WHERE actualDatetimeToDestination IS NULL
        AND actualDatetimeFromSource IS NOT NULL
      ORDER BY actualDatetimeFromSource DESC
      LIMIT 1
    ''');
    if (maps.isNotEmpty) {
      return BusTrip.fromJson(maps.first);
    }
    return null;
  }

  /// Get all route details ordered by seq
  Future<List<RouteDetail>> getAllRouteDetails() async {
    final db = await database;
    final maps = await db.rawQuery('SELECT * FROM route_details ORDER BY seq ASC');
    return maps.map((m) => RouteDetail.fromJson(m)).toList();
  }

  /// Get all price ranges ordered by startSeq
  Future<List<PriceRange>> getAllPriceRanges() async {
    final db = await database;
    final maps = await db.rawQuery('SELECT * FROM price_ranges ORDER BY routeDetailStartSeq ASC');
    return maps.map((m) => PriceRange.fromJson(m)).toList();
  }

  /// Get count of route details
  Future<int> getRouteDetailsCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as cnt FROM route_details');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Get count of price ranges
  Future<int> getPriceRangesCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as cnt FROM price_ranges');
    return Sqflite.firstIntValue(result) ?? 0;
  }
}
