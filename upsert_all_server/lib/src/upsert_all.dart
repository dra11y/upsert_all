import 'package:serverpod/serverpod.dart';

import 'generated/protocol.dart';
import 'extensions/extensions.dart';
import 'serverpod_internals/serverpod_internals.dart';
import 'upsert_return_types.dart';

Future<Map<UpsertReturnType, List<T>>> upsertAll<T extends TableRow>(
  Session session, {
  required Iterable<T> rows,
  int batchSize = 100,
  required Set<Column> uniqueBy,
  List<Column> excludedCriteriaColumns = const [],
  List<Column> nonUpdatableColumns = const [],
  Set<UpsertReturnType> returning = UpsertReturnTypes.changes,
  Transaction? transaction,
}) async {
  // Do nothing if passed an empty list.
  if (rows.isEmpty) return {};

  // Make sure ON CONFLICT column(s) specified.
  assert(uniqueBy.isNotEmpty);

  if (excludedCriteriaColumns.isEmpty) {
    excludedCriteriaColumns = [
      ColumnInt('id'),
      ColumnDateTime('createdAt'),
      ColumnDateTime('updatedAt'),
    ];
  }

  if (nonUpdatableColumns.isEmpty) {
    nonUpdatableColumns = [ColumnInt('id'), ColumnDateTime('createdAt')];
  }

  var table = session.serverpod.serializationManager.getTableForType(T);
  assert(table is Table, '''
You need to specify a template type that is a subclass of TableRow.
E.g. myRows = await session.db.find<MyTableClass>(where: ...);
Current type was $T''');
  if (table == null) return {};

  var startTime = DateTime.now();

  // Convert all rows to JSON.
  List<Map> dataList = rows.map((row) => row.toJsonForDatabase()).toList();

  // Get all columns in the table that are present in the JSON.
  // It only makes sense to include the `id` column if it is in the ON CONFLICT columns.
  List<Column> columns = table.columns
      .where((column) =>
          uniqueBy.contains(ColumnInt('id')) || column.columnName != 'id')
      .where((column) =>
          dataList.any((data) => data.containsKey(column.columnName)))
      .toList();
  Map<String, String> columnTypes = Map.fromEntries(columns
      .map((column) => MapEntry(column.columnName, column.databaseType)));
  List<String> columnsList =
      columns.map((column) => column.columnName).toList();
  List<String> quotedColumnsList =
      columnsList.map((columnName) => '"$columnName"').toList();
  final onConflictColumnsList =
      uniqueBy.map((column) => '"${column.columnName}"').toList();
  final skipUpdate =
      onConflictColumnsList.every((col) => quotedColumnsList.contains(col));
  final excludedCriteriaColumnsList = excludedCriteriaColumns
      .map((column) => '"${column.columnName}"')
      .toList();
  final nonUpdatableColumnsList =
      nonUpdatableColumns.map((column) => '"${column.columnName}"').toList();

  final tableName = table.tableName;
  final insertColumns = columnsList
      .where((column) => column != 'id')
      .map((col) => '"$col"')
      .join(', ');
  final insertColumnsWithTypes = columnsList
      .where((column) => column != 'id')
      .map((col) =>
          columnTypes[col] != null ? '"$col"::${columnTypes[col]!}' : '"$col"')
      .join(', ');
  final insertColumnsForCompareWithJsonB =
      insertColumnsWithTypes.replaceAll(RegExp('(?<!jsonb)::json'), '::jsonb');
  // print('insertColumnsForCompareWithJsonB = $insertColumnsForCompareWithJsonB');
  final updateSetList = quotedColumnsList
      .where((column) => !nonUpdatableColumnsList.contains(column))
      .map((column) => '$column = input_values.$column')
      .join(',\n    ');
  final quotedOnConflicts = onConflictColumnsList.join(', ');
  final updateWhere = onConflictColumnsList
      .map((column) =>
          '$tableName.$column IS NOT DISTINCT FROM input_values.$column')
      .join(' AND ');
  final updateWhereNotExistsInserted = onConflictColumnsList
      .map((column) =>
          '$tableName.$column IS NOT DISTINCT FROM inserted_rows.$column')
      .join(' AND ');
  final distinctOrConditionsList = quotedColumnsList
      .where((column) =>
          !excludedCriteriaColumnsList.contains(column) &&
          !onConflictColumnsList.contains(column))
      .map((column) =>
          '$tableName.$column IS DISTINCT FROM input_values.$column');

  final distinctOrConditions = distinctOrConditionsList.isNotEmpty
      ? 'AND (${distinctOrConditionsList.join(' OR ')})'
      : '';

  var batches = dataList.chunked(batchSize);
  Map<UpsertReturnType, List<T>> resultsMap = {};

  final selectResultsUnion = [
    if (returning.contains(UpsertReturnType.inserted))
      "SELECT id, $insertColumnsWithTypes, ${UpsertReturnType.inserted.index} AS \"returnType\" FROM inserted_rows",
    if (!skipUpdate && returning.contains(UpsertReturnType.updated))
      "SELECT id, $insertColumnsWithTypes, ${UpsertReturnType.updated.index} AS \"returnType\" FROM updated_rows",
    if (returning.contains(UpsertReturnType.unchanged))
      "SELECT id, $insertColumnsWithTypes, ${UpsertReturnType.unchanged.index} AS \"returnType\" FROM unchanged_rows",
  ].join(' UNION ALL ');

  var index = 0;
  for (var batch in batches) {
    print(
        "upsertAll $tableName batch ${index + 1} of ${batches.length}, size = $batchSize, start = ${index * batchSize}, length = ${batch.length}");
    index++;

    var valuesList = batch
        .asMap()
        .map((index, data) {
          final rowValues = [];
          for (var column in columns) {
            final columnName = column.columnName;
            var convertedValue =
                DatabasePoolManager.encoder.convert(data[columnName]);
            if (index == 0) {
              // print('columnName $columnName type = ${columnTypes[columnName]}');
              convertedValue += '::${columnTypes[columnName]}';
            }
            rowValues.add(convertedValue);
          }
          return MapEntry(index, rowValues);
        })
        .values
        .toList();

    final inputValues =
        valuesList.map((values) => values.join(', ')).join('),\n    (');

    final query = """
      WITH input_values ($insertColumns) AS (
        VALUES ($inputValues)
      ), inserted_rows AS (
        INSERT INTO $tableName ($insertColumns)
        SELECT $insertColumnsWithTypes FROM input_values
        ON CONFLICT ($quotedOnConflicts) DO NOTHING
        RETURNING id, $insertColumns
      ), ${skipUpdate ? '' : '''updated_rows AS (
        UPDATE $tableName
          SET $updateSetList FROM input_values
        WHERE $updateWhere
          $distinctOrConditions
          AND NOT EXISTS (
            SELECT 1 FROM inserted_rows WHERE $updateWhereNotExistsInserted
          )
        RETURNING id, $insertColumns
      ),'''} unchanged_rows AS (
        SELECT id, $insertColumnsForCompareWithJsonB FROM $tableName
          WHERE ($quotedOnConflicts) IN
            (SELECT $quotedOnConflicts FROM input_values)
        EXCEPT (
          SELECT id, $insertColumnsForCompareWithJsonB FROM inserted_rows
          ${skipUpdate ? '' : 'UNION ALL SELECT * FROM updated_rows'}
        )
      ), results AS (
        $selectResultsUnion
      )
      SELECT * FROM results;
    """;

    try {
      var databaseConnection = await session.db.databaseConnection;

      var context = transaction != null
          ? transaction.postgresContext
          : databaseConnection.postgresConnection;

      // print('query = $query');

      var result = await context.mappedResultsQuery(
        query,
        allowReuse: false,
        timeoutInSeconds: 60,
        substitutionValues: {},
      );

      // print('result = $result');

      for (var rawRow in result) {
        final value = rawRow.values.first;
        final returnType = UpsertReturnType.fromJson(value['returnType'])!;
        final row = formatTableRow<T>(
            session.serverpod.serializationManager, tableName, value);
        if (row == null) continue;
        resultsMap[returnType] = [
          ...resultsMap[returnType] ?? [],
          row,
        ];
      }
    } catch (e, trace) {
      logQuery(session, query, startTime, exception: e, trace: trace);
      rethrow;
    }

    logQuery(session, query, startTime, numRowsAffected: resultsMap.length);
  }

  print(
      '\tresults: ${resultsMap.keys.map((type) => '${resultsMap[type]!.length} ${type.name}').join(', ')}');

  return resultsMap;
}
