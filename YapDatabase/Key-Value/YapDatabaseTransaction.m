#import "YapDatabaseTransaction.h"
#import "YapDatabasePrivate.h"
#import "YapAbstractDatabaseExtensionPrivate.h"
#import "YapDatabaseString.h"
#import "YapDatabaseLogging.h"
#import "YapCache.h"
#import "YapNull.h"

#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

/**
 * Define log level for this file: OFF, ERROR, WARN, INFO, VERBOSE
 * See YapDatabaseLogging.h for more information.
**/
#if DEBUG
  static const int ydbLogLevel = YDB_LOG_LEVEL_INFO;
#else
  static const int ydbLogLevel = YDB_LOG_LEVEL_WARN;
#endif


@implementation YapDatabaseReadTransaction {
	
/* From YapAbstractDatabasePrivate.h & YapDatabasePrivate.h :

@protected
    BOOL isMutated; // Used for "mutation during enumeration" protection

@public
	BOOL isReadWriteTransaction;
	__unsafe_unretained YapDatabaseConnection *connection;
 
*/
}

- (id)initWithConnection:(YapAbstractDatabaseConnection *)aConnection isReadWriteTransaction:(BOOL)flag
{
	if ((self = [super initWithConnection:aConnection isReadWriteTransaction:flag]))
	{
		connection = (YapDatabaseConnection *)aConnection;
	}
	return self;
}

@synthesize connection = connection;

#pragma mark Count

- (NSUInteger)numberOfKeys
{
	sqlite3_stmt *statement = [connection getCountStatement];
	if (statement == NULL) return 0;
	
	NSUInteger result = 0;
	
	int status = sqlite3_step(statement);
	if (status == SQLITE_ROW)
	{
		if (connection->needsMarkSqlLevelSharedReadLock)
			[connection markSqlLevelSharedReadLockAcquired];
		
		result = (NSUInteger)sqlite3_column_int64(statement, 0);
	}
	else if (status == SQLITE_ERROR)
	{
		YDBLogError(@"Error executing 'getDataForKeyStatement': %d %s",
		                                                    status, sqlite3_errmsg(connection->db));
	}
	
	sqlite3_reset(statement);
	
	return result;
}

#pragma mark List

- (NSArray *)allKeys
{
	sqlite3_stmt *statement = [connection enumerateKeysStatement];
	if (statement == NULL) return nil;
	
	// SELECT "key" FROM "database";
	
	__block NSMutableArray *keys = [[NSMutableArray alloc] init];
	
	while (sqlite3_step(statement) == SQLITE_ROW)
	{
		if (connection->needsMarkSqlLevelSharedReadLock)
			[connection markSqlLevelSharedReadLockAcquired];
		
		const unsigned char *text = sqlite3_column_text(statement, 0);
		int textSize = sqlite3_column_bytes(statement, 0);
		
		NSString *key = [[NSString alloc] initWithBytes:text length:textSize encoding:NSUTF8StringEncoding];
		
		[keys addObject:key];
	}
	
	sqlite3_reset(statement);
	
	return keys;
}

#pragma mark Primitive

- (NSData *)primitiveDataForKey:(NSString *)key
{
	if (key == nil) return nil;
	
	sqlite3_stmt *statement = [connection getDataForKeyStatement];
	if (statement == NULL) return nil;
	
	// SELECT "data" FROM "database" WHERE "key" = ? ;
	
	YapDatabaseString _key; MakeYapDatabaseString(&_key, key);
	sqlite3_bind_text(statement, 1, _key.str, _key.length, SQLITE_STATIC);
	
	NSData *result = nil;
	
	int status = sqlite3_step(statement);
	if (status == SQLITE_ROW)
	{
		if (connection->needsMarkSqlLevelSharedReadLock)
			[connection markSqlLevelSharedReadLockAcquired];
		
		const void *blob = sqlite3_column_blob(statement, 0);
		int blobSize = sqlite3_column_bytes(statement, 0);
		
		result = [[NSData alloc] initWithBytes:blob length:blobSize];
	}
	else if (status == SQLITE_ERROR)
	{
		YDBLogError(@"Error executing 'getDataForKeyStatement': %d %s, key(%@)",
				   status, sqlite3_errmsg(connection->db), key);
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_key);
	
	return result;
}

#pragma mark Object

- (id)objectForKey:(NSString *)key
{
	if (key == nil) return nil;
	
	id object = [connection->objectCache objectForKey:key];
	if (object)
		return object;
	
	sqlite3_stmt *statement = [connection getDataForKeyStatement];
	if (statement == NULL) return nil;
	
	// SELECT data FROM 'database' WHERE key = ? ;
	
	YapDatabaseString _key; MakeYapDatabaseString(&_key, key);
	sqlite3_bind_text(statement, 1, _key.str, _key.length, SQLITE_STATIC);
	
	int status = sqlite3_step(statement);
	if (status == SQLITE_ROW)
	{
		if (connection->needsMarkSqlLevelSharedReadLock)
			[connection markSqlLevelSharedReadLockAcquired];
		
		const void *blob = sqlite3_column_blob(statement, 0);
		int blobSize = sqlite3_column_bytes(statement, 0);
		
		// Performance tuning:
		//
		// Use initWithBytesNoCopy to avoid an extra allocation and memcpy.
		// But be sure not to call sqlite3_reset until we're done with the data.
		
		NSData *oData = [[NSData alloc] initWithBytesNoCopy:(void *)blob length:blobSize freeWhenDone:NO];
		object = connection->database->objectDeserializer(oData);
	}
	else if (status == SQLITE_ERROR)
	{
		YDBLogError(@"Error executing 'getDataForKeyStatement': %d %s, key(%@)",
				   status, sqlite3_errmsg(connection->db), key);
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_key);
	
	if (object)
		[connection->objectCache setObject:object forKey:[key copy]]; // mutable string protection
	
	return object;
}

- (BOOL)hasObjectForKey:(NSString *)key
{
	if (key == nil) return NO;
	
	// Shortcut:
	// We may not need to query the database if we have the key in any of our caches.
	
	if ([connection->metadataCache objectForKey:key]) return YES;
	if ([connection->objectCache objectForKey:key]) return YES;
	
	// The normal SQL way
	
	sqlite3_stmt *statement = [connection getCountForKeyStatement];
	if (statement == NULL) return NO;
	
	// SELECT COUNT(*) AS NumberOfRows FROM "database" WHERE "key" = ?;
	
	YapDatabaseString _key; MakeYapDatabaseString(&_key, key);
	sqlite3_bind_text(statement, 1, _key.str, _key.length, SQLITE_STATIC);
	
	BOOL result = NO;
	
	int status = sqlite3_step(statement);
	if (status == SQLITE_ROW)
	{
		if (connection->needsMarkSqlLevelSharedReadLock)
			[connection markSqlLevelSharedReadLockAcquired];
		
		result = (sqlite3_column_int64(statement, 0) > 0);
	}
	else if (status == SQLITE_ERROR)
	{
		YDBLogError(@"Error executing 'getCountForKeyStatement': %d %s, key(%@)",
		                                                     status, sqlite3_errmsg(connection->db), key);
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_key);
	
	return result;
}

- (BOOL)getObject:(id *)objectPtr metadata:(id *)metadataPtr forKey:(NSString *)key
{
	if (key == nil)
	{
		if (objectPtr) *objectPtr = nil;
		if (metadataPtr) *metadataPtr = nil;
		
		return NO;
	}
	
	id object = [connection->objectCache objectForKey:key];
	id metadata = [connection->metadataCache objectForKey:key];
	
	if (object && metadata)
	{
		// Both object and metadata were in cache.
		// Just need to check for empty metadata placeholder from cache.
		if (metadata == [YapNull null])
			metadata = nil;
	}
	else if (!object && metadata)
	{
		// Metadata was in cache.
		// Missing object. Fetch individually.
		object = [self objectForKey:key];
		
		// And check for empty metadata placeholder from cache.
		if (metadata == [YapNull null])
			metadata = nil;
	}
	else if (object && !metadata)
	{
		// Object was in cache.
		// Missing metadata. Fetch individually.
		metadata = [self metadataForKey:key];
	}
	else // (!object && !metadata)
	{
		// Both object and metadata are missing.
		// Fetch via query.
		
		sqlite3_stmt *statement = [connection getAllForKeyStatement];
		if (statement)
		{
			// SELECT "data", "metadata" FROM "database" WHERE "key" = ? ;
			
			YapDatabaseString _key; MakeYapDatabaseString(&_key, key);
			sqlite3_bind_text(statement, 1, _key.str, _key.length, SQLITE_STATIC);
			
			int status = sqlite3_step(statement);
			if (status == SQLITE_ROW)
			{
				if (connection->needsMarkSqlLevelSharedReadLock)
					[connection markSqlLevelSharedReadLockAcquired];
				
				const void *oBlob = sqlite3_column_blob(statement, 0);
				int oBlobSize = sqlite3_column_bytes(statement, 0);
				
				const void *mBlob = sqlite3_column_blob(statement, 1);
				int mBlobSize = sqlite3_column_bytes(statement, 1);
				
				NSData *oData, *mData;
				
				oData = [[NSData alloc] initWithBytesNoCopy:(void *)oBlob length:oBlobSize freeWhenDone:NO];
				object = connection->database->objectDeserializer(oData);
				
				if (mBlobSize > 0)
				{
					mData = [[NSData alloc] initWithBytesNoCopy:(void *)mBlob length:mBlobSize freeWhenDone:NO];
					metadata = connection->database->metadataDeserializer(mData);
				}
			}
			else if (status == SQLITE_ERROR)
			{
				YDBLogError(@"Error executing 'getAllForKeyStatement': %d %s",
				                                                   status, sqlite3_errmsg(connection->db));
			}
			
			if (object)
			{
				key = [key copy]; // mutable string protection
				
				[connection->objectCache setObject:object forKey:key];
			
				if (metadata)
					[connection->metadataCache setObject:metadata forKey:key];
				else
					[connection->metadataCache setObject:[YapNull null] forKey:key];
			}
			
			sqlite3_clear_bindings(statement);
			sqlite3_reset(statement);
			FreeYapDatabaseString(&_key);
		}
	}
	
	if (objectPtr) *objectPtr = object;
	if (metadataPtr) *metadataPtr = metadata;
	
	return (object != nil || metadata != nil);
}

#pragma mark Metadata

- (id)metadataForKey:(NSString *)key
{
	if (key == nil) return nil;
	
	id metadata = [connection->metadataCache objectForKey:key];
	if (metadata)
	{
		if (metadata == [YapNull null])
			return nil;
		else
			return metadata;
	}
	
	sqlite3_stmt *statement = [connection getMetadataForKeyStatement];
	if (statement == NULL) return nil;
	
	// SELECT "metadata" FROM "database" WHERE "key" = ? ;
	
	YapDatabaseString _key; MakeYapDatabaseString(&_key, key);
	sqlite3_bind_text(statement, 1, _key.str, _key.length, SQLITE_STATIC);
	
	BOOL found = NO;
	NSData *metadataData = nil;
	
	int status = sqlite3_step(statement);
	if (status == SQLITE_ROW)
	{
		if (connection->needsMarkSqlLevelSharedReadLock)
			[connection markSqlLevelSharedReadLockAcquired];
		
		found = YES;
		
		const void *blob = sqlite3_column_blob(statement, 0);
		int blobSize = sqlite3_column_bytes(statement, 0);
		
		// Performance tuning:
		//
		// Use initWithBytesNoCopy to avoid an extra allocation and memcpy.
		// But be sure not to call sqlite3_reset until we're done with the data.
		
		if (blobSize > 0)
			metadataData = [[NSData alloc] initWithBytesNoCopy:(void *)blob length:blobSize freeWhenDone:NO];
	}
	else if (status == SQLITE_ERROR)
	{
		YDBLogError(@"Error executing 'getMetadataForKeyStatement': %d %s",
		                                                        status, sqlite3_errmsg(connection->db));
	}
	
	if (found)
	{
		if (metadataData)
			metadata = connection->database->metadataDeserializer(metadataData);
		
		if (metadata)
			[connection->metadataCache setObject:metadata forKey:[key copy]];       // mutable string protection
		else
			[connection->metadataCache setObject:[YapNull null] forKey:[key copy]]; // mutable string protection
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_key);
	
	return metadata;
}

#pragma mark Enumerate

/**
 * Fast enumeration over all keys in the database.
 *
 * This uses a "SELECT key FROM database" operation, and then steps over the results
 * and invoking the given block handler.
**/
- (void)enumerateKeysUsingBlock:(void (^)(NSString *key, BOOL *stop))block
{
	if (block == NULL) return;
	
	sqlite3_stmt *statement = [connection enumerateKeysStatement];
	if (statement == NULL) return;
	
	BOOL stop = NO;
	isMutated = NO; // mutation during enumeration protection
	
	// SELECT "key" FROM "database";
	
	int status;
	while ((status = sqlite3_step(statement)) == SQLITE_ROW)
	{
		if (connection->needsMarkSqlLevelSharedReadLock)
			[connection markSqlLevelSharedReadLockAcquired];
		
		const unsigned char *text = sqlite3_column_text(statement, 0);
		int textSize = sqlite3_column_bytes(statement, 0);
		
		NSString *key = [[NSString alloc] initWithBytes:text length:textSize encoding:NSUTF8StringEncoding];
		
		block(key, &stop);
		
		if (stop || isMutated) break;
	}
	
	if ((status != SQLITE_DONE) && !stop && !isMutated)
	{
		YDBLogError(@"%@ - sqlite_step error: %d %s", THIS_METHOD, status, sqlite3_errmsg(connection->db));
	}
	
	sqlite3_reset(statement);
	
	if (isMutated && !stop)
	{
		@throw [self mutationDuringEnumerationException];
	}
}

/**
 * Enumerates over the given list of keys (unordered), and fetches the associated metadata.
 * 
 * This method is faster than metadataForKey when fetching multiple items, as it optimizes cache access.
 * That is, it will first enumerate over cached items and then fetch items from the database,
 * thus optimizing the cache and reducing the query size.
 *
 * If any keys are missing from the database, the 'metadata' parameter will be nil.
 *
 * IMPORTANT:
 * Due to various optimizations, the items may not be enumerated in the same order as the 'keys' parameter.
**/
- (void)enumerateMetadataForKeys:(NSArray *)keys
             unorderedUsingBlock:(void (^)(NSUInteger keyIndex, id metadata, BOOL *stop))block
{
	if (block == NULL) return;
	if ([keys count] == 0) return;
	
	BOOL stop = NO;
	isMutated = NO; // mutation during enumeration protection
	
	// Check the cache first (to optimize cache)
	
	NSMutableArray *missingIndexes = [NSMutableArray arrayWithCapacity:[keys count]];
	
	NSUInteger keyIndex = 0;
	
	for (NSString *key in keys)
	{
		id metadata = [connection->metadataCache objectForKey:key];
		if (metadata)
		{
			if (metadata == [YapNull null])
				block(keyIndex, nil, &stop);
			else
				block(keyIndex, metadata, &stop);
			
			if (stop || isMutated) break;
		}
		else
		{
			[missingIndexes addObject:@(keyIndex)];
		}
				  
		keyIndex++;
	}
	
	if (stop) {
		return;
	}
	if (isMutated) {
		@throw [self mutationDuringEnumerationException];
		return;
	}
	if ([missingIndexes count] == 0) {
		return;
	}
	
	// Go to database for any missing keys (if needed)
	
	// Sqlite has an upper bound on the number of host parameters that may be used in a single query.
	// We need to watch out for this in case a large array of keys is passed.
	
	NSUInteger maxHostParams = (NSUInteger) sqlite3_limit(connection->db, SQLITE_LIMIT_VARIABLE_NUMBER, -1);
	
	do
	{
		// Determine how many parameters to use in the query
		
		NSUInteger numHostParams = MIN([missingIndexes count], maxHostParams);
		
		// Create the SQL query:
		// SELECT "key", "metadata" FROM "database" WHERE key IN (?, ?, ...);
		
		NSUInteger capacity = 80 + (numHostParams * 3);
		NSMutableString *query = [NSMutableString stringWithCapacity:capacity];
		
		[query appendString:@"SELECT \"key\", \"metadata\" FROM \"database\" WHERE \"key\" IN ("];
		
		NSUInteger i;
		for (i = 0; i < numHostParams; i++)
		{
			if (i == 0)
				[query appendFormat:@"?"];
			else
				[query appendFormat:@", ?"];
		}
		
		[query appendString:@");"];
		
		sqlite3_stmt *statement;
		
		int status = sqlite3_prepare_v2(connection->db, [query UTF8String], -1, &statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating 'objectsForKeys' statement: %d %s",
						status, sqlite3_errmsg(connection->db));
			return;
		}
		
		// Bind parameters.
		// And move objects from the missingIndexes array into keyIndexDict.
		
		NSMutableDictionary *keyIndexDict = [NSMutableDictionary dictionaryWithCapacity:numHostParams];
		
		for (i = 0; i < numHostParams; i++)
		{
			NSNumber *keyIndexNumber = [missingIndexes objectAtIndex:i];
			NSString *key = [keys objectAtIndex:[keyIndexNumber unsignedIntegerValue]];
			
			[keyIndexDict setObject:keyIndexNumber forKey:key];
			
			sqlite3_bind_text(statement, (int)(i + 1), [key UTF8String], -1, SQLITE_TRANSIENT);
		}
		
		[missingIndexes removeObjectsInRange:NSMakeRange(0, numHostParams)];
		
		// Execute the query and step over the results
		
		while ((status = sqlite3_step(statement)) == SQLITE_ROW)
		{
			if (connection->needsMarkSqlLevelSharedReadLock)
				[connection markSqlLevelSharedReadLockAcquired];
			
			const unsigned char *text = sqlite3_column_text(statement, 0);
			int textSize = sqlite3_column_bytes(statement, 0);
			
			const void *blob = sqlite3_column_blob(statement, 1);
			int blobSize = sqlite3_column_bytes(statement, 1);
			
			NSString *key = [[NSString alloc] initWithBytes:text length:textSize encoding:NSUTF8StringEncoding];
			NSUInteger keyIndex = [[keyIndexDict objectForKey:key] unsignedIntegerValue];
			
			NSData *metadataData = [[NSData alloc] initWithBytesNoCopy:(void *)blob length:blobSize freeWhenDone:NO];
			
			id metadata = metadataData ? connection->database->metadataDeserializer(metadataData) : nil;
			
			if (metadata)
				[connection->metadataCache setObject:metadata forKey:key];       // key is immutable
			else
				[connection->metadataCache setObject:[YapNull null] forKey:key]; // key is immutable
			
			block(keyIndex, metadata, &stop);
			
			[keyIndexDict removeObjectForKey:key];
			
			if (stop || isMutated) break;
		}
		
		if ((status != SQLITE_DONE) && !stop && !isMutated)
		{
			YDBLogError(@"%@ - sqlite_step error: %d %s", THIS_METHOD, status, sqlite3_errmsg(connection->db));
		}
		
		sqlite3_finalize(statement);
		statement = NULL;
		
		if (stop) {
			return;
		}
		if (isMutated) {
			@throw [self mutationDuringEnumerationException];
			return;
		}
		
		// If there are any remaining items in the keyIndexDict,
		// then those items didn't exist in the database.
		
		for (NSNumber *keyIndexNumber in [keyIndexDict objectEnumerator])
		{
			NSUInteger keyIndex = [keyIndexNumber unsignedIntegerValue];
			block(keyIndex, nil, &stop);
			
			// Do NOT add keys to the cache that don't exist in the database.
			
			if (stop || isMutated) break;
		}
		
		if (stop) {
			return;
		}
		if (isMutated) {
			@throw [self mutationDuringEnumerationException];
			return;
		}
		
		
	} while ([missingIndexes count] > 0);
}

/**
 * Enumerates over the given list of keys (unordered), and fetches the associated objects.
 *
 * This method is faster than objectForKey when fetching multiple items, as it optimizes cache access.
 * That is, it will first enumerate over cached items and then fetch items from the database,
 * thus optimizing the cache and reducing the query size.
 *
 * If any keys are missing from the database, the 'object' parameter will be nil.
 * 
 * IMPORTANT:
 * Due to various optimizations, the items may not be enumerated in the same order as the 'keys' parameter.
**/
- (void)enumerateObjectsForKeys:(NSArray *)keys
            unorderedUsingBlock:(void (^)(NSUInteger keyIndex, id object, BOOL *stop))block
{
	if (block == NULL) return;
	if ([keys count] == 0) return;
	
	BOOL stop = NO;
	isMutated = NO; // mutation during enumeration protection
	
	// Check the cache first (to optimize cache)
	
	NSMutableArray *missingIndexes = [NSMutableArray arrayWithCapacity:[keys count]];
	NSUInteger keyIndex = 0;
	
	for (NSString *key in keys)
	{
		id object = [connection->objectCache objectForKey:key];
		if (object)
		{
			block(keyIndex, object, &stop);
			
			if (stop || isMutated) break;
		}
		else
		{
			[missingIndexes addObject:@(keyIndex)];
		}
				  
		keyIndex++;
	}
	
	if (stop) {
		return;
	}
	if (isMutated) {
		@throw [self mutationDuringEnumerationException];
		return;
	}
	if ([missingIndexes count] == 0) {
		return;
	}
	
	// Go to database for any missing keys (if needed)
	
	// Sqlite has an upper bound on the number of host parameters that may be used in a single query.
	// We need to watch out for this in case a large array of keys is passed.
	
	NSUInteger maxHostParams = (NSUInteger) sqlite3_limit(connection->db, SQLITE_LIMIT_VARIABLE_NUMBER, -1);
	
	do
	{
		// Determine how many parameters to use in the query
		
		NSUInteger numHostParams = MIN([missingIndexes count], maxHostParams);
		
		// Create the SQL query:
		// SELECT "key", "data" FROM "database" WHERE key IN (?, ?, ...);
		
		NSUInteger capacity = 80 + (numHostParams * 3);
		NSMutableString *query = [NSMutableString stringWithCapacity:capacity];
		
		[query appendString:@"SELECT \"key\", \"data\" FROM \"database\" WHERE \"key\" IN ("];
		
		NSUInteger i;
		for (i = 0; i < numHostParams; i++)
		{
			if (i == 0)
				[query appendFormat:@"?"];
			else
				[query appendFormat:@", ?"];
		}
		
		[query appendString:@");"];
		
		sqlite3_stmt *statement;
		
		int status = sqlite3_prepare_v2(connection->db, [query UTF8String], -1, &statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating 'objectsForKeys' statement: %d %s",
						status, sqlite3_errmsg(connection->db));
			return;
		}
		
		// Bind parameters.
		// And move objects from the missingIndexes array into keyIndexDict.
		
		NSMutableDictionary *keyIndexDict = [NSMutableDictionary dictionaryWithCapacity:numHostParams];
		
		for (i = 0; i < numHostParams; i++)
		{
			NSNumber *keyIndexNumber = [missingIndexes objectAtIndex:i];
			NSString *key = [keys objectAtIndex:[keyIndexNumber unsignedIntegerValue]];
			
			[keyIndexDict setObject:keyIndexNumber forKey:key];
			
			sqlite3_bind_text(statement, (int)(i + 1), [key UTF8String], -1, SQLITE_TRANSIENT);
		}
		
		[missingIndexes removeObjectsInRange:NSMakeRange(0, numHostParams)];
		
		// Execute the query and step over the results
		
		while ((status = sqlite3_step(statement)) == SQLITE_ROW)
		{
			if (connection->needsMarkSqlLevelSharedReadLock)
				[connection markSqlLevelSharedReadLockAcquired];
			
			const unsigned char *text = sqlite3_column_text(statement, 0);
			int textSize = sqlite3_column_bytes(statement, 0);
			
			const void *blob = sqlite3_column_blob(statement, 1);
			int blobSize = sqlite3_column_bytes(statement, 1);
			
			NSString *key = [[NSString alloc] initWithBytes:text length:textSize encoding:NSUTF8StringEncoding];
			NSUInteger keyIndex = [[keyIndexDict objectForKey:key] unsignedIntegerValue];
			
			NSData *objectData = [[NSData alloc] initWithBytesNoCopy:(void *)blob length:blobSize freeWhenDone:NO];
			id object = connection->database->objectDeserializer(objectData);
			
			if (object) {
				[connection->objectCache setObject:object forKey:key]; // key is immutable
			}
			
			block(keyIndex, object, &stop);
			
			[keyIndexDict removeObjectForKey:key];
			
			if (stop || isMutated) break;
		}
		
		if ((status != SQLITE_DONE) && !stop && !isMutated)
		{
			YDBLogError(@"%@ - sqlite_step error: %d %s", THIS_METHOD, status, sqlite3_errmsg(connection->db));
		}
		
		sqlite3_finalize(statement);
		statement = NULL;
		
		if (stop) {
			return;
		}
		if (isMutated) {
			@throw [self mutationDuringEnumerationException];
			return;
		}
		
		// If there are any remaining items in the keyIndexDict,
		// then those items didn't exist in the database.
		
		for (NSNumber *keyIndexNumber in [keyIndexDict objectEnumerator])
		{
			NSUInteger keyIndex = [keyIndexNumber unsignedIntegerValue];
			block(keyIndex, nil, &stop);
			
			// Do NOT add keys to the cache that don't exist in the database.
			
			if (stop || isMutated) break;
		}
		
		if (stop) {
			return;
		}
		if (isMutated) {
			@throw [self mutationDuringEnumerationException];
			return;
		}
		
		
	} while ([missingIndexes count] > 0);
}

/**
 * Enumerates over the given list of keys (unordered), and fetches the associated rows.
 *
 * This method is faster than fetching items one-by-one as it optimizes cache access.
 * That is, it will first enumerate over cached items and then fetch items from the database,
 * thus optimizing the cache and reducing the query size.
 *
 * If any keys are missing from the database, the 'object' parameter will be nil.
 * 
 * IMPORTANT:
 * Due to various optimizations, the items may not be enumerated in the same order as the 'keys' parameter.
**/
- (void)enumerateRowsForKeys:(NSArray *)keys
         unorderedUsingBlock:(void (^)(NSUInteger keyIndex, id object, id metadata, BOOL *stop))block
{
	if (block == NULL) return;
	if ([keys count] == 0) return;
	
	BOOL stop = NO;
	isMutated = NO; // mutation during enumeration protection
	
	// Check the cache first (to optimize cache)
	
	NSMutableArray *missingIndexes = [NSMutableArray arrayWithCapacity:[keys count]];
	NSUInteger keyIndex = 0;
	
	for (NSString *key in keys)
	{
		id object = [connection->objectCache objectForKey:key];
		if (object)
		{
			id metadata = [connection->metadataCache objectForKey:key];
			if (metadata)
			{
				if (metadata == [YapNull null])
					block(keyIndex, object, nil, &stop);
				else
					block(keyIndex, object, metadata, &stop);
				
				if (stop || isMutated) break;
			}
			else
			{
				[missingIndexes addObject:@(keyIndex)];
			}
		}
		else
		{
			[missingIndexes addObject:@(keyIndex)];
		}
		
		keyIndex++;
	}
	
	if (stop) {
		return;
	}
	if (isMutated) {
		@throw [self mutationDuringEnumerationException];
		return;
	}
	if ([missingIndexes count] == 0) {
		return;
	}
	
	// Go to database for any missing keys (if needed)
	
	// Sqlite has an upper bound on the number of host parameters that may be used in a single query.
	// We need to watch out for this in case a large array of keys is passed.
	
	NSUInteger maxHostParams = (NSUInteger) sqlite3_limit(connection->db, SQLITE_LIMIT_VARIABLE_NUMBER, -1);
	
	do
	{
		// Determine how many parameters to use in the query
		
		NSUInteger numHostParams = MIN([missingIndexes count], maxHostParams);
		
		// Create the SQL query:
		// SELECT "key", "data", "metadata" FROM "database" WHERE key IN (?, ?, ...);
		
		NSUInteger capacity = 80 + (numHostParams * 3);
		NSMutableString *query = [NSMutableString stringWithCapacity:capacity];
		
		[query appendString:@"SELECT \"key\", \"data\", \"metadata\" FROM \"database\" WHERE \"key\" IN ("];
		
		NSUInteger i;
		for (i = 0; i < numHostParams; i++)
		{
			if (i == 0)
				[query appendFormat:@"?"];
			else
				[query appendFormat:@", ?"];
		}
		
		[query appendString:@");"];
		
		sqlite3_stmt *statement;
		
		int status = sqlite3_prepare_v2(connection->db, [query UTF8String], -1, &statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating 'objectsForKeys' statement: %d %s",
						status, sqlite3_errmsg(connection->db));
			return;
		}
		
		// Bind parameters.
		// And move objects from the missingIndexes array into keyIndexDict.
		
		NSMutableDictionary *keyIndexDict = [NSMutableDictionary dictionaryWithCapacity:numHostParams];
		
		for (i = 0; i < numHostParams; i++)
		{
			NSNumber *keyIndexNumber = [missingIndexes objectAtIndex:i];
			NSString *key = [keys objectAtIndex:[keyIndexNumber unsignedIntegerValue]];
			
			[keyIndexDict setObject:keyIndexNumber forKey:key];
			
			sqlite3_bind_text(statement, (int)(i + 1), [key UTF8String], -1, SQLITE_TRANSIENT);
		}
		
		[missingIndexes removeObjectsInRange:NSMakeRange(0, numHostParams)];
		
		// Execute the query and step over the results
		
		while ((status = sqlite3_step(statement)) == SQLITE_ROW)
		{
			if (connection->needsMarkSqlLevelSharedReadLock)
				[connection markSqlLevelSharedReadLockAcquired];
			
			const unsigned char *text = sqlite3_column_text(statement, 0);
			int textSize = sqlite3_column_bytes(statement, 0);
			
			NSString *key = [[NSString alloc] initWithBytes:text length:textSize encoding:NSUTF8StringEncoding];
			NSUInteger keyIndex = [[keyIndexDict objectForKey:key] unsignedIntegerValue];
			
			id object = [connection->objectCache objectForKey:key];
			if (object == nil)
			{
				const void *oBlob = sqlite3_column_blob(statement, 1);
				int oBlobSize = sqlite3_column_bytes(statement, 1);
				
				NSData *oData = [[NSData alloc] initWithBytesNoCopy:(void *)oBlob length:oBlobSize freeWhenDone:NO];
				object = connection->database->objectDeserializer(oData);
			}
			
			id metadata = [connection->metadataCache objectForKey:key];
			if (metadata)
			{
				if (metadata == [YapNull null])
					metadata = nil;
			}
			else
			{
				const void *mBlob = sqlite3_column_blob(statement, 2);
				int mBlobSize = sqlite3_column_bytes(statement, 2);
				
				NSData *mData = [[NSData alloc] initWithBytesNoCopy:(void *)mBlob length:mBlobSize freeWhenDone:NO];
				metadata = connection->database->metadataDeserializer(mData);
			}
			
			if (object)
			{
				[connection->objectCache setObject:object forKey:key]; // key is immutable
				
				if (metadata)
					[connection->metadataCache setObject:metadata forKey:key];       // key is immutable
				else
					[connection->metadataCache setObject:[YapNull null] forKey:key]; // key is immutable
			}
			
			block(keyIndex, object, metadata, &stop);
			
			[keyIndexDict removeObjectForKey:key];
			
			if (stop || isMutated) break;
		}
		
		if ((status != SQLITE_DONE) && !stop && !isMutated)
		{
			YDBLogError(@"%@ - sqlite_step error: %d %s", THIS_METHOD, status, sqlite3_errmsg(connection->db));
		}
		
		sqlite3_finalize(statement);
		statement = NULL;
		
		if (stop) {
			return;
		}
		if (isMutated) {
			@throw [self mutationDuringEnumerationException];
			return;
		}
		
		// If there are any remaining items in the keyIndexDict,
		// then those items didn't exist in the database.
		
		for (NSNumber *keyIndexNumber in [keyIndexDict objectEnumerator])
		{
			NSUInteger keyIndex = [keyIndexNumber unsignedIntegerValue];
			block(keyIndex, nil, nil, &stop);
			
			// Do NOT add keys to the cache that don't exist in the database.
			
			if (stop || isMutated) break;
		}
		
		if (stop) {
			return;
		}
		if (isMutated) {
			@throw [self mutationDuringEnumerationException];
			return;
		}
		
		
	} while ([missingIndexes count] > 0);
}

/**
 * Fast enumeration over all keys and metadata in the database.
 *
 * This uses a "SELECT key, metadata FROM database" operation, and then steps over the results,
 * deserializing each metadata (if not cached), and invoking the given block handler.
 *
 * If you only need to enumerate over certain metadata rows (e.g. keys with a particular prefix),
 * consider using the alternative version below which provide a filter,
 * allowing you to skip the deserialization step for those rows you're not interested in.
**/
- (void)enumerateKeysAndMetadataUsingBlock:(void (^)(NSString *key, id metadata, BOOL *stop))block
{
	return [self enumerateKeysAndMetadataUsingBlock:block withFilter:NULL];
}

/**
 * Fast enumeration over all keys and metadata in the database for which you're interested in.
 * The filter block allows you to decide which rows you're interested in,
 * allowing you to skip the deserialization step for ignored rows.
 *
 * From the filter block, simply return YES if you'd like the block handler to be invoked for given row.
 * If the filter block returns NO, then the block handler is skipped for the given row,
 * which avoids the cost associated with deserialization process.
 **/
- (void)enumerateKeysAndMetadataUsingBlock:(void (^)(NSString *key, id metadata, BOOL *stop))block
                                withFilter:(BOOL (^)(NSString *key))filter
{
	if (block == NULL) return;
	
	sqlite3_stmt *statement = [connection enumerateKeysAndMetadataStatement];
	if (statement == NULL) return;
	
	isMutated = NO; // mutation during enumeration protection
	
	// SELECT "key", "metadata" FROM "database";
	//
	// Performance tuning:
	// Use initWithBytesNoCopy to avoid an extra allocation and memcpy.
	//
	// Cache considerations:
	// Do we want to add the objects/metadata to the cache here?
	// If the cache is unlimited then we should.
	// Otherwise we should only add to the cache if its not full.
	// The cache should generally be reserved for items that are explicitly fetched,
	// and we don't want to crowd them out during enumerations.
	
	BOOL stop = NO;
	BOOL unlimitedMetadataCacheLimit = (connection->metadataCacheLimit == 0);
	
	int status;
	while ((status = sqlite3_step(statement)) == SQLITE_ROW)
	{
		if (connection->needsMarkSqlLevelSharedReadLock)
			[connection markSqlLevelSharedReadLockAcquired];
		
		const unsigned char *text = sqlite3_column_text(statement, 0);
		int textSize = sqlite3_column_bytes(statement, 0);
		
		NSString *key = [[NSString alloc] initWithBytes:text length:textSize encoding:NSUTF8StringEncoding];
		
		BOOL invokeBlock = filter == NULL ? YES : filter(key);
		if (invokeBlock)
		{
			id metadata = [connection->metadataCache objectForKey:key];
			if (metadata)
			{
				if (metadata == [YapNull null])
					metadata = nil;
			}
			else
			{
				const void *mBlob = sqlite3_column_blob(statement, 1);
				int mBlobSize = sqlite3_column_bytes(statement, 1);
				
				if (mBlobSize > 0)
				{
					NSData *mData = [[NSData alloc] initWithBytesNoCopy:(void *)mBlob length:mBlobSize freeWhenDone:NO];
					metadata = connection->database->metadataDeserializer(mData);
				}
				
				if (unlimitedMetadataCacheLimit || [connection->metadataCache count] < connection->metadataCacheLimit)
				{
					if (metadata)
						[connection->metadataCache setObject:metadata forKey:key];
					else
						[connection->metadataCache setObject:[YapNull null] forKey:key];
				}
			}
			
			block(key, metadata, &stop);
			
			if (stop || isMutated) break;
		}
	}
	
	if ((status != SQLITE_DONE) && !stop && !isMutated)
	{
		YDBLogError(@"%@ - sqlite_step error: %d %s", THIS_METHOD, status, sqlite3_errmsg(connection->db));
	}
	
	sqlite3_reset(statement);
	
	if (isMutated && !stop)
	{
		@throw [self mutationDuringEnumerationException];
	}
}

/**
 * Fast enumeration over all objects in the database.
 *
 * This uses a "SELECT key, object FROM database" operation, and then steps over the results,
 * deserializing each object and metadata (if not cached), and then invoking the given block handler.
 *
 * If you only need to enumerate over certain objects (e.g. keys with a particular prefix),
 * consider using the alternative versions below which provide a filter,
 * allowing you to skip the serialization steps for those rows you're not interested in.
**/
- (void)enumerateKeysAndObjectsUsingBlock:(void (^)(NSString *key, id object, BOOL *stop))block
{
	[self enumerateKeysAndObjectsUsingBlock:block withFilter:NULL];
}

/**
 * Fast enumeration over objects in the database for which you're interested in.
 * The filter block allows you to specify which objects you're interested in,
 * allowing you to skip the deserialization step for ignored rows.
 *
 * From the filter block, simply return YES if you'd like the block handler to be invoked for the given row.
 * If the filter block returns NO, then the block handler is skipped for the given row,
 * which avoids the cost associated with deserialization process.
**/
- (void)enumerateKeysAndObjectsUsingBlock:(void (^)(NSString *key, id object, BOOL *stop))block
                               withFilter:(BOOL (^)(NSString *key))filter
{
	if (block == NULL) return;
	
	sqlite3_stmt *statement = [connection enumerateKeysAndObjectsStatement];
	if (statement == NULL) return;
	
	isMutated = NO; // mutation during enumeration protection
	
	// SELECT "key", "data", FROM "database";
	//
	// Performance tuning:
	// Use initWithBytesNoCopy to avoid an extra allocation and memcpy.
	//
	// Cache considerations:
	// Do we want to add the objects/metadata to the cache here?
	// If the cache is unlimited then we should.
	// Otherwise we should only add to the cache if its not full.
	// The cache should generally be reserved for items that are explicitly fetched,
	// and we don't want to crowd them out during enumerations.
	
	BOOL stop = NO;
	BOOL unlimitedObjectCacheLimit = (connection->objectCacheLimit == 0);

	int status;
	while ((status = sqlite3_step(statement)) == SQLITE_ROW)
	{
		if (connection->needsMarkSqlLevelSharedReadLock)
			[connection markSqlLevelSharedReadLockAcquired];
		
		const unsigned char *text = sqlite3_column_text(statement, 0);
		int textSize = sqlite3_column_bytes(statement, 0);
		
		NSString *key = [[NSString alloc] initWithBytes:text length:textSize encoding:NSUTF8StringEncoding];
		
		BOOL invokeBlock = filter == NULL ? YES : filter(key);
		if (invokeBlock)
		{
			id object = [connection->objectCache objectForKey:key];
			if (object == nil)
			{
				const void *oBlob = sqlite3_column_blob(statement, 1);
				int oBlobSize = sqlite3_column_bytes(statement, 1);

				NSData *oData = [[NSData alloc] initWithBytesNoCopy:(void *)oBlob length:oBlobSize freeWhenDone:NO];
				object = connection->database->objectDeserializer(oData);
				
				if (unlimitedObjectCacheLimit || [connection->objectCache count] < connection->objectCacheLimit)
				{
					if (object)
						[connection->objectCache setObject:object forKey:key];
				}
			}
			
			block(key, object, &stop);
			
			if (stop || isMutated) break;
		}
	}
	
	if ((status != SQLITE_DONE) && !stop && !isMutated)
	{
		YDBLogError(@"%@ - sqlite_step error: %d %s", THIS_METHOD, status, sqlite3_errmsg(connection->db));
	}
	
	sqlite3_reset(statement);
	
	if (isMutated && !stop)
	{
		@throw [self mutationDuringEnumerationException];
	}
}

/**
 * Fast enumeration over all objects in the database.
 *
 * This uses a "SELECT * FROM database" operation, and then steps over the results,
 * deserializing each object and metadata (if not cached), and then invoking the given block handler.
 *
 * If you only need to enumerate over certain objects (e.g. keys with a particular prefix),
 * consider using the alternative version below which provide a filter,
 * allowing you to skip the serialization steps for those rows you're not interested in.
**/
- (void)enumerateRowsUsingBlock:(void (^)(NSString *key, id object, id metadata, BOOL *stop))block
{
	[self enumerateRowsUsingBlock:block withFilter:NULL];
}

/**
 * Fast enumeration over rows in the database for which you're interested in.
 * The filter block allows you to specify which rows you're interested in,
 * allowing you to skip the deserialization step for ignored rows.
 *
 * From the filter block, simply return YES if you'd like the block handler to be invoked for the given row.
 * If the filter block returns NO, then the block handler is skipped for the given row,
 * which avoids the cost associated with deserialization process.
**/
- (void)enumerateRowsUsingBlock:(void (^)(NSString *key, id object, id metadata, BOOL *stop))block
                     withFilter:(BOOL (^)(NSString *key))filter
{
	if (block == NULL) return;
	
	sqlite3_stmt *statement = [connection enumerateRowsStatement];
	if (statement == NULL) return;
	
	isMutated = NO; // mutation during enumeration protection
	
	// SELECT "key", "data", "metadata" FROM "database";
	//
	// Performance tuning:
	// Use initWithBytesNoCopy to avoid an extra allocation and memcpy.
	//
	// Cache considerations:
	// Do we want to add the objects/metadata to the cache here?
	// If the cache is unlimited then we should.
	// Otherwise we should only add to the cache if its not full.
	// The cache should generally be reserved for items that are explicitly fetched,
	// and we don't want to crowd them out during enumerations.
	
	BOOL stop = NO;
	BOOL unlimitedObjectCacheLimit = (connection->objectCacheLimit == 0);
	BOOL unlimitedMetadataCacheLimit = (connection->metadataCacheLimit == 0);

	int status;
	while ((status = sqlite3_step(statement)) == SQLITE_ROW)
	{
		if (connection->needsMarkSqlLevelSharedReadLock)
			[connection markSqlLevelSharedReadLockAcquired];
		
		const unsigned char *text = sqlite3_column_text(statement, 0);
		int textSize = sqlite3_column_bytes(statement, 0);
		
		NSString *key = [[NSString alloc] initWithBytes:text length:textSize encoding:NSUTF8StringEncoding];
		
		BOOL invokeBlock = filter == NULL ? YES : filter(key);
		if (invokeBlock)
		{
			id metadata = [connection->metadataCache objectForKey:key];
			if (metadata)
			{
				if (metadata == [YapNull null])
					metadata = nil;
			}
			else
			{
				const void *mBlob = sqlite3_column_blob(statement, 2);
				int mBlobSize = sqlite3_column_bytes(statement, 2);
				
				if (mBlobSize > 0)
				{
					NSData *mData = [[NSData alloc] initWithBytesNoCopy:(void *)mBlob length:mBlobSize freeWhenDone:NO];
					metadata = connection->database->metadataDeserializer(mData);
				}
				
				if (unlimitedMetadataCacheLimit || [connection->metadataCache count] < connection->metadataCacheLimit)
				{
					if (metadata)
						[connection->metadataCache setObject:metadata forKey:key];
					else
						[connection->metadataCache setObject:[YapNull null] forKey:key];
				}
			}
			
			id object = [connection->objectCache objectForKey:key];
			if (object == nil)
			{
				const void *oBlob = sqlite3_column_blob(statement, 1);
				int oBlobSize = sqlite3_column_bytes(statement, 1);

				NSData *oData = [[NSData alloc] initWithBytesNoCopy:(void *)oBlob length:oBlobSize freeWhenDone:NO];
				object = connection->database->objectDeserializer(oData);
				
				if (unlimitedObjectCacheLimit || [connection->objectCache count] < connection->objectCacheLimit)
				{
					if (object)
						[connection->objectCache setObject:object forKey:key];
				}
			}
			
			block(key, object, metadata, &stop);
			
			if (stop || isMutated) break;
		}
	}
	
	if ((status != SQLITE_DONE) && !stop && !isMutated)
	{
		YDBLogError(@"%@ - sqlite_step error: %d %s", THIS_METHOD, status, sqlite3_errmsg(connection->db));
	}
	
	sqlite3_reset(statement);
	
	if (isMutated && !stop)
	{
		@throw [self mutationDuringEnumerationException];
	}
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation YapDatabaseReadWriteTransaction

#pragma mark Primitive

- (void)setPrimitiveData:(NSData *)data forKey:(NSString *)key
{
	[self setPrimitiveData:data forKey:key withMetadata:nil];
}

- (void)setPrimitiveData:(NSData *)data forKey:(NSString *)key withMetadata:(id)metadata
{
	if (data == nil)
	{
		[self removeObjectForKey:key];
		return;
	}
	
	if (key == nil) return;
	
	sqlite3_stmt *statement = [connection setAllForKeyStatement];
	if (statement == NULL) return;
	
	// INSERT OR REPLACE INTO "database" ("key", "data", "metadata") VALUES (?, ?, ?);
	//
	// To use SQLITE_STATIC on our data blob, we use the objc_precise_lifetime attribute.
	// This ensures the data isn't released until it goes out of scope.
	
	YapDatabaseString _key; MakeYapDatabaseString(&_key, key);
	sqlite3_bind_text(statement, 1, _key.str, _key.length, SQLITE_STATIC);
	
	sqlite3_bind_blob(statement, 2, data.bytes, (int)data.length, SQLITE_STATIC);
	
	__attribute__((objc_precise_lifetime)) NSData *rawMeta = connection->database->metadataSerializer(metadata);
	sqlite3_bind_blob(statement, 3, rawMeta.bytes, (int)rawMeta.length, SQLITE_STATIC);
	
	BOOL set = YES;
	
	int status = sqlite3_step(statement);
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"Error executing 'setAllForKeyStatement': %d %s, key(%@)",
		                                                   status, sqlite3_errmsg(connection->db), key);
		set = NO;
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_key);
	
	if (!set) return;
	
	isMutated = YES;  // mutation during enumeration protection
	key = [key copy]; // mutable string protection
	
	[connection->objectCache removeObjectForKey:key];
	[connection->objectChanges setObject:[YapNull null] forKey:key];
	
	if (metadata) {
		[connection->metadataCache setObject:metadata forKey:key];
		[connection->metadataChanges setObject:metadata forKey:key];
	}
	else {
		[connection->metadataCache setObject:[YapNull null] forKey:key];
		[connection->metadataChanges setObject:[YapNull null] forKey:key];
	}
	
	[[self extensions] enumerateKeysAndObjectsUsingBlock:^(id extNameObj, id extTransactionObj, BOOL *stop) {
		
		__unsafe_unretained id <YapAbstractDatabaseExtensionTransaction_KeyValue> extTransaction = extTransactionObj;
		
		[extTransaction handleRemoveObjectForKey:key];
	}];
}

#pragma mark Object

- (void)setObject:(id)object forKey:(NSString *)key
{
	[self setObject:object forKey:key withMetadata:nil];
}

- (void)setObject:(id)object forKey:(NSString *)key withMetadata:(id)metadata
{
	if (object == nil)
	{
		[self removeObjectForKey:key];
		return;
	}
	
	if (key == nil) return;
	
	sqlite3_stmt *statement = [connection setAllForKeyStatement];
	if (statement == NULL) return;
	
	// INSERT OR REPLACE INTO "database" ("key", "data", "metadata") VALUES (?, ?, ?);
	//
	// To use SQLITE_STATIC on our data blob, we use the objc_precise_lifetime attribute.
	// This ensures the data isn't released until it goes out of scope.
	
	YapDatabaseString _key; MakeYapDatabaseString(&_key, key);
	sqlite3_bind_text(statement, 1, _key.str, _key.length, SQLITE_STATIC);
	
	__attribute__((objc_precise_lifetime)) NSData *rawData = connection->database->objectSerializer(object);
	sqlite3_bind_blob(statement, 2, rawData.bytes, (int)rawData.length, SQLITE_STATIC);
	
	__attribute__((objc_precise_lifetime)) NSData *rawMeta = connection->database->metadataSerializer(metadata);
	sqlite3_bind_blob(statement, 3, rawMeta.bytes, (int)rawMeta.length, SQLITE_STATIC);
	
	BOOL set = YES;
	
	int status = sqlite3_step(statement);
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"Error executing 'setAllForKeyStatement': %d %s, key(%@)",
		                                                   status, sqlite3_errmsg(connection->db), key);
		set = NO;
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_key);
	
	if (!set) return;
	
	isMutated = YES;  // mutation during enumeration protection
	key = [key copy]; // mutable string protection
	
	[connection->objectCache setObject:object forKey:key];
	[connection->objectChanges setObject:object forKey:key];
	
	if (metadata) {
		[connection->metadataCache setObject:metadata forKey:key];
		[connection->metadataChanges setObject:metadata forKey:key];
	}
	else {
		[connection->metadataCache setObject:[YapNull null] forKey:key];
		[connection->metadataChanges setObject:[YapNull null] forKey:key];
	}
	
	[[self extensions] enumerateKeysAndObjectsUsingBlock:^(id extNameObj, id extTransactionObj, BOOL *stop) {
		
		__unsafe_unretained id <YapAbstractDatabaseExtensionTransaction_KeyValue> extTransaction = extTransactionObj;
		
		[extTransaction handleSetObject:object forKey:key withMetadata:metadata];
	}];
}

#pragma mark Metadata

- (void)setMetadata:(id)metadata forKey:(NSString *)key
{
	if (![self hasObjectForKey:key]) return;
	
	sqlite3_stmt *statement = [connection setMetadataForKeyStatement];
	if (statement == NULL) return;
	
	// UPDATE "database" SET "metadata" = ? WHERE "key" = ?;
	// 
	// To use SQLITE_STATIC on our data blob, we use the objc_precise_lifetime attribute.
	// This ensures the data isn't released until it goes out of scope.
	
	__attribute__((objc_precise_lifetime)) NSData *rawMeta = connection->database->metadataSerializer(metadata);
	sqlite3_bind_blob(statement, 1, rawMeta.bytes, (int)rawMeta.length, SQLITE_STATIC);
	
	YapDatabaseString _key; MakeYapDatabaseString(&_key, key);
	sqlite3_bind_text(statement, 2, _key.str, _key.length, SQLITE_STATIC);
	
	BOOL updated = YES;
	
	int status = sqlite3_step(statement);
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"Error executing 'setMetaForKeyStatement': %d %s, key(%@)",
		                                                    status, sqlite3_errmsg(connection->db), key);
		updated = NO;
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_key);
	
	if (!updated) return;
	
	isMutated = YES;  // mutation during enumeration protection
	key = [key copy]; // mutable string protection
	
	if (metadata) {
		[connection->metadataCache setObject:metadata forKey:key];
		[connection->metadataChanges setObject:metadata forKey:key];
	}
	else {
		[connection->metadataCache setObject:[YapNull null] forKey:key];
		[connection->metadataChanges setObject:[YapNull null] forKey:key];
	}
	
	[[self extensions] enumerateKeysAndObjectsUsingBlock:^(id extNameObj, id extTransactionObj, BOOL *stop) {
		
		__unsafe_unretained id <YapAbstractDatabaseExtensionTransaction_KeyValue> extTransaction = extTransactionObj;
		
		[extTransaction handleSetMetadata:metadata forKey:key];
	}];
}

#pragma mark Remove

- (void)removeObjectForKey:(NSString *)key
{
	if (key == nil) return;
	
	sqlite3_stmt *statement = [connection removeForKeyStatement];
	if (statement == NULL) return;
	
	// DELETE FROM "database" WHERE "key" = ?;
	
	YapDatabaseString _key; MakeYapDatabaseString(&_key, key);
	sqlite3_bind_text(statement, 1, _key.str, _key.length, SQLITE_STATIC);
	
	BOOL removed = YES;
	
	int status = sqlite3_step(statement);
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"Error executing 'removeForKeyStatement': %d %s, key(%@)",
		                                                   status, sqlite3_errmsg(connection->db), key);
		removed = NO;
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_key);
	
	if (!removed) return;
	
	isMutated = YES;  // mutation during enumeration protection
	key = [key copy]; // mutable string protection
	
	[connection->objectCache removeObjectForKey:key];
	[connection->metadataCache removeObjectForKey:key];
	
	[connection->objectChanges removeObjectForKey:key];
	[connection->metadataChanges removeObjectForKey:key];
	[connection->removedKeys addObject:key];
	
	[[self extensions] enumerateKeysAndObjectsUsingBlock:^(id extNameObj, id extTransactionObj, BOOL *stop) {
		
		__unsafe_unretained id <YapAbstractDatabaseExtensionTransaction_KeyValue> extTransaction = extTransactionObj;
		
		[extTransaction handleRemoveObjectForKey:key];
	}];
}

- (void)removeObjectsForKeys:(NSArray *)keys
{
	if ([keys count] == 0) {
		return;
	}
	if ([keys count] == 1) {
		[self removeObjectForKey:[keys objectAtIndex:0]];
		return;
	}
	
	// Sqlite has an upper bound on the number of host parameters that may be used in a single query.
	// We need to watch out for this in case a large array of keys is passed.
	
	NSUInteger maxHostParams = (NSUInteger) sqlite3_limit(connection->db, SQLITE_LIMIT_VARIABLE_NUMBER, -1);
	
	NSUInteger keysIndex = 0;
	NSUInteger keysCount = [keys count];
	
	do
	{
		NSUInteger keysLeft = keysCount - keysIndex;
		NSUInteger numHostParams = MIN(keysLeft, maxHostParams);
		
		// DELETE FROM "database" WHERE "key" in (?, ?, ...);
		
		NSUInteger capacity = 50 + (numHostParams * 3);
		NSMutableString *query = [NSMutableString stringWithCapacity:capacity];
		
		[query appendString:@"DELETE FROM \"database\" WHERE \"key\" IN ("];
		
		NSUInteger i;
		for (i = 0; i < numHostParams; i++)
		{
			if (i == 0)
				[query appendFormat:@"?"];
			else
				[query appendFormat:@", ?"];
		}
	
		[query appendString:@");"];
	
		sqlite3_stmt *statement;
		
		int status = sqlite3_prepare_v2(connection->db, [query UTF8String], -1, &statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"Error creating 'removeObjectForKeys' statement: %d %s",
			                                                          status, sqlite3_errmsg(connection->db));
			return;
		}
		
		for (i = 0; i < numHostParams; i++)
		{
			NSString *key = [keys objectAtIndex:(keysIndex + i)];
			
			sqlite3_bind_text(statement, (int)(i + 1), [key UTF8String], -1, SQLITE_TRANSIENT);
		}
		
		status = sqlite3_step(statement);
		if (status != SQLITE_DONE)
		{
			YDBLogError(@"Error executing 'removeObjectForKeys' statement: %d %s",
			                                                           status, sqlite3_errmsg(connection->db));
		}
		
		sqlite3_finalize(statement);
		statement = NULL;
		
		keysIndex += numHostParams;
		
	} while (keysIndex < keysCount);
	
	isMutated = YES; // mutation during enumeration protection
	keys = [[NSMutableArray alloc] initWithArray:keys copyItems:YES]; // mutable string protection
	
	[connection->objectCache removeObjectsForKeys:keys];
	[connection->metadataCache removeObjectsForKeys:keys];
	
	[connection->objectChanges removeObjectsForKeys:keys];
	[connection->metadataChanges removeObjectsForKeys:keys];
	[connection->removedKeys addObjectsFromArray:keys];
	
	[[self extensions] enumerateKeysAndObjectsUsingBlock:^(id extNameObj, id extTransactionObj, BOOL *stop) {
		
		__unsafe_unretained id <YapAbstractDatabaseExtensionTransaction_KeyValue> extTransaction = extTransactionObj;
		
		[extTransaction handleRemoveObjectsForKeys:keys];
	}];
}

- (void)removeAllObjects
{
	sqlite3_stmt *statement = [connection removeAllStatement];
	if (statement == NULL) return;
	
	// DELETE FROM "database";
	
	int status = sqlite3_step(statement);
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"Error executing 'removeAllStatement': %d %s", status, sqlite3_errmsg(connection->db));
	}
	
	sqlite3_reset(statement);
	
	isMutated = YES; // mutation during enumeration protection
	
	[connection->objectCache removeAllObjects];
	[connection->metadataCache removeAllObjects];
	
	[connection->objectChanges removeAllObjects];
	[connection->metadataChanges removeAllObjects];
	[connection->removedKeys removeAllObjects];
	connection->allKeysRemoved = YES;
	
	[[self extensions] enumerateKeysAndObjectsUsingBlock:^(id extNameObj, id extTransactionObj, BOOL *stop) {
		
		__unsafe_unretained id <YapAbstractDatabaseExtensionTransaction_KeyValue> extTransaction = extTransactionObj;
		
		[extTransaction handleRemoveAllObjects];
	}];
}

@end
