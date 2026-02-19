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
}
