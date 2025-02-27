import 'dart:async';

import 'package:odoo_repository/src/odoo_environment.dart';
import 'package:odoo_rpc/odoo_rpc.dart';

import 'odoo_id.dart';
import 'odoo_record.dart';
import 'odoo_rpc_call.dart';

/// Base class of Odoo repository logic with RPC calls and local caching.
/// It sends stream events on record changes.
/// On read operation at first cached value is returned then async RPC call
/// is issued. When RPC response arrives stream gets update with fresh value.
class OdooRepository<R extends OdooRecord> {
  /// Holds current Odoo records
  List<R> latestRecords = [];

  List<dynamic> domain = [
    [1, '=', 1]
  ];

  /// holds total number of records in remote database.
  int remoteRecordsCount = 0;

  /// fetch limit
  int limit = 80;

  /// offset when fetching records.
  /// Normally it should be zero.
  /// It can be increased to load more data for list view
  /// without clearing a cache. See [cacheMoreRecords]
  int _offset = 0;

  set offset(int value) {
    if (value < 0) value = 0;
    if (value > remoteRecordsCount) value = remoteRecordsCount;
    _offset = value;
  }

  int get offset => _offset;

  /// Allows to change default order when fetching data.
  String order = '';

  /// Shows if [cacheMoreRecords] is running right now.
  /// Prevents loading more records before current request is finished.
  bool isLoadingMore = false;

  /// True if local cache contains less records that remote db.
  bool get canLoadMore => !isLoadingMore && (_offset < remoteRecordsCount);

  bool get hasReachedMax => latestRecords.length >= remoteRecordsCount;

  // Duration in ms for throttling RPC calls
  int throttleDuration = 1000;

  // Tells if throttling is active now
  bool _isThrottling = false;

  /// Holds list of all repositories
  late final OdooEnvironment env;

  /// Tells whether we should send record change events to a stream.
  /// Activates when there is at least one listener.
  bool recordStreamActive = false;

  /// Record change events stream controller
  late StreamController<List<R>> recordStreamController;

  /// Returns stream of record changed events
  Stream<List<R>> get recordStream => recordStreamController.stream;

  /// Odoo ORM model name. E.g. 'res.partner'
  /// Must be overridden to set real model name.
  final String modelName;
  final List<String> oFields;

  /// Instantiates [OdooRepository] with given [OdooDatabase] info.
  OdooRepository(this.env, this.modelName, this.oFields) {
    recordStreamController = StreamController<List<R>>.broadcast(
        onListen: startSteam, onCancel: stopStream);
  }

  /// Enables stream of records fetched
  void startSteam() => recordStreamActive = true;

  /// Disables stream of records fetched
  void stopStream() => recordStreamActive = false;

  /// newIdMapping for all Odoo instances starts with
  final String newIdMappingPrefix = 'OdooNewIdMapping';

  /// Unique key per odoo instance
  String get newIdMappingKey => '$newIdMappingPrefix:${env.serverUuid}';

  /// Gets mapping from cache
  Map<int, int> get newIdMapping {
    if (!isAuthenticated) {
      return <int, int>{};
    }
    return Map<int, int>.from(
        env.cache.get(newIdMappingKey, defaultValue: <int, int>{}));
  }

  /// Stores mapping to cache
  Future<void> setNewIdMapping(
      {required int newId, required int realId}) async {
    if (!isAuthenticated) {
      return;
    }
    var mapping = newIdMapping;
    mapping[newId] = realId;
    return await env.cache.put(newIdMappingKey, mapping);
  }

  /// Gets unique part of a key for
  /// caching records of [modelName] of database per user
  String get cacheKeySignature {
    if (!isAuthenticated) {
      throw OdooAuthenticationException();
    }
    return '${env.serverUuid}:${env.orpc.sessionId!.userId}:$modelName';
  }

  /// Returns cache key prefix to store call with unique key name
  String get rpcCallKeyPrefix {
    return 'OdooRpcCall:$cacheKeySignature:';
  }

  /// Returns prefix that is used caching records of [modelName] of database
  String get recordCacheKeyPrefix {
    if (!isAuthenticated) {
      throw OdooAuthenticationException();
    }
    return 'OdooRecord:$cacheKeySignature:';
  }

  /// Returns cache key to store record ids of current model.
  /// Unique per url+db+user+model.
  String get recordIdsCacheKey => 'OdooRecordIds:$cacheKeySignature';

  /// Sends empty list of records to a stream
  void clearRecords() {
    latestRecords = [];
    if (recordStreamActive) {
      recordStreamController.add([]);
    }
  }

  /// Returns cache key name by record [id]
  String getRecordCacheKey(int id) {
    return '$recordCacheKeyPrefix$id';
  }

  /// Deletes all cached records
  Future<void> clearCaches() async {
    try {
      final keyPrefix = recordCacheKeyPrefix;
      for (String key in env.cache.keys) {
        if (key.contains(keyPrefix)) {
          await env.cache.delete(key);
        }
      }
    } catch (e) {
      // clearCaches might be called when session already expired
      // and recordCacheKeyPrefix can't be computed
      return;
    }
  }

  /// Stores [record] in cache
  Future<void> cachePut(R record) async {
    if (isAuthenticated) {
      final key = getRecordCacheKey(record.id);
      await env.cache.put(key, record);
    }
  }

  /// Deletes [record] from cache
  Future<void> cacheDelete(R? record) async {
    if (isAuthenticated && record != null) {
      final key = getRecordCacheKey(record.id);
      await env.cache.delete(key);
    }
  }

  /// Gets record from cache by record's [id] (odoo id).
  R? cacheGet(int id) {
    if (isAuthenticated) {
      final key = getRecordCacheKey(id);
      try {
        return env.cache.get(key, defaultValue: null);
      } on Exception {
        env.cache.delete(key);
        return null;
      }
    }
    return null;
  }

  /// Returns currently cached records
  List<R> get _cachedRecords {
    if (!isAuthenticated) {
      throw OdooAuthenticationException();
    }
    // take list of cached ids and fetch corresponding records
    var ids = env.cache.get(recordIdsCacheKey, defaultValue: []);
    var recordIDs = List<int>.from(ids);
    var cachedRecords = <R>[];
    for (var recordID in recordIDs) {
      var record = cacheGet(recordID);
      if (record != null) {
        cachedRecords.add(record);
      }
    }
    return cachedRecords;
  }

  /// Get records from local cache and trigger remote fetch if not throttling
  List<R> get records {
    latestRecords = _cachedRecords;
    env.logger.d(
        '$modelName: Got ${latestRecords.length.toString()} records from cache.');
    if (!_isThrottling) {
      fetchRecords();
      _isThrottling = true;
      Timer(Duration(milliseconds: throttleDuration),
          () => _isThrottling = false);
    }
    return latestRecords;
  }

  /// Get records from remote.
  /// Must set [remoteRecordsCount]
  /// Read operation is issued without call queue as it is idempotent.
  /// Many repositories can call own searchRead concurrently.
  Future<List<dynamic>> searchRead() async {
    try {
      final Map<String, dynamic> response = await env.orpc.callKw({
        'model': modelName,
        'method': 'web_search_read',
        'args': [],
        'kwargs': {
          'context': {'bin_size': true},
          'domain': domain,
          'fields': oFields,
          'limit': limit,
          'offset': offset,
          'order': order
        },
      });
      remoteRecordsCount = response['length'] as int;
      return response['records'] as List<dynamic>;
    } on Exception {
      remoteRecordsCount = 0;
      return [];
    }
  }

  /// Must be overridden to create real record from json
  R createRecordFromJson(Map<String, dynamic> json) {
    return OdooRecord(0) as R;
  }

  /// Sends given list of records to a stream if there are listeners
  void _recordStreamAdd(List<R> latestRecords) {
    if (recordStreamActive && isAuthenticated) {
      recordStreamController.add(latestRecords);
    }
  }

  /// Fetch records from remote and push to the stream
  Future<void> fetchRecords() async {
    /// reset offset as if we are loading first page.
    /// To fetch more than that use [cacheMoreRecords].
    offset = 0;
    try {
      final res = await searchRead();
      var freshRecordsIDs = <int>[];
      var freshRecords = <R>[];
      await clearCaches();
      for (Map<String, dynamic> item in res) {
        var record = createRecordFromJson(item);
        freshRecordsIDs.add(record.id);
        freshRecords.add(record);
        await cachePut(record);
      }
      if (freshRecordsIDs.isNotEmpty) {
        await env.cache.delete(recordIdsCacheKey);
        await env.cache.put(recordIdsCacheKey, freshRecordsIDs);
      }
      latestRecords = freshRecords;
      _recordStreamAdd(latestRecords);
    } on Exception {
      env.logger.d('$modelName: frontend_get_requests: OdooException}');
    }
  }

  /// Fetches more records from remote and adds them to list of cached records.
  /// Supposed to be used with list views.
  Future<void> cacheMoreRecords() async {
    if (isLoadingMore) return;
    isLoadingMore = true;
    offset += limit;
    try {
      final res = await searchRead();
      isLoadingMore = false;
      if (res.isEmpty) return;
      var cachedRecords = _cachedRecords;
      for (Map<String, dynamic> item in res) {
        var record = createRecordFromJson(item);
        cachedRecords.add(record);
        await cachePut(record);
      }
      await env.cache.delete(recordIdsCacheKey);
      await env.cache
          .put(recordIdsCacheKey, cachedRecords.map((e) => e.id).toList());
      latestRecords = cachedRecords;
      _recordStreamAdd(latestRecords);
    } on Exception {
      isLoadingMore = false;
      env.logger.d('$modelName: frontend_get_requests: OdooException}');
    }
  }

  // Public methods

  bool get isAuthenticated => env.isAuthenticated;

  int? currentNextId;

  // Truncate to 32 bit: database index limitation
  int get timestamp32 => DateTime.now().millisecondsSinceEpoch & 0xFFFFFFFF;

  /// Returns next available id
  int get nextId {
    if (currentNextId == null) {
      currentNextId = timestamp32;
      return currentNextId!;
    }
    var candidateNextId = timestamp32;
    while (currentNextId == candidateNextId) {
      candidateNextId = timestamp32;
    }
    currentNextId = candidateNextId;

    return currentNextId!;
  }

  /// Create new record in cache and schedule rpc call
  /// Must use call queue via execute() method to issue calls
  /// sequentially comparing to other repositories(models)
  Future<R> create(R record) async {
    env.logger.d('$modelName: create id=${record.id}');
    await cachePut(record);
    latestRecords.insert(0, record);
    final vals = record.toVals();
    vals.remove('id');
    // vals list or vals
    var serverVersion = env.orpc.sessionId!.serverVersionInt;
    final args = serverVersion >= 12 ? [vals] : vals;
    await execute(
        recordId: record.id,
        method: 'create',
        args: args,
        kwargs: {},
        awaited: true);
    _recordStreamAdd(latestRecords);
    return record;
  }

  /// To be implemented in concrete class
  List<R> search(List<List<dynamic>> domain, {int? limit, String? order}) {
    return [];
  }

  /// Update record in cache and schedule rpc call
  /// /// Must use call queue via execute() method to issue calls
  /// sequentially comparing to other repositories(models)
  Future<void> write(R newRecord) async {
    var values = <String, dynamic>{};
    final oldRecord = latestRecords.firstWhere(
        (element) => element.id == newRecord.id,
        orElse: () => newRecord);
    // Determine what fields were changed
    final oldRecordJson = oldRecord.toVals();
    final newRecordJson = newRecord.toVals();
    for (var k in newRecordJson.keys) {
      if (oldRecordJson[k] != newRecordJson[k]) {
        values[k] = newRecordJson[k];
      }
    }
    if (values.isEmpty) {
      return;
    }
    // write-through cache
    final recordIndex =
        latestRecords.indexWhere((element) => element.id == newRecord.id);
    if (recordIndex < 0) {
      latestRecords.insert(0, newRecord);
    } else {
      latestRecords[recordIndex] = newRecord;
    }
    env.logger.d('$modelName: write id=${newRecord.id}, values = `$values`');
    await execute(
        recordId: newRecord.id,
        method: 'write',
        args: [OdooId(modelName, newRecord.id), values],
        kwargs: {},
        awaited: true);
    _recordStreamAdd(latestRecords);
  }

  /// Unlink record on remote db
  /// /// Must use call queue via execute() method to issue calls
  /// sequentially comparing to other repositories(models)
  Future<void> unlink(R record) async {
    env.logger.d('$modelName: unlink id=${record.id}');
    await execute(recordId: record.id, method: 'unlink');
    await cacheDelete(record);
  }

  /// Converts [newId] created in offline mode to [id] from odoo database.
  int newIdToId(int newId) {
    if (newIdMapping.containsKey(newId)) {
      return newIdMapping[newId]!;
    }
    return newId;
  }

  /// Helps to builds rpc call instance.
  OdooRpcCall buildRpcCall(
      String method, int recordId, dynamic args, Map<String, dynamic> kwargs) {
    return OdooRpcCall(
      env.orpc.sessionId!.userId,
      env.orpc.baseURL,
      env.orpc.sessionId!.dbName,
      modelName,
      recordId,
      method,
      args,
      kwargs,
    );
  }

  /// Executes [method] on [recordId] of current [modelName].
  /// It places call to queue that is processed either immediately if
  /// network is online or when network state will be changed to online.
  Future<dynamic> execute(
      {required int recordId,
      required String method,
      dynamic args = const [],
      Map<String, dynamic> kwargs = const {},
      bool awaited = false}) async {
    final rpcCall = buildRpcCall(method, recordId, args, kwargs);
    await env.queueCall(rpcCall, awaited: awaited);
  }
}
