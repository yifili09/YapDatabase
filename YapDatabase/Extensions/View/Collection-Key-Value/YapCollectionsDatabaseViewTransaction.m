#import "YapCollectionsDatabaseViewTransaction.h"
#import "YapCollectionsDatabaseViewPrivate.h"
#import "YapDatabaseViewPageMetadata.h"
#import "YapDatabaseViewChange.h"
#import "YapDatabaseViewChangePrivate.h"
#import "YapAbstractDatabaseExtensionPrivate.h"
#import "YapAbstractDatabasePrivate.h"
#import "YapCollectionsDatabasePrivate.h"
#import "YapCache.h"
#import "YapCollectionKey.h"
#import "YapDatabaseString.h"
#import "YapDatabaseLogging.h"

#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

/**
 * Define log level for this file: OFF, ERROR, WARN, INFO, VERBOSE
 * See YapDatabaseLogging.h for more information.
**/
#if DEBUG
  static const int ydbLogLevel = YDB_LOG_LEVEL_WARN;
#else
  static const int ydbLogLevel = YDB_LOG_LEVEL_WARN;
#endif

/**
 * This version number is stored in the yap2 table.
 * If there is a major re-write to this class, then the version number will be incremented,
 * and the class can automatically rebuild the tables as needed.
**/
#define YAP_DATABASE_VIEW_CLASS_VERSION 1

/**
 * The view is tasked with storing ordered arrays of keys.
 * In doing so, it splits the array into "pages" of keys,
 * and stores the pages in the database.
 * This reduces disk IO, as only the contents of a single page are written for a single change.
 * And only the contents of a single page need be read to fetch a single key.
**/
#define YAP_DATABASE_VIEW_MAX_PAGE_SIZE 50

/**
 * ARCHITECTURE OVERVIEW:
 *
 * A YapCollectionsDatabaseView allows one to store a ordered array of collection/key tuples.
 * Furthermore, groups are supported, which means there may be multiple ordered arrays of tuples, one per group.
 *
 * Conceptually this is a very simple concept.
 * But obviously there are memory and performance requirements that add complexity.
 *
 * The view creates two database tables:
 *
 * view_name_key:
 * - collection (string) : from the database table
 * - key        (string) : from the database table
 * - pageKey    (string) : the primary key in the page table
 *
 * view_name_page:
 * - pageKey  (string, primary key) : a uuid
 * - data     (blob)                : an array of collection/key tuples (the page)
 * - metadata (blob)                : a YapDatabaseViewPageMetadata object
 *
 * For both tables "name" is replaced by the registered name of the view.
 *
 * Thus, given a key, we can quickly identify if the key exists in the view (via the key table).
 * And if so we can use the associated pageKey to figure out the group and index of the key.
 *
 * When we open the view, we read all the metadata objects from the page table into memory.
 * We use the metadata to create the two primary data structures:
 *
 * - group_pagesMetadata_dict (NSMutableDictionary) : key(group), value(array of YapDatabaseViewPageMetadata objects)
 * - pageKey_group_dict       (NSMutableDictionary) : key(pageKey), value(group)
 *
 * Given a group, we can use the group_pages_dict to find the associated array of pages (and metadata for each page).
 * Given a pageKey, we can use the pageKey_group_dict to quickly find the associated group.
**/
@implementation YapCollectionsDatabaseViewTransaction

- (id)initWithViewConnection:(YapCollectionsDatabaseViewConnection *)inViewConnection
         databaseTransaction:(YapCollectionsDatabaseReadTransaction *)inDatabaseTransaction
{
	if ((self = [super init]))
	{
		viewConnection = inViewConnection;
		databaseTransaction = inDatabaseTransaction;
	}
	return self;
}

/**
 * This method is called to create any necessary tables,
 * as well as populate the view by enumerating over the existing rows in the database.
 * 
 * The given BOOL (isFirstTimeExtensionRegistration) indicates if this is the first time the view has been registered.
 * That is, this value will be YES the very first time this view is registered with this name.
 * Subsequent registrations (on later app launches) will pass NO.
 * 
 * In general, a YES parameter means the view needs to populate itself by enumerating over the rows in the database.
 * A NO parameter means the view is already up-to-date.
**/
- (BOOL)createIfNeeded
{
	int oldClassVersion = [self intValueForExtensionKey:@"classVersion"];
	int classVersion = YAP_DATABASE_VIEW_CLASS_VERSION;
	
	if (oldClassVersion != classVersion)
	{
		// First time registration
		
		if (![self createTables]) return NO;
		if (![self populateView]) return NO;
		
		[self setIntValue:classVersion forExtensionKey:@"classVersion"];
		
		int userSuppliedConfigVersion = viewConnection->view->version;
		[self setIntValue:userSuppliedConfigVersion forExtensionKey:@"version"];
	}
	else
	{
		// Check user-supplied config version.
		// We may need to re-populate the database if the groupingBlock or sortingBlock changed.
		
		int oldVersion = [self intValueForExtensionKey:@"version"];
		int newVersion = viewConnection->view->version;
		
		if (oldVersion != newVersion)
		{
			if (![self populateView]) return NO;
			
			[self setIntValue:newVersion forExtensionKey:@"version"];
		}
	}
	
	return YES;
}

- (BOOL)prepareIfNeeded
{
	if (viewConnection->group_pagesMetadata_dict && viewConnection->pageKey_group_dict)
	{
		// Already prepared
		return YES;
	}
	
	sqlite3 *db = databaseTransaction->connection->db;
	
	NSString *string = [NSString stringWithFormat:
	    @"SELECT \"pageKey\", \"metadata\" FROM \"%@\" ;", [self pageTableName]];
	
	sqlite3_stmt *statement;
	
	int status = sqlite3_prepare_v2(db, [string UTF8String], -1, &statement, NULL);
	if (status != SQLITE_OK)
	{
		YDBLogError(@"%@ (%@): Cannot create 'enumerate_stmt': %d %s",
		            THIS_METHOD, [self registeredName], status, sqlite3_errmsg(db));
		return NO;
	}
	
	// Enumerate over the page rows in the database, and populate our data structure.
	// Each row gives us the following fields:
	//
	// - group
	// - pageKey
	// - prevPageKey
	//
	// From this information we need to piece together the group_pagesMetadata_dict:
	// - dict.key = group
	// - dict.value = properly ordered array of YapDatabaseViewKeyPageMetadata objects
	//
	// To piece together the proper page order we make a temporary dictionary with each link in the linked-list.
	// For example:
	//
	// pageC.prevPage = pageB  =>      B -> C
	// pageB.prevPage = pageA  =>      A -> B
	// pageA.prevPage = nil    => NSNull -> A
	//
	// After the enumeration of all rows is complete, we can simply walk the linked list from the first page.
	
	NSMutableDictionary *groupPageDict = [[NSMutableDictionary alloc] init];
	NSMutableDictionary *groupOrderDict = [[NSMutableDictionary alloc] init];
	
	unsigned int stepCount = 0;
	
	while (sqlite3_step(statement) == SQLITE_ROW)
	{
		stepCount++;
		
		const unsigned char *text = sqlite3_column_text(statement, 0);
		int textSize = sqlite3_column_bytes(statement, 0);
		
		const void *blob = sqlite3_column_blob(statement, 1);
		int blobSize = sqlite3_column_bytes(statement, 1);
		
		NSString *pageKey = [[NSString alloc] initWithBytes:text length:textSize encoding:NSUTF8StringEncoding];
		NSData *data = [[NSData alloc] initWithBytesNoCopy:(void *)blob length:blobSize freeWhenDone:NO];
		
		id metadata = [NSKeyedUnarchiver unarchiveObjectWithData:data];
		
		if ([metadata isKindOfClass:[YapDatabaseViewPageMetadata class]])
		{
			YapDatabaseViewPageMetadata *pageMetadata = (YapDatabaseViewPageMetadata *)metadata;
			pageMetadata->pageKey = pageKey;
			
			NSString *group = pageMetadata->group;
			
			NSMutableDictionary *pageDict = [groupPageDict objectForKey:group];
			if (pageDict == nil)
			{
				pageDict = [[NSMutableDictionary alloc] init];
				[groupPageDict setObject:pageDict forKey:group];
			}
			
			NSMutableDictionary *orderDict = [groupOrderDict objectForKey:group];
			if (orderDict == nil)
			{
				orderDict = [[NSMutableDictionary alloc] init];
				[groupOrderDict setObject:orderDict forKey:group];
			}
			
			[pageDict setObject:pageMetadata forKey:pageKey];
			
			if (pageMetadata->prevPageKey)
				[orderDict setObject:pageMetadata->pageKey forKey:pageMetadata->prevPageKey];
			else
				[orderDict setObject:pageMetadata->pageKey forKey:[NSNull null]];
		}
		else
		{
			YDBLogWarn(@"%@ (%@): Encountered unknown metadata class: %@",
					   THIS_METHOD, [self registeredName], [metadata class]);
		}
	}
	
	YDBLogVerbose(@"Processing %u items from %@...", stepCount, [self pageTableName]);
	
	YDBLogVerbose(@"groupPageDict: %@", groupPageDict);
	YDBLogVerbose(@"groupOrderDict: %@", groupOrderDict);
	
	__block BOOL error = ((status != SQLITE_OK) && (status != SQLITE_DONE));
	
	if (error)
	{
		YDBLogError(@"%@ (%@): Error enumerating page table: %d %s",
		            THIS_METHOD, [self registeredName], status, sqlite3_errmsg(db));
	}
	else
	{
		// Initialize ivars in viewConnection.
		// We try not to do this before we know the table exists.
		
		viewConnection->group_pagesMetadata_dict = [[NSMutableDictionary alloc] init];
		viewConnection->pageKey_group_dict = [[NSMutableDictionary alloc] init];
		
		// Enumerate over each group
		
		[groupOrderDict enumerateKeysAndObjectsUsingBlock:^(id _group, id _orderDict, BOOL *stop) {
			
			__unsafe_unretained NSString *group = (NSString *)_group;
			__unsafe_unretained NSMutableDictionary *orderDict = (NSMutableDictionary *)_orderDict;
			
			NSMutableDictionary *pageDict = [groupPageDict objectForKey:group];
			
			// Walk the linked-list to stitch together the pages for this section.
			//
			// NSNull -> firstPageKey
			// firstPageKey -> secondPageKey
			// ...
			// secondToLastPageKey -> lastPageKey
			//
			// And from the keys, we can get the actual pageMetadata using the pageDict.
			
			NSMutableArray *pagesForGroup = [[NSMutableArray alloc] initWithCapacity:[pageDict count]];
			[viewConnection->group_pagesMetadata_dict setObject:pagesForGroup forKey:group];
			
			YapDatabaseViewPageMetadata *prevPageMetadata = nil;
			
			NSString *pageKey = [orderDict objectForKey:[NSNull null]];
			while (pageKey)
			{
				[viewConnection->pageKey_group_dict setObject:group forKey:pageKey];
				
				YapDatabaseViewPageMetadata *pageMetadata = [pageDict objectForKey:pageKey];
				if (pageMetadata == nil)
				{
					YDBLogError(@"%@ (%@): Invalid key ordering detected in group(%@)",
					            THIS_METHOD, [self registeredName], group);
					
					error = YES;
					break;
				}
				
				[pagesForGroup addObject:pageMetadata];
				
				if (prevPageMetadata)
					prevPageMetadata->nextPageKey = pageKey;
				
				prevPageMetadata = pageMetadata;
				pageKey = [orderDict objectForKey:pageKey];
				
				if ([pagesForGroup count] > [orderDict count])
				{
					YDBLogError(@"%@ (%@): Circular key ordering detected in group(%@)",
					            THIS_METHOD, [self registeredName], group);
					
					error = YES;
					break;
				}
			}
			
			// Validate data for this section
			
			if (!error && ([pagesForGroup count] != [orderDict count]))
			{
				YDBLogError(@"%@ (%@): Missing key page(s) in group(%@)",
				            THIS_METHOD, [self registeredName], group);
				
				error = YES;
			}
		}];
	}
	
	// Validate data
	
	if (error)
	{
		// If there was an error opening the view, we need to reset the ivars to nil.
		// These are checked at the beginning of this method as a shortcut.
		
		viewConnection->group_pagesMetadata_dict = nil;
		viewConnection->pageKey_group_dict = nil;
	}
	else
	{
		YDBLogVerbose(@"viewConnection->group_pagesMetadata_dict: %@", viewConnection->group_pagesMetadata_dict);
		YDBLogVerbose(@"viewConnection->pageKey_group_dict: %@", viewConnection->pageKey_group_dict);
	}
	
	sqlite3_finalize(statement);
	return !error;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Accessors
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Required override method from YapAbstractDatabaseExtensionTransaction.
**/
- (YapAbstractDatabaseTransaction *)databaseTransaction
{
	return databaseTransaction;
}

/**
 * Required override method from YapAbstractDatabaseExtensionTransaction.
**/
- (YapAbstractDatabaseExtension *)extension
{
	return viewConnection->view;
}

/**
 * Required override method from YapAbstractDatabaseExtensionTransaction.
**/
- (YapAbstractDatabaseExtensionConnection *)extensionConnection
{
	return viewConnection;
}

- (NSString *)registeredName
{
	return [viewConnection->view registeredName];
}

- (NSString *)keyTableName
{
	return [viewConnection->view keyTableName];
}

- (NSString *)pageTableName
{
	return [viewConnection->view pageTableName];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Serialization & Deserialization
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSData *)serializePage:(NSMutableArray *)page
{
	return [NSKeyedArchiver archivedDataWithRootObject:page];
}

- (NSMutableArray *)deserializePage:(NSData *)data
{
	return [NSKeyedUnarchiver unarchiveObjectWithData:data];
}

- (NSData *)serializeMetadata:(YapDatabaseViewPageMetadata *)metadata
{
	return [NSKeyedArchiver archivedDataWithRootObject:metadata];
}

- (YapDatabaseViewPageMetadata *)deserializeMetadata:(NSData *)data
{
	return [NSKeyedUnarchiver unarchiveObjectWithData:data];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Utilities
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSString *)generatePageKey
{
	NSString *key = nil;
	
	CFUUIDRef uuid = CFUUIDCreate(NULL);
	if (uuid)
	{
		key = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, uuid);
		CFRelease(uuid);
	}
	
	return key;
}

/**
 * If the given collection/key is in the view, returns the associated pageKey.
 *
 * This method will use the cache(s) if possible.
 * Otherwise it will lookup the value in the key table.
**/
- (NSString *)pageKeyForCollectionKey:(YapCollectionKey *)collectionKey
{
	NSParameterAssert(collectionKey != nil);
	
	NSString *pageKey = nil;
	
	// Check dirty cache & clean cache
	
	pageKey = [viewConnection->dirtyKeys objectForKey:collectionKey];
	if (pageKey)
	{
		if ((__bridge void *)pageKey == (__bridge void *)[NSNull null])
			return nil;
		else
			return pageKey;
	}
	
	pageKey = [viewConnection->keyCache objectForKey:collectionKey];
	if (pageKey)
	{
		if ((__bridge void *)pageKey == (__bridge void *)[NSNull null])
			return nil;
		else
			return pageKey;
	}
	
	// Otherwise pull from the database
	
	sqlite3_stmt *statement = [viewConnection keyTable_getPageKeyForCollectionKeyStatement];
	if (statement == NULL)
		return nil;
	
	// SELECT "pageKey" FROM "keyTableName" WHERE collection = ? AND key = ? ;
	
	YapDatabaseString _collection; MakeYapDatabaseString(&_collection, collectionKey.collection);
	sqlite3_bind_text(statement, 1, _collection.str, _collection.length, SQLITE_STATIC);
	
	YapDatabaseString _key; MakeYapDatabaseString(&_key, collectionKey.key);
	sqlite3_bind_text(statement, 2, _key.str, _key.length, SQLITE_STATIC);
	
	int status = sqlite3_step(statement);
	if (status == SQLITE_ROW)
	{
		const unsigned char *text = sqlite3_column_text(statement, 0);
		int textSize = sqlite3_column_bytes(statement, 0);
		
		pageKey = [[NSString alloc] initWithBytes:text length:textSize encoding:NSUTF8StringEncoding];
	}
	else if (status == SQLITE_ERROR)
	{
		YDBLogError(@"%@ (%@): Error executing statement: %d %s, collection(%@) key(%@)",
		            THIS_METHOD, [self registeredName],
		            status, sqlite3_errmsg(databaseTransaction->connection->db),
		            collectionKey.collection, collectionKey.key);
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_collection);
	FreeYapDatabaseString(&_key);
	
	if (pageKey)
		[viewConnection->keyCache setObject:pageKey forKey:collectionKey];
	else
		[viewConnection->keyCache setObject:[NSNull null] forKey:collectionKey];
	
	return pageKey;
}

/**
 * Given a collection, and subset of keys, this method searches the 'keys' table to find all associated pageKeys.
 * 
 * The result is a dictionary, where the key is a pageKey, and the value is an NSSet
 * of all keys within that pageKey that belong to the given collection and within the given array of keys.
**/
- (NSDictionary *)pageKeysForKeys:(NSArray *)keys inCollection:(NSString *)collection
{
	NSParameterAssert(collection != nil);
	
	if ([keys count] == 0)
	{
		return [NSDictionary dictionary];
	}
	
	NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:[keys count]];
	
	sqlite3 *db = databaseTransaction->connection->db;
	
	// Sqlite has an upper bound on the number of host parameters that may be used in a single query.
	// We need to watch out for this in case a large array of keys is passed.
	
	NSUInteger maxHostParams = (NSUInteger) sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, -1);
	
	NSUInteger keysIndex = 0;
	NSUInteger keysCount = [keys count];
	
	YapDatabaseString _collection; MakeYapDatabaseString(&_collection, collection);
	
	do
	{
		NSUInteger keysLeft = keysCount - keysIndex;
		NSUInteger numKeyParams = MIN(keysLeft, (maxHostParams - 1)); // minus 1 for collection param
		
		// SELECT "key", "pageKey" FROM "keyTableName" WHERE collection = ? AND "key" IN (?, ?, ...);
		
		NSUInteger capacity = 50 + (numKeyParams * 3);
		NSMutableString *query = [NSMutableString stringWithCapacity:capacity];
		
		[query appendFormat:
		    @"SELECT \"key\", \"pageKey\" FROM \"%@\" WHERE \"collection\" = ? AND \"key\" IN (", [self keyTableName]];
		
		NSUInteger i;
		for (i = 0; i < numKeyParams; i++)
		{
			if (i == 0)
				[query appendFormat:@"?"];
			else
				[query appendFormat:@", ?"];
		}
		
		[query appendString:@");"];
		
		sqlite3_stmt *statement;
		int status;
		
		status = sqlite3_prepare_v2(db, [query UTF8String], -1, &statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"%@ (%@): Error creating statement\n"
			            @" - status(%d), errmsg: %s\n"
			            @" - query: %@",
			            THIS_METHOD, [self registeredName], status, sqlite3_errmsg(db), query);
			
			break; // Break from do/while. Still need to free _collection.
		}
		
		sqlite3_bind_text(statement, 1, _collection.str, _collection.length, SQLITE_STATIC);
		
		for (i = 0; i < numKeyParams; i++)
		{
			NSString *key = [keys objectAtIndex:(keysIndex + i)];
			
			sqlite3_bind_text(statement, (int)(i + 2), [key UTF8String], -1, SQLITE_TRANSIENT);
		}
		
		status = sqlite3_step(statement);
		while (status == SQLITE_ROW)
		{
			// Extract key & pageKey from row
			
			const unsigned char *text0 = sqlite3_column_text(statement, 0);
			int textSize0 = sqlite3_column_bytes(statement, 0);
			
			const unsigned char *text1 = sqlite3_column_text(statement, 1);
			int textSize1 = sqlite3_column_bytes(statement, 1);
			
			NSString *key = [[NSString alloc] initWithBytes:text0 length:textSize0 encoding:NSUTF8StringEncoding];
			NSString *pageKey = [[NSString alloc] initWithBytes:text1 length:textSize1 encoding:NSUTF8StringEncoding];
			
			// Add to result dictionary
			
			NSMutableSet *keysInPage = [result objectForKey:pageKey];
			if (keysInPage == nil)
			{
				keysInPage = [NSMutableSet setWithCapacity:1];
				[result setObject:keysInPage forKey:pageKey];
			}
			
			[keysInPage addObject:key];
			
			// Step to next row
			
			status = sqlite3_step(statement);
		}
		
		if (status != SQLITE_DONE)
		{
			YDBLogError(@"%@ (%@): Error executing statement: %d %s",
			            THIS_METHOD, [self registeredName], status, sqlite3_errmsg(db));
			
			break; // Break from do/while. Still need to free _collection.
		}
		
		keysIndex += numKeyParams;
	}
	while (keysIndex < keysCount);
	
	FreeYapDatabaseString(&_collection);
	
	return result;
}

/**
 * Given a collection, this method searches the 'keys' table to find all the associated keys and pageKeys.
 * 
 * The result is a dictionary, where the key is a pageKey, and the value is an NSSet
 * of all keys within that pageKey that belong to the given collection.
**/
- (NSDictionary *)pageKeysAndKeysForCollection:(NSString *)collection
{
	NSParameterAssert(collection != nil);
	
	sqlite3 *db = databaseTransaction->connection->db;
	
	sqlite3_stmt *statement = [viewConnection keyTable_enumerateForCollectionStatement];
	if (statement == NULL)
		return nil;
	
	NSMutableDictionary *result = [NSMutableDictionary dictionary];
	
	// SELECT "key", "pageKey" FROM "keyTableName" WHERE "collection" = ?;
	
	YapDatabaseString _collection; MakeYapDatabaseString(&_collection, collection);
	sqlite3_bind_text(statement, 1, _collection.str, _collection.length, SQLITE_STATIC);
	
	int status = sqlite3_step(statement);
	while (status == SQLITE_ROW)
	{
		// Extract key & pageKey from row
		
		const unsigned char *_key = sqlite3_column_text(statement, 0);
		int _keySize = sqlite3_column_bytes(statement, 0);
		
		const unsigned char *_pageKey = sqlite3_column_text(statement, 1);
		int _pageKeySize = sqlite3_column_bytes(statement, 1);
		
		NSString *key = [[NSString alloc] initWithBytes:_key length:_keySize encoding:NSUTF8StringEncoding];
		NSString *pageKey = [[NSString alloc] initWithBytes:_pageKey length:_pageKeySize encoding:NSUTF8StringEncoding];
		
		// Add to result dictionary
		
		NSMutableSet *keysInPage = [result objectForKey:pageKey];
		if (keysInPage == nil)
		{
			keysInPage = [NSMutableSet setWithCapacity:1];
			[result setObject:keysInPage forKey:pageKey];
		}
		
		[keysInPage addObject:key];
		
		// Step to next row
		
		status = sqlite3_step(statement);
	}
	
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"%@ (%@): Error executing statement: %d %s",
					THIS_METHOD, [self registeredName], status, sqlite3_errmsg(db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_collection);
	
	return result;
}

/**
 * Fetches the page for the given pageKey.
 * 
 * This method will use the cache(s) if possible.
 * Otherwise it will load the data from the page table and deserialize it.
**/
- (NSMutableArray *)pageForPageKey:(NSString *)pageKey
{
	NSMutableArray *page = nil;
	
	// Check dirty cache & clean cache
	
	page = [viewConnection->dirtyPages objectForKey:pageKey];
	if (page) return page;
	
	page = [viewConnection->pageCache objectForKey:pageKey];
	if (page) return page;
	
	// Otherwise pull from the database
	
	sqlite3_stmt *statement = [viewConnection pageTable_getDataForPageKeyStatement];
	if (statement == NULL)
		return nil;
	
	// SELECT data FROM 'pageTableName' WHERE pageKey = ? ;
	
	YapDatabaseString _pageKey; MakeYapDatabaseString(&_pageKey, pageKey);
	sqlite3_bind_text(statement, 1, _pageKey.str, _pageKey.length, SQLITE_STATIC);
	
	int status = sqlite3_step(statement);
	if (status == SQLITE_ROW)
	{
		const void *blob = sqlite3_column_blob(statement, 0);
		int blobSize = sqlite3_column_bytes(statement, 0);
		
		NSData *data = [[NSData alloc] initWithBytesNoCopy:(void *)blob length:blobSize freeWhenDone:NO];
		
		page = [self deserializePage:data];
	}
	else if (status == SQLITE_ERROR)
	{
		YDBLogError(@"%@ (%@): Error executing statement: %d %s",
		            THIS_METHOD, [self registeredName],
		            status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_pageKey);
	
	// Store in cache if found
	if (page)
		[viewConnection->pageCache setObject:page forKey:pageKey];
	
	return page;
}

- (NSString *)groupForPageKey:(NSString *)pageKey
{
	return [viewConnection->pageKey_group_dict objectForKey:pageKey];
}

- (NSUInteger)indexForCollectionKey:(YapCollectionKey *)collectionKey
                            inGroup:(NSString *)group
                        withPageKey:(NSString *)pageKey
{
	// Calculate the offset of the corresponding page within the group.
	
	NSUInteger pageOffset = 0;
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
	{
		if ([pageMetadata->pageKey isEqualToString:pageKey])
		{
			break;
		}
		
		pageOffset += pageMetadata->count;
	}
	
	// Fetch the actual page (ordered array of keys)
	
	NSMutableArray *page = [self pageForPageKey:pageKey];
	
	// Find the exact index of the key within the page
	
	NSUInteger keyIndexWithinPage = [page indexOfObject:collectionKey];
	
	// Return the full index of the key within the group
	
	return pageOffset + keyIndexWithinPage;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Populate
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (BOOL)createTables
{
	sqlite3 *db = databaseTransaction->connection->db;
	
	NSString *keyTableName = [self keyTableName];
	NSString *pageTableName = [self pageTableName];
	
	YDBLogVerbose(@"Creating view tables for registeredName(%@): %@, %@",
	              [self registeredName], keyTableName, pageTableName);
	
	NSString *createKeyTable = [NSString stringWithFormat:
	    @"CREATE TABLE IF NOT EXISTS \"%@\""
	    @" (\"collection\" CHAR NOT NULL,"
		@"  \"key\" CHAR NOT NULL,"
	    @"  \"pageKey\" CHAR NOT NULL,"
		@"  PRIMARY KEY (\"collection\", \"key\")"
	    @" );", keyTableName];
	
	NSString *createPageTable = [NSString stringWithFormat:
	    @"CREATE TABLE IF NOT EXISTS \"%@\""
	    @" (\"pageKey\" CHAR NOT NULL PRIMARY KEY,"
	    @"  \"data\" BLOB,"
		@"  \"metadata\" BLOB"
	    @" );", pageTableName];
	
	int status;
	
	status = sqlite3_exec(db, [createKeyTable UTF8String], NULL, NULL, NULL);
	if (status != SQLITE_OK)
	{
		YDBLogError(@"%@ - Failed creating key table (%@): %d %s",
		            THIS_METHOD, keyTableName, status, sqlite3_errmsg(db));
		return NO;
	}
	
	status = sqlite3_exec(db, [createPageTable UTF8String], NULL, NULL, NULL);
	if (status != SQLITE_OK)
	{
		YDBLogError(@"%@ - Failed creating page table (%@): %d %s",
		            THIS_METHOD, pageTableName, status, sqlite3_errmsg(db));
		return NO;
	}
	
	return YES;
}

- (BOOL)populateView
{
	// Remove everything from the database
	
	[self removeAllKeysInAllCollections];
	
	// Initialize ivars
	
	viewConnection->group_pagesMetadata_dict = [[NSMutableDictionary alloc] init];
	viewConnection->pageKey_group_dict = [[NSMutableDictionary alloc] init];
	
	// Enumerate the existing rows in the database and populate the view
	
	__unsafe_unretained YapCollectionsDatabaseView *view = viewConnection->view;
	
	BOOL groupingNeedsObject = view->groupingBlockType == YapCollectionsDatabaseViewBlockTypeWithObject ||
	                           view->groupingBlockType == YapCollectionsDatabaseViewBlockTypeWithRow;
	
	BOOL groupingNeedsMetadata = view->groupingBlockType == YapCollectionsDatabaseViewBlockTypeWithMetadata ||
	                             view->groupingBlockType == YapCollectionsDatabaseViewBlockTypeWithRow;
	
	BOOL sortingNeedsObject = view->sortingBlockType  == YapCollectionsDatabaseViewBlockTypeWithObject ||
	                          view->sortingBlockType  == YapCollectionsDatabaseViewBlockTypeWithRow;
	
	BOOL sortingNeedsMetadata = view->sortingBlockType  == YapCollectionsDatabaseViewBlockTypeWithMetadata ||
	                            view->sortingBlockType  == YapCollectionsDatabaseViewBlockTypeWithRow;
	
	BOOL needsObject = groupingNeedsObject || sortingNeedsObject;
	BOOL needsMetadata = groupingNeedsMetadata || sortingNeedsMetadata;
	
	NSString *(^getGroup)(NSString *collection, NSString *key, id object, id metadata);
	getGroup = ^(NSString *collection, NSString *key, id object, id metadata){
		
		if (view->groupingBlockType == YapCollectionsDatabaseViewBlockTypeWithKey)
		{
			__unsafe_unretained YapCollectionsDatabaseViewGroupingWithKeyBlock groupingBlock =
		        (YapCollectionsDatabaseViewGroupingWithKeyBlock)view->groupingBlock;
			
			return groupingBlock(collection, key);
		}
		else if (view->groupingBlockType == YapCollectionsDatabaseViewBlockTypeWithObject)
		{
			__unsafe_unretained YapCollectionsDatabaseViewGroupingWithObjectBlock groupingBlock =
		        (YapCollectionsDatabaseViewGroupingWithObjectBlock)view->groupingBlock;
			
			return groupingBlock(collection, key, object);
		}
		else if (view->groupingBlockType == YapCollectionsDatabaseViewBlockTypeWithMetadata)
		{
			__unsafe_unretained YapCollectionsDatabaseViewGroupingWithMetadataBlock groupingBlock =
		        (YapCollectionsDatabaseViewGroupingWithMetadataBlock)view->groupingBlock;
			
			return groupingBlock(collection, key, metadata);
		}
		else
		{
			__unsafe_unretained YapCollectionsDatabaseViewGroupingWithRowBlock groupingBlock =
		        (YapCollectionsDatabaseViewGroupingWithRowBlock)view->groupingBlock;
			
			return groupingBlock(collection, key, object, metadata);
		}
	};
	
	int flags = (YapDatabaseViewChangeColumnObject | YapDatabaseViewChangeColumnMetadata);
	
	if (needsObject && needsMetadata)
	{
		if (groupingNeedsObject || groupingNeedsMetadata)
		{
			[databaseTransaction enumerateRowsInAllCollectionsUsingBlock:
			    ^(NSString *collection, NSString *key, id object, id metadata, BOOL *stop) {
				
				NSString *group = getGroup(collection, key, object, metadata);
				if (group)
				{
					YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
					
					[self insertObject:object
							  metadata:metadata
					 forCollectionKey:collectionKey inGroup:group withModifiedColumns:flags isNew:YES];
				}
			}];
		}
		else
		{
			// Optimization: Grouping doesn't require the object or metadata.
			// So we can skip the deserialization step for any rows not in the view.
			
			__block NSString *group = nil;
			[databaseTransaction enumerateRowsInAllCollectionsUsingBlock:
			    ^(NSString *collection, NSString *key, id object, id metadata, BOOL *stop) {
				
				YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
					
				[self insertObject:object
				          metadata:metadata
				  forCollectionKey:collectionKey inGroup:group  withModifiedColumns:flags isNew:YES];
				
			} withFilter:^BOOL(NSString *collection, NSString *key) {
				
				group = getGroup(collection, key, nil, nil);
				return (group != nil);
			}];
		}
	}
	else if (needsObject && !needsMetadata)
	{
		if (groupingNeedsObject)
		{
			[databaseTransaction enumerateKeysAndObjectsInAllCollectionsUsingBlock:
			    ^(NSString *collection, NSString *key, id object, BOOL *stop) {
				
				NSString *group = getGroup(collection, key, object, nil);
				if (group)
				{
					YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
					
					[self insertObject:object
					          metadata:nil
					  forCollectionKey:collectionKey inGroup:group withModifiedColumns:flags isNew:YES];
				}
			}];
		}
		else
		{
			// Optimization: Grouping doesn't require the object.
			// So we can skip the deserialization step for any rows not in the view.
			
			__block NSString *group = nil;
			[databaseTransaction enumerateKeysAndObjectsInAllCollectionsUsingBlock:
			    ^(NSString *collection, NSString *key, id object, BOOL *stop) {
				
				YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
				
				[self insertObject:object
				          metadata:nil
				  forCollectionKey:collectionKey inGroup:group withModifiedColumns:flags isNew:YES];
				
			} withFilter:^BOOL(NSString *collection, NSString *key) {
				
				group = getGroup(collection, key, nil, nil);
				return (group != nil);
			}];
		}
	}
	else if (!needsObject && needsMetadata)
	{
		if (groupingNeedsMetadata)
		{
			[databaseTransaction enumerateKeysAndMetadataInAllCollectionsUsingBlock:
			    ^(NSString *collection, NSString *key, id metadata, BOOL *stop) {
				
				NSString *group = getGroup(collection, key, nil, metadata);
				if (group)
				{
					YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
					
					[self insertObject:nil
					          metadata:metadata
					  forCollectionKey:collectionKey inGroup:group withModifiedColumns:flags isNew:YES];
				}
			}];
		}
		else
		{
			// Optimization: Grouping doesn't require the metadata.
			// So we can skip the deserialization step for any rows not in the view.
			
			__block NSString *group = nil;
			[databaseTransaction enumerateKeysAndMetadataInAllCollectionsUsingBlock:
			    ^(NSString *collection, NSString *key, id metadata, BOOL *stop) {
				
				YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
				
				[self insertObject:nil
				          metadata:metadata
				  forCollectionKey:collectionKey inGroup:group withModifiedColumns:flags isNew:YES];
				
			} withFilter:^BOOL(NSString *collection, NSString *key) {
				
				group = getGroup(collection, key, nil, nil);
				return (group != nil);
			}];
		}
	}
	else // if (!needsObject && !needsMetadata)
	{
		[databaseTransaction enumerateKeysInAllCollectionsUsingBlock:
		    ^(NSString *collection, NSString *key, BOOL *stop) {
			
			NSString *group = getGroup(collection, key, nil, nil);
			if (group)
			{
				YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
				
				[self insertObject:nil
				          metadata:nil
				  forCollectionKey:collectionKey inGroup:group withModifiedColumns:flags isNew:YES];
			}
		}];
	}
	
	return YES;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Logic
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Use this method once the insertion index of a key is known.
 * 
 * Note: This method assumes the group already exists.
**/
- (void)insertCollectionKey:(YapCollectionKey *)collectionKey
                    inGroup:(NSString *)group
                    atIndex:(NSUInteger)index
        withExistingPageKey:(NSString *)existingPageKey
{
	YDBLogAutoTrace();
	
	NSParameterAssert(collectionKey != nil);
	NSParameterAssert(group != nil);
	
	// Find pageMetadata, pageKey and page
	
	YapDatabaseViewPageMetadata *pageMetadata = nil;
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	NSUInteger pageOffset = 0;
	NSUInteger pageIndex = 0;
	
	NSUInteger lastPageIndex = [pagesMetadataForGroup count] - 1;
	
	for (YapDatabaseViewPageMetadata *pm in pagesMetadataForGroup)
	{
		// Edge case: key is being inserted at the very end
		
		if ((index < (pageOffset + pm->count)) || (pageIndex == lastPageIndex))
		{
			pageMetadata = pm;
			break;
		}
		else if (index == (pageOffset + pm->count))
		{
			// Optimization:
			// The insertion index is in-between two pages.
			// So it could go at the end of this page, or the beginning of the next page.
			//
			// We always place the key in the next page, unless the next page is already full.
			//
			// Related method: splitOversizedPage:
			
			NSUInteger maxPageSize = YAP_DATABASE_VIEW_MAX_PAGE_SIZE;
			
			if (pm->count < maxPageSize)
			{
				YapDatabaseViewPageMetadata *nextpm = [pagesMetadataForGroup objectAtIndex:(pageIndex+1)];
				if (nextpm->count >= maxPageSize)
				{
					pageMetadata = pm;
					break;
				}
			}
		}
		
		pageIndex++;
		pageOffset += pm->count;
	}
	
	NSAssert(pageMetadata != nil, @"Missing pageMetadata in group(%@)", group);
	
	NSString *pageKey = pageMetadata->pageKey;
	NSMutableArray *page = [self pageForPageKey:pageKey];
	
	YDBLogVerbose(@"Inserting key(%@) collection(%@) in group(%@) at index(%lu) with page(%@) pageOffset(%lu)",
	              collectionKey.key, collectionKey.collection, group,
	              (unsigned long)index, pageKey, (unsigned long)(index - pageOffset));
	
	// Update page
	
	[page insertObject:collectionKey atIndex:(index - pageOffset)];
	
	[viewConnection->dirtyPages setObject:page forKey:pageKey];
	[viewConnection->pageCache setObject:page forKey:pageKey];
	
	// Update page metadata (by incrementing count)
	
	pageMetadata->count = [page count]; // number of keys in page
	[viewConnection->dirtyMetadata setObject:pageMetadata forKey:pageKey];
	
	// Mark key for insertion (if needed - may have already been in group)
	
	if (![pageKey isEqualToString:existingPageKey])
	{
		[viewConnection->dirtyKeys setObject:pageKey forKey:collectionKey];
		[viewConnection->keyCache setObject:pageKey forKey:collectionKey];
	}
	
	// Add change to log
	
	[viewConnection->changes addObject:
	    [YapDatabaseViewRowChange insertKey:collectionKey inGroup:group atIndex:index]];
	
	[viewConnection->mutatedGroups addObject:group];
}

/**
 * Use this method after it has been determined that the key should be inserted into the given group.
 * The object and metadata parameters must be properly set (if needed by the sorting block).
 * 
 * This method will use the configured sorting block to find the proper index for the key.
 * It will attempt to optimize this operation as best as possible using a variety of techniques.
**/
- (void)insertObject:(id)object
            metadata:(id)metadata
    forCollectionKey:(YapCollectionKey *)collectionKey
             inGroup:(NSString *)group
 withModifiedColumns:(int)flags
               isNew:(BOOL)isGuaranteedNew
{
	YDBLogAutoTrace();
	
	__unsafe_unretained YapCollectionsDatabaseView *view = viewConnection->view;
	
	// Fetch the pages associated with the group.
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	// Is the key already in the group?
	// If so:
	// - its index within the group may or may not have changed.
	// - we can use its existing position as an optimization during sorting.
	
	BOOL tryExistingIndexInGroup = NO;
	NSUInteger existingIndexInGroup = NSNotFound;
	
	NSString *existingPageKey = isGuaranteedNew ? nil : [self pageKeyForCollectionKey:collectionKey];
	if (existingPageKey)
	{
		// The key is already in the view.
		// Has it changed groups?
		
		NSString *existingGroup = [self groupForPageKey:existingPageKey];
		
		if ([group isEqualToString:existingGroup])
		{
			// The key is already in the group.
			//
			// Find out what its current index is.
			
			existingIndexInGroup = [self indexForCollectionKey:collectionKey inGroup:group withPageKey:existingPageKey];
			
			if (view->sortingBlockType == YapCollectionsDatabaseViewBlockTypeWithKey)
			{
				// Sorting is based entirely on the key, which hasn't changed.
				// Thus the position within the view hasn't changed.
				
				[viewConnection->changes addObject:
				    [YapDatabaseViewRowChange updateKey:collectionKey
				                                columns:flags
				                                inGroup:group
				                                atIndex:existingIndexInGroup]];
				return;
			}
			else
			{
				// Possible optimization:
				// Object or metadata was updated, but doesn't affect the position of the row within the view.
				tryExistingIndexInGroup = YES;
			}
		}
		else
		{
			[self removeCollectionKey:collectionKey withPageKey:existingPageKey group:existingGroup];
			
			// Don't forget to reset the existingPageKey ivar!
			// Or else 'insertKey:inGroup:atIndex:withExistingPageKey:' will be given an invalid existingPageKey.
			existingPageKey = nil;
		}
	}
	
	// Is this a new group ?
	
	if (pagesMetadataForGroup == nil)
	{
		// First object added to group.
		
		NSString *pageKey = [self generatePageKey];
		
		YDBLogVerbose(@"Inserting key(%@) collection(%@) in new group(%@) with page(%@)",
		              collectionKey.key, collectionKey.collection, group, pageKey);
		
		// Create page
		
		NSMutableArray *page = [NSMutableArray arrayWithCapacity:1];
		[page addObject:collectionKey];
		
		// Create pageMetadata
		
		YapDatabaseViewPageMetadata *pageMetadata = [[YapDatabaseViewPageMetadata alloc] init];
		pageMetadata->pageKey = pageKey;
		pageMetadata->nextPageKey = nil;
		pageMetadata->group = group;
		pageMetadata->count = 1;
		
		// Add page and pageMetadata to in-memory structures
		
		pagesMetadataForGroup = [[NSMutableArray alloc] initWithCapacity:1];
		[pagesMetadataForGroup addObject:pageMetadata];
		
		[viewConnection->group_pagesMetadata_dict setObject:pagesMetadataForGroup forKey:group];
		[viewConnection->pageKey_group_dict setObject:group forKey:pageKey];
		
		// Mark page as dirty
		
		[viewConnection->dirtyPages setObject:page forKey:pageKey];
		[viewConnection->pageCache setObject:page forKey:pageKey];
		
		// Mark pageMetadata as dirty
		
		[viewConnection->dirtyMetadata setObject:pageMetadata forKey:pageKey];
		
		// Mark key for insertion
		
		[viewConnection->dirtyKeys setObject:pageKey forKey:collectionKey];
		[viewConnection->keyCache setObject:pageKey forKey:collectionKey];
		
		// Add change to log
		
		[viewConnection->changes addObject:
		    [YapDatabaseViewSectionChange insertGroup:group]];
		
		[viewConnection->changes addObject:
		    [YapDatabaseViewRowChange insertKey:collectionKey inGroup:group atIndex:0]];
		
		[viewConnection->mutatedGroups addObject:group];
		
		return;
	}
	
	// Need to determine the location within the existing group.

	// Calculate out how many keys are in the group.
	
	NSUInteger count = 0;
	
	for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
	{
		count += pageMetadata->count;
	}
	
	// Create a block to do a single sorting comparison between the object to be inserted,
	// and some other object within the group at a given index.
	//
	// This block will be invoked repeatedly as we calculate the insertion index.
	
	NSComparisonResult (^compare)(NSUInteger) = ^NSComparisonResult (NSUInteger index){
		
		YapCollectionKey *another = nil;
		
		NSUInteger pageOffset = 0;
		for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
		{
			if ((index < (pageOffset + pageMetadata->count)) && (pageMetadata->count > 0))
			{
				NSMutableArray *page = [self pageForPageKey:pageMetadata->pageKey];
				
				another = [page objectAtIndex:(index - pageOffset)];
				break;
			}
			else
			{
				pageOffset += pageMetadata->count;
			}
		}
		
		if (view->sortingBlockType == YapCollectionsDatabaseViewBlockTypeWithKey)
		{
			__unsafe_unretained YapCollectionsDatabaseViewSortingWithKeyBlock sortingBlock =
			    (YapCollectionsDatabaseViewSortingWithKeyBlock)view->sortingBlock;
			
			return sortingBlock(group, collectionKey.collection, collectionKey.key,
			                                 another.collection,       another.key);
		}
		else if (view->sortingBlockType == YapCollectionsDatabaseViewBlockTypeWithObject)
		{
			__unsafe_unretained YapCollectionsDatabaseViewSortingWithObjectBlock sortingBlock =
			    (YapCollectionsDatabaseViewSortingWithObjectBlock)view->sortingBlock;
			
			id anotherObject = [databaseTransaction objectForKey:another.key inCollection:another.collection];
			
			return sortingBlock(group, collectionKey.collection, collectionKey.key,        object,
			                                 another.collection,       another.key, anotherObject);
		}
		else if (view->sortingBlockType == YapCollectionsDatabaseViewBlockTypeWithMetadata)
		{
			__unsafe_unretained YapCollectionsDatabaseViewSortingWithMetadataBlock sortingBlock =
			    (YapCollectionsDatabaseViewSortingWithMetadataBlock)view->sortingBlock;
			
			id anotherMetadata = [databaseTransaction metadataForKey:another.key inCollection:another.collection];
			
			return sortingBlock(group, collectionKey.collection, collectionKey.key,        metadata,
			                                 another.collection,       another.key, anotherMetadata);
		}
		else
		{
			__unsafe_unretained YapCollectionsDatabaseViewSortingWithRowBlock sortingBlock =
			    (YapCollectionsDatabaseViewSortingWithRowBlock)view->sortingBlock;
			
			id anotherObject = nil;
			id anotherMetadata = nil;
			
			[databaseTransaction getObject:&anotherObject
			                      metadata:&anotherMetadata
			                        forKey:another.key
			                  inCollection:another.collection];
			
			return sortingBlock(group, collectionKey.collection, collectionKey.key,        object,        metadata,
			                                 another.collection,       another.key, anotherObject, anotherMetadata);
		}
	};
	
	NSComparisonResult cmp;
	
	// Optimization 1:
	//
	// If the key is already in the group, check to see if its index is the same as before.
	// This handles the common case where an object is updated without changing its position within the view.
	
	if (tryExistingIndexInGroup)
	{
		NSMutableArray *existingPage = [self pageForPageKey:existingPageKey];
		
		NSUInteger existingPageOffset = 0;
		for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
		{
			if ([pageMetadata->pageKey isEqualToString:existingPageKey])
				break;
			else
				existingPageOffset += pageMetadata->count;
		}
		
		NSUInteger existingIndex = existingPageOffset + [existingPage indexOfObject:collectionKey];
		
		// Edge case: existing key is the only key in the group
		//
		// (existingIndex == 0) && (count == 1)
		
		BOOL useExistingIndexInGroup = YES;
		
		if (existingIndex > 0)
		{
			cmp = compare(existingIndex - 1); // compare vs prev
			
			useExistingIndexInGroup = (cmp != NSOrderedAscending); // object >= prev
		}
		
		if ((existingIndex + 1) < count && useExistingIndexInGroup)
		{
			cmp = compare(existingIndex + 1); // compare vs next
			
			useExistingIndexInGroup = (cmp != NSOrderedDescending); // object <= next
		}
		
		if (useExistingIndexInGroup)
		{
			// The key doesn't change position.
			
			YDBLogVerbose(@"Updated key(%@) in group(%@) maintains current index", collectionKey.key, group);
			
			[viewConnection->changes addObject:
			    [YapDatabaseViewRowChange updateKey:collectionKey
			                                columns:flags
			                                inGroup:group
			                                atIndex:existingIndexInGroup]];
			return;
		}
		else
		{
			// The key has changed position.
			// Remove it from previous position (and don't forget to decrement count).
			
			[self removeCollectionKey:collectionKey withPageKey:existingPageKey group:group];
			count--;
			
			// Don't forget to reset the existingPageKey ivar!
			// Or else 'insertKey:inGroup:atIndex:withExistingPageKey:' will be given an invalid existingPageKey.
			existingPageKey = nil;
		}
	}
		
	// Optimization 2:
	//
	// A very common operation is to insert objects at the beginning or end of the array.
	// We attempt to notice this trend and optimize around it.
	
	if (viewConnection->lastInsertWasAtFirstIndex && (count > 1))
	{
		cmp = compare(0);
		
		if (cmp == NSOrderedAscending) // object < first
		{
			YDBLogVerbose(@"Insert key(%@) collection(%@) in group(%@) at beginning (optimization)",
			              collectionKey.key, collectionKey.collection, group);
			
			[self insertCollectionKey:collectionKey
			                  inGroup:group
			                  atIndex:0
			      withExistingPageKey:existingPageKey];
			return;
		}
	}
	
	if (viewConnection->lastInsertWasAtLastIndex && (count > 1))
	{
		cmp = compare(count - 1);
		
		if (cmp != NSOrderedAscending) // object >= last
		{
			YDBLogVerbose(@"Insert key(%@) collection(%@) in group(%@) at end (optimization)",
			              collectionKey.key, collectionKey.collection, group);
			
			[self insertCollectionKey:collectionKey
			                  inGroup:group
			                  atIndex:count
			      withExistingPageKey:existingPageKey];
			return;
		}
	}
	
	// Otherwise:
	//
	// Binary search operation.
	//
	// This particular algorithm accounts for cases where the objects are not unique.
	// That is, if some objects are NSOrderedSame, then the algorithm returns the largest index possible
	// (within the region where elements are "equal").
	
	NSUInteger loopCount = 0;
	
	NSUInteger min = 0;
	NSUInteger max = count;
	
	while (min < max)
	{
		NSUInteger mid = (min + max) / 2;
		
		cmp = compare(mid);
		
		if (cmp == NSOrderedAscending)
			max = mid;
		else
			min = mid + 1;
		
		loopCount++;
	}
	
	YDBLogVerbose(@"Insert key(%@) collection(%@) in group(%@) took %lu comparisons",
	              collectionKey.key, collectionKey.collection, group, (unsigned long)loopCount);
	
	[self insertCollectionKey:collectionKey inGroup:group atIndex:min withExistingPageKey:existingPageKey];
	
	viewConnection->lastInsertWasAtFirstIndex = (min == 0);
	viewConnection->lastInsertWasAtLastIndex  = (min == count);
}

/**
 * Use this method (instead of removeKey:) when the pageKey and group are already known.
**/
- (void)removeCollectionKey:(YapCollectionKey *)collectionKey
                withPageKey:(NSString *)pageKey
                      group:(NSString *)group
{
	YDBLogAutoTrace();
	
	NSParameterAssert(collectionKey != nil);
	NSParameterAssert(pageKey != nil);
	NSParameterAssert(group != nil);
	
	// Fetch page & pageMetadata
	
	NSMutableArray *page = [self pageForPageKey:pageKey];
	
	YapDatabaseViewPageMetadata *pageMetadata = nil;
	NSUInteger pageOffset = 0;
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	for (YapDatabaseViewPageMetadata *pm in pagesMetadataForGroup)
	{
		if ([pm->pageKey isEqualToString:pageKey])
		{
			pageMetadata = pm;
			break;
		}
		
		pageOffset += pm->count;
	}
	
	NSAssert(pageMetadata != nil, @"Missing pageMetadata in group(%@) withPageKey(%@)", group, pageKey);
	
	// Find index within page
	
	NSUInteger keyIndexWithinPage = [page indexOfObject:collectionKey];
	if (keyIndexWithinPage == NSNotFound)
	{
		YDBLogError(@"%@ (%@): Collection(%@) Key(%@) expected to be in page(%@), but is missing",
		            THIS_METHOD, [self registeredName], collectionKey.collection, collectionKey.key, pageKey);
		return;
	}
	
	YDBLogVerbose(@"Removing collection(%@) key(%@) from page(%@) at index(%lu)",
	              collectionKey.collection, collectionKey.key, page, (unsigned long)keyIndexWithinPage);
	
	// Add change to log
	
	[viewConnection->changes addObject:
	    [YapDatabaseViewRowChange deleteKey:collectionKey inGroup:group atIndex:(pageOffset + keyIndexWithinPage)]];
	
	[viewConnection->mutatedGroups addObject:group];
	
	// Update page (by removing key from array)
	
	[page removeObjectAtIndex:keyIndexWithinPage];
	
	// Update page metadata (by decrementing count)
	
	pageMetadata->count = [page count];
	
	// Mark page as dirty
	
	YDBLogVerbose(@"Dirty page(%@)", pageKey);
	
	[viewConnection->dirtyPages setObject:page forKey:pageKey];
	[viewConnection->pageCache setObject:page forKey:pageKey];
	
	// Mark page metadata as dirty
	
	[viewConnection->dirtyMetadata setObject:pageMetadata forKey:pageKey];
	
	// Mark key for deletion
	
	[viewConnection->dirtyKeys setObject:[NSNull null] forKey:collectionKey];
	[viewConnection->keyCache removeObjectForKey:collectionKey];
}

/**
 * Use this method when you don't know if the collection/key exists in the view.
**/
- (void)removeCollectionKey:(YapCollectionKey *)collectionKey
{
	YDBLogAutoTrace();
	
	// Find out if collection/key is in view
	
	NSString *pageKey = [self pageKeyForCollectionKey:collectionKey];
	if (pageKey)
	{
		[self removeCollectionKey:collectionKey withPageKey:pageKey group:[self groupForPageKey:pageKey]];
	}
}

/**
 * Use this method to remove a set of 1 or more keys (in a single collection) from a given pageKey & group.
**/
- (void)removeKeys:(NSSet *)keys
      inCollection:(NSString *)collection
       withPageKey:(NSString *)pageKey
             group:(NSString *)group
{
	YDBLogAutoTrace();
	
	if ([keys count] == 0) return;
	if ([keys count] == 1)
	{
		NSString *key = [keys anyObject];
		YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
		
		[self removeCollectionKey:collectionKey withPageKey:pageKey group:group];
		return;
	}
	
	NSParameterAssert(collection != nil);
	NSParameterAssert(pageKey != nil);
	NSParameterAssert(group != nil);
	
	// Fetch page & pageMetadata
	
	NSMutableArray *page = [self pageForPageKey:pageKey];
	
	YapDatabaseViewPageMetadata *pageMetadata = nil;
	NSUInteger pageOffset = 0;
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	for (YapDatabaseViewPageMetadata *pm in pagesMetadataForGroup)
	{
		if ([pm->pageKey isEqualToString:pageKey])
		{
			pageMetadata = pm;
			break;
		}
		
		pageOffset += pm->count;
	}
	
	NSAssert(pageMetadata != nil, @"Missing pageMetadata in group(%@) withPageKey(%@)", group, pageKey);
	
	// Find indexes within page
	
	NSMutableIndexSet *keyIndexSet = [NSMutableIndexSet indexSet];
	NSUInteger keyIndexWithinPage = 0;
	
	NSMutableArray *collectionKeys = [NSMutableArray arrayWithCapacity:[keys count]];
	
	for (YapCollectionKey *collectionKey in page)
	{
		if ([collection isEqualToString:collectionKey.collection])
		{
			if ([keys containsObject:collectionKey.key])
			{
				[keyIndexSet addIndex:keyIndexWithinPage];
				[collectionKeys addObject:collectionKey];
			}
		}
		
		keyIndexWithinPage++;
	}
	
	if ([keyIndexSet count] != [keys count])
	{
		YDBLogWarn(@"%@ (%@): Keys expected to be in page(%@), but are missing",
		           THIS_METHOD, [self registeredName], pageKey);
	}
	
	YDBLogVerbose(@"Removing %lu key(s) from page(%@)", (unsigned long)[keyIndexSet count], page);
	
	// Add change to log
	// Notes:
	// 
	// - We have to do this before we update the page
	//     so we can fetch the keys that are being removed.
	//
	// - We must add the changes in reverse order,
	//     just as if we were deleting them from the array one-at-a-time.
	
	__block NSUInteger i = [collectionKeys count] - 1;
	[keyIndexSet enumerateIndexesWithOptions:NSEnumerationReverse
	                              usingBlock:^(NSUInteger keyIndexWithinPage, BOOL *stop) {
		
		YapCollectionKey *collectionKey = [collectionKeys objectAtIndex:i];
		i--;
									  
		[viewConnection->changes addObject:
		    [YapDatabaseViewRowChange deleteKey:collectionKey inGroup:group atIndex:(pageOffset + keyIndexWithinPage)]];
	}];
	
	[viewConnection->mutatedGroups addObject:group];
	
	// Update page (by removing keys from array)
	
	[page removeObjectsAtIndexes:keyIndexSet];
	
	// Update page metadata (by decrementing count)
	
	pageMetadata->count = [page count];
	
	// Mark page as dirty
	
	YDBLogVerbose(@"Dirty page(%@)", pageKey);
	
	[viewConnection->dirtyPages setObject:page forKey:pageKey];
	[viewConnection->pageCache setObject:page forKey:pageKey];
	
	// Mark page metadata as dirty
	
	[viewConnection->dirtyMetadata setObject:pageMetadata forKey:pageKey];
	
	// Mark keys for deletion
	
	for (YapCollectionKey *collectionKey in collectionKeys)
	{
		[viewConnection->dirtyKeys setObject:[NSNull null] forKey:collectionKey];
		[viewConnection->keyCache removeObjectForKey:collectionKey];
	}
}

- (void)removeAllKeysInAllCollections
{
	YDBLogAutoTrace();
	
	sqlite3_stmt *keyStatement = [viewConnection keyTable_removeAllStatement];
	sqlite3_stmt *pageStatement = [viewConnection pageTable_removeAllStatement];
	
	if (keyStatement == NULL || pageStatement == NULL)
		return;
	
	int status;
	
	// DELETE FROM "keyTableName";
	
	YDBLogVerbose(@"DELETE FROM '%@';", [self keyTableName]);
	
	status = sqlite3_step(keyStatement);
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"%@ (%@): Error in keyStatement: %d %s",
		            THIS_METHOD, [self registeredName],
		            status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	// DELETE FROM 'pageTableName';
	
	YDBLogVerbose(@"DELETE FROM '%@';", [self pageTableName]);
	
	status = sqlite3_step(pageStatement);
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"%@ (%@): Error in pageStatement: %d %s",
		            THIS_METHOD, [self registeredName],
		            status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_reset(keyStatement);
	sqlite3_reset(pageStatement);
	
	for (NSString *group in viewConnection->group_pagesMetadata_dict)
	{
		[viewConnection->changes addObject:[YapDatabaseViewSectionChange resetGroup:group]];
		[viewConnection->mutatedGroups addObject:group];
	}
	
	[viewConnection->group_pagesMetadata_dict removeAllObjects];
	[viewConnection->pageKey_group_dict removeAllObjects];
	
	[viewConnection->keyCache removeAllObjects];
	[viewConnection->pageCache removeAllObjects];
	
	[viewConnection->dirtyKeys removeAllObjects];
	[viewConnection->dirtyPages removeAllObjects];
	[viewConnection->dirtyMetadata removeAllObjects];
	
	viewConnection->reset = YES;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Cleanup & Commit
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)splitOversizedPage:(YapDatabaseViewPageMetadata *)pageMetadata
{
	YDBLogAutoTrace();
	
	NSUInteger maxPageSize = YAP_DATABASE_VIEW_MAX_PAGE_SIZE;
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:pageMetadata->group];
	
	while (pageMetadata->count > maxPageSize)
	{
		NSUInteger pageIndex = [pagesMetadataForGroup indexOfObjectIdenticalTo:pageMetadata];
		
		// Check to see if there's room in the previous page
		
		if (pageIndex > 0)
		{
			YapDatabaseViewPageMetadata *prevPageMetadata = [pagesMetadataForGroup objectAtIndex:(pageIndex - 1)];
			
			if (prevPageMetadata->count < maxPageSize)
			{
				// Move objects from beginning of page to end of previous page
				
				NSMutableArray *page = [self pageForPageKey:pageMetadata->pageKey];
				NSMutableArray *prevPage = [self pageForPageKey:prevPageMetadata->pageKey];
				
				NSUInteger excessInPage = pageMetadata->count - maxPageSize;
				NSUInteger spaceInPrevPage = maxPageSize - prevPageMetadata->count;
				
				NSUInteger numToMove = MIN(excessInPage, spaceInPrevPage);
				
				NSRange pageRange = NSMakeRange(0, numToMove);                    // beginning range
				NSRange prevPageRange = NSMakeRange([prevPage count], numToMove); // end range
				
				NSArray *subset = [page subarrayWithRange:pageRange];
				
				[page removeObjectsInRange:pageRange];
				[prevPage insertObjects:subset atIndexes:[NSIndexSet indexSetWithIndexesInRange:prevPageRange]];
				
				// Update counts
				
				pageMetadata->count = [page count];
				prevPageMetadata->count = [prevPage count];
				
				// Mark prevPage & prevPageMetadata as dirty.
				// The page & pageMetadata are already marked as dirty.
				
				[viewConnection->dirtyPages setObject:prevPage forKey:prevPageMetadata->pageKey];
				[viewConnection->pageCache setObject:prevPage forKey:prevPageMetadata->pageKey];
				
				[viewConnection->dirtyMetadata setObject:prevPageMetadata forKey:prevPageMetadata->pageKey];
				
				// Mark keys as dirty
				
				for (NSString *key in subset)
				{
					[viewConnection->dirtyKeys setObject:prevPageMetadata->pageKey forKey:key];
					[viewConnection->keyCache setObject:prevPageMetadata->pageKey forKey:key];
				}
				
				continue;
			}
		}
		
		// Check to see if there's room in the next page
		
		if ((pageIndex + 1) < [pagesMetadataForGroup count])
		{
			YapDatabaseViewPageMetadata *nextPageMetadata = [pagesMetadataForGroup objectAtIndex:(pageIndex + 1)];
			
			if (nextPageMetadata->count < maxPageSize)
			{
				// Move objects from end of page to beginning of next page
				
				NSMutableArray *page = [self pageForPageKey:pageMetadata->pageKey];
				NSMutableArray *nextPage = [self pageForPageKey:nextPageMetadata->pageKey];
				
				NSUInteger excessInPage = pageMetadata->count - maxPageSize;
				NSUInteger spaceInNextPage = maxPageSize - nextPageMetadata->count;
				
				NSUInteger numToMove = MIN(excessInPage, spaceInNextPage);
				
				NSRange pageRange = NSMakeRange([page count] - numToMove, numToMove); // end range
				NSRange nextPageRange = NSMakeRange(0, numToMove);                    // beginning range
				
				NSArray *subset = [page subarrayWithRange:pageRange];
				
				[page removeObjectsInRange:pageRange];
				[nextPage insertObjects:subset atIndexes:[NSIndexSet indexSetWithIndexesInRange:nextPageRange]];
				
				// Update counts
				
				pageMetadata->count = [page count];
				nextPageMetadata->count = [nextPage count];
				
				// Mark nextPage & nextPageMetadata as dirty.
				// The page & pageMetadata are already marked as dirty.
				
				[viewConnection->dirtyPages setObject:nextPage forKey:nextPageMetadata->pageKey];
				[viewConnection->pageCache setObject:nextPage forKey:nextPageMetadata->pageKey];
				
				[viewConnection->dirtyMetadata setObject:nextPageMetadata forKey:nextPageMetadata->pageKey];
				
				// Mark keys as dirty
				
				for (NSString *key in subset)
				{
					[viewConnection->dirtyKeys setObject:nextPageMetadata->pageKey forKey:key];
					[viewConnection->keyCache setObject:nextPageMetadata->pageKey forKey:key];
				}
				
				continue;
			}
		}
	
		// Create new page and pageMetadata.
		// Insert into array.
		
		NSUInteger excessInPage = pageMetadata->count - maxPageSize;
		NSUInteger numToMove = MIN(excessInPage, maxPageSize);
		
		NSString *newPageKey = [self generatePageKey];
		NSMutableArray *newPage = [[NSMutableArray alloc] initWithCapacity:numToMove];
		
		// Create new pageMetadata
		
		YapDatabaseViewPageMetadata *newPageMetadata = [[YapDatabaseViewPageMetadata alloc] init];
		newPageMetadata->pageKey = newPageKey;
		newPageMetadata->group = pageMetadata->group;
		
		// Insert new pageMetadata into array & update linked-list
	
		[pagesMetadataForGroup insertObject:newPageMetadata atIndex:(pageIndex + 1)];
		
		[viewConnection->pageKey_group_dict setObject:newPageMetadata->group
		                                       forKey:newPageMetadata->pageKey];
		
		if ((pageIndex + 2) < [pagesMetadataForGroup count])
		{
			YapDatabaseViewPageMetadata *nextPageMetadata = [pagesMetadataForGroup objectAtIndex:(pageIndex + 2)];
			
			pageMetadata->nextPageKey = newPageKey;
			
			newPageMetadata->prevPageKey = pageMetadata->pageKey;
			newPageMetadata->nextPageKey = nextPageMetadata->pageKey;
			
			nextPageMetadata->prevPageKey = newPageKey; // prevPageKey property is persistent
			
			[viewConnection->dirtyMetadata setObject:nextPageMetadata forKey:nextPageMetadata->pageKey];
		}
		else
		{
			pageMetadata->nextPageKey = newPageKey;
			
			newPageMetadata->prevPageKey = pageMetadata->pageKey;
			newPageMetadata->nextPageKey = nil;
		}
		
		// Move objects from end of page to beginning of new page
		
		NSMutableArray *page = [self pageForPageKey:pageMetadata->pageKey];
		
		NSRange pageRange = NSMakeRange([page count] - numToMove, numToMove); // end range
		
		NSArray *subset = [page subarrayWithRange:pageRange];
		
		[page removeObjectsInRange:pageRange];
		[newPage addObjectsFromArray:subset];
		
		// Update counts
		
		pageMetadata->count = [page count];
		newPageMetadata->count = [newPage count];
		
		// Mark page & pageMetadata as dirty
		
		[viewConnection->dirtyPages setObject:newPage forKey:newPageKey];
		[viewConnection->pageCache setObject:newPage forKey:newPageKey];
		
		[viewConnection->dirtyMetadata setObject:newPageMetadata forKey:newPageKey];
		
		// Mark keys as dirty
		
		for (NSString *key in subset)
		{
			[viewConnection->dirtyKeys setObject:newPageKey forKey:key];
			[viewConnection->keyCache setObject:newPageKey forKey:key];
		}
		
	} // end while (pageMetadata->count > maxPageSize)
}

- (void)dropEmptyPage:(YapDatabaseViewPageMetadata *)pageMetadata
{
	YDBLogAutoTrace();
	
	// Find page
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:pageMetadata->group];
	
	NSUInteger pageIndex = [pagesMetadataForGroup indexOfObjectIdenticalTo:pageMetadata];
	
	// Update surrounding pages
	
	if (pageIndex > 0)
	{
		YapDatabaseViewPageMetadata *prevPageMetadata = [pagesMetadataForGroup objectAtIndex:(pageIndex - 1)];
		prevPageMetadata->nextPageKey = pageMetadata->nextPageKey;
		
		// The nextPageKey property is transient (not saved to disk).
		// So this change doesn't affect on-disk representation.
	}
	
	if ((pageIndex + 1) < [pagesMetadataForGroup count])
	{
		YapDatabaseViewPageMetadata *nextPageMetadata = [pagesMetadataForGroup objectAtIndex:(pageIndex + 1)];
		nextPageMetadata->prevPageKey = pageMetadata->prevPageKey;
		
		// The prevPageKey property is persistent (saved to disk).
		// So this change affects the on-disk representation.
		
		[viewConnection->dirtyMetadata setObject:nextPageMetadata forKey:nextPageMetadata->pageKey];
	}
	
	// Drop page
	
	[pagesMetadataForGroup removeObjectAtIndex:pageIndex];
	[viewConnection->pageKey_group_dict removeObjectForKey:pageMetadata->pageKey];
	
	// Mark page as dropped
	
	[viewConnection->dirtyPages setObject:[NSNull null] forKey:pageMetadata->pageKey];
	[viewConnection->pageCache removeObjectForKey:pageMetadata->pageKey];
	
	// Mark page metadata as dropped
	
	[viewConnection->dirtyMetadata setObject:[NSNull null] forKey:pageMetadata->pageKey];
	
	// Maybe drop group
	
	if ([pagesMetadataForGroup count] == 0)
	{
		YDBLogVerbose(@"Dropping empty group(%@)", pageMetadata->group);
		
		[viewConnection->changes addObject:
		    [YapDatabaseViewSectionChange deleteGroup:pageMetadata->group]];
		
		[viewConnection->group_pagesMetadata_dict removeObjectForKey:pageMetadata->group];
	}
}

/**
 * This method is only called if within a readwrite transaction.
 *
 * Extensions may implement it to perform any "cleanup" before the changeset is requested.
 * Remember, the changeset is requested before the commitTransaction method is invoked.
**/
- (void)preCommitReadWriteTransaction
{
	YDBLogAutoTrace();
	
	// During the readwrite transaction we do nothing to enforce the pageSize restriction.
	// Multiple modifications during a transaction make it non worthwhile.
	//
	// Instead we wait til the transaction has completed
	// and then we can perform all such cleanup in a single step.
	
	NSUInteger maxPageSize = YAP_DATABASE_VIEW_MAX_PAGE_SIZE;
	
	// Get all the dirty pageMetadata objects.
	// We snapshot the items so we can make modifications as we enumerate.
	
	NSArray *allDirtyPageMetadata = [viewConnection->dirtyMetadata allValues];
	
	// Step 1 is to "expand" the oversized pages.
	//
	// This means either splitting them in 2,
	// or allowing items to spill over into a neighboring page (that has room).
	
	for (YapDatabaseViewPageMetadata *pageMetadata in allDirtyPageMetadata)
	{
		if (pageMetadata->count > maxPageSize)
		{
			[self splitOversizedPage:pageMetadata];
		}
	}
	
	// Step 2 is to "collapse" undersized pages.
	//
	// This means dropping empty pages,
	// and maybe combining a page with a neighboring page (that has room).
	//
	// Note: We do this after "expansion" to allow undersized pages to first accomodate overflow.
	
	for (YapDatabaseViewPageMetadata *pageMetadata in allDirtyPageMetadata)
	{
		if (pageMetadata->count == 0)
		{
			[self dropEmptyPage:pageMetadata];
		}
	}
}

- (void)commitTransaction
{
	YDBLogAutoTrace();
	
	// During the transaction we stored all changes in the "dirty" dictionaries.
	// This allows the view to make multiple changes to a page, yet only write it once.
	
	YDBLogVerbose(@"viewConnection->dirtyPages: %@", viewConnection->dirtyPages);
	YDBLogVerbose(@"viewConnection->dirtyMetadata: %@", viewConnection->dirtyMetadata);
	YDBLogVerbose(@"viewConnection->dirtyKeys: %@", viewConnection->dirtyKeys);
	
	// Write dirty pages to table (along with associated dirty metadata)
	
	[viewConnection->dirtyPages enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
		
		NSString *pageKey = (NSString *)key;
		NSMutableArray *page = (NSMutableArray *)obj;
		
		YapDatabaseViewPageMetadata *pageMetadata = [viewConnection->dirtyMetadata objectForKey:pageKey];
		if (pageMetadata == nil)
		{
			YDBLogError(@"%@ (%@): Missing metadata for dirty page with pageKey: %@",
			            THIS_METHOD, [self registeredName], pageKey);
			return;//continue;
		}
		
		if ((id)page == (id)[NSNull null])
		{
			sqlite3_stmt *statement = [viewConnection pageTable_removeForPageKeyStatement];
			if (statement == NULL)
			{
				*stop = YES;
				return;//continue;
			}
			
			// DELETE FROM "pageTableName" WHERE "pageKey" = ?;
			
			YDBLogVerbose(@"DELETE FROM '%@' WHERE 'pageKey' = ?;\n"
			              @" - pageKey: %@", [self pageTableName], pageKey);
			
			YapDatabaseString _pageKey; MakeYapDatabaseString(&_pageKey, pageKey);
			sqlite3_bind_text(statement, 1, _pageKey.str, _pageKey.length, SQLITE_STATIC);
			
			int status = sqlite3_step(statement);
			if (status != SQLITE_DONE)
			{
				YDBLogError(@"%@ (%@): Error executing statement[1a]: %d %s",
				            THIS_METHOD, [self registeredName],
				            status, sqlite3_errmsg(databaseTransaction->connection->db));
			}
			
			sqlite3_clear_bindings(statement);
			sqlite3_reset(statement);
			FreeYapDatabaseString(&_pageKey);
		}
		else
		{
			sqlite3_stmt *statement = [viewConnection pageTable_setAllForPageKeyStatement];
			if (statement == NULL)
			{
				*stop = YES;
				return;//continue;
			}
			
			// INSERT OR REPLACE INTO "pageTableName" ("pageKey", "data", "metadata") VALUES (?, ?, ?);
			
			YDBLogVerbose(@"INSERT OR REPLACE INTO '%@' ('pageKey', 'data', 'metadata) VALUES (?, ?, ?);\n"
			              @" - pageKey : %@\n"
			              @" - data    : %@\n"
			              @" - metadata: %@", [self pageTableName], pageKey, page, pageMetadata);
			
			YapDatabaseString _pageKey; MakeYapDatabaseString(&_pageKey, pageKey);
			sqlite3_bind_text(statement, 1, _pageKey.str, _pageKey.length, SQLITE_STATIC);
			
			__attribute__((objc_precise_lifetime)) NSData *rawData = [self serializePage:page];
			sqlite3_bind_blob(statement, 2, rawData.bytes, (int)rawData.length, SQLITE_STATIC);
			
			__attribute__((objc_precise_lifetime)) NSData *rawMeta = [self serializeMetadata:pageMetadata];
			sqlite3_bind_blob(statement, 3, rawMeta.bytes, (int)rawMeta.length, SQLITE_STATIC);
			
			int status = sqlite3_step(statement);
			if (status != SQLITE_DONE)
			{
				YDBLogError(@"%@ (%@): Error executing statement[1b]: %d %s",
				            THIS_METHOD, [self registeredName],
				            status, sqlite3_errmsg(databaseTransaction->connection->db));
			}
			
			sqlite3_clear_bindings(statement);
			sqlite3_reset(statement);
			FreeYapDatabaseString(&_pageKey);
		}
	}];
	
	// Write dirty page metadata to table (those not associated with dirty pages).
	// This happens when the nextPageKey pointer is changed.
	
	[viewConnection->dirtyMetadata enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
		
		NSString *pageKey = (NSString *)key;
		YapDatabaseViewPageMetadata *pageMetadata = (YapDatabaseViewPageMetadata *)obj;
		
		if ([viewConnection->dirtyPages objectForKey:pageKey])
		{
			// Both the page and metadata were dirty, so we wrote them both to disk at the same time.
			// No need to write the metadata again.
			
			return;//continue;
		}
		
		if ((id)pageMetadata == (id)[NSNull null])
		{
			// This shouldn't happen
			
			YDBLogWarn(@"%@ (%@): NULL metadata without matching dirty page with pageKey: %@",
			           THIS_METHOD, [self registeredName], pageKey);
		}
		else
		{
			sqlite3_stmt *statement = [viewConnection pageTable_setMetadataForPageKeyStatement];
			if (statement == NULL)
			{
				*stop = YES;
				return;//continue;
			}
			
			// UPDATE "pageTableName" SET "metadata" = ? WHERE "pageKey" = ?;
			
			YDBLogVerbose(@"UPDATE '%@' SET 'metadata' = ? WHERE 'pageKey' = ?;\n"
			              @" - metadata: %@\n"
			              @" - pageKey : %@", [self pageTableName], pageMetadata, pageKey);
			
			__attribute__((objc_precise_lifetime)) NSData *rawMeta = [self serializeMetadata:pageMetadata];
			sqlite3_bind_blob(statement, 1, rawMeta.bytes, (int)rawMeta.length, SQLITE_STATIC);
			
			YapDatabaseString _pageKey; MakeYapDatabaseString(&_pageKey, pageKey);
			sqlite3_bind_text(statement, 2, _pageKey.str, _pageKey.length, SQLITE_STATIC);
			
			int status = sqlite3_step(statement);
			if (status != SQLITE_DONE)
			{
				YDBLogError(@"%@ (%@): Error executing statement[2]: %d %s",
				            THIS_METHOD, [self registeredName],
				            status, sqlite3_errmsg(databaseTransaction->connection->db));
			}
			
			sqlite3_clear_bindings(statement);
			sqlite3_reset(statement);
			FreeYapDatabaseString(&_pageKey);
		}
	}];
	
	// Update the dirty key -> pageKey mappings.
	// We do this at the end because keys may get moved around from
	// page to page during processing, and page consolidation/expansion.
	
	[viewConnection->dirtyKeys enumerateKeysAndObjectsUsingBlock:^(id collectionKeyObj, id pageKeyObj, BOOL *stop) {
		
		__unsafe_unretained YapCollectionKey *collectionKey = (YapCollectionKey *)collectionKeyObj;
		__unsafe_unretained NSString *pageKey = (NSString *)pageKeyObj;
		
		if ((id)pageKey == (id)[NSNull null])
		{
			sqlite3_stmt *statement = [viewConnection keyTable_removeForCollectionKeyStatement];
			if (statement == NULL)
			{
				*stop = YES;
				return;//continue;
			}
			
			// DELETE FROM "keyTableName" WHERE "collection" = ? AND "key" = ?;
			
			YDBLogVerbose(@"DELETE FROM '%@' WHERE 'collection' = ? AND'key' = ?;\n"
			              @" - collection : %@\n"
						  @" - key : %@", [self keyTableName], collectionKey.collection, collectionKey.key);
			
			YapDatabaseString _collection; MakeYapDatabaseString(&_collection, collectionKey.collection);
			sqlite3_bind_text(statement, 1, _collection.str, _collection.length, SQLITE_STATIC);
			
			YapDatabaseString _key; MakeYapDatabaseString(&_key, collectionKey.key);
			sqlite3_bind_text(statement, 2, _key.str, _key.length, SQLITE_STATIC);
			
			int status = sqlite3_step(statement);
			if (status != SQLITE_DONE)
			{
				YDBLogError(@"%@ (%@): Error executing statement[3a]: %d %s",
				            THIS_METHOD, [self registeredName],
				            status, sqlite3_errmsg(databaseTransaction->connection->db));
			}
			
			sqlite3_clear_bindings(statement);
			sqlite3_reset(statement);
			FreeYapDatabaseString(&_collection);
			FreeYapDatabaseString(&_key);
		}
		else
		{
			sqlite3_stmt *statement = [viewConnection keyTable_setPageKeyForCollectionKeyStatement];
			if (statement == NULL)
			{
				*stop = YES;
				return;//continue;
			}
			
			// INSERT OR REPLACE INTO "keyTableName" ("collection", "key", "pageKey") VALUES (?, ?, ?);
			
			YDBLogVerbose(@"INSERT OR REPLACE INTO '%@' ('collection', 'key', 'pageKey') VALUES (?, ?);\n"
			              @" - collection: %@\n"
			              @" - key       : %@\n"
			              @" - pageKey   : %@",
			              [self keyTableName], collectionKey.collection, collectionKey.key, pageKey);
			
			YapDatabaseString _collection; MakeYapDatabaseString(&_collection, collectionKey.collection);
			sqlite3_bind_text(statement, 1, _collection.str, _collection.length, SQLITE_STATIC);
			
			YapDatabaseString _key; MakeYapDatabaseString(&_key, collectionKey.key);
			sqlite3_bind_text(statement, 2, _key.str, _key.length, SQLITE_STATIC);
			
			YapDatabaseString _pageKey; MakeYapDatabaseString(&_pageKey, pageKey);
			sqlite3_bind_text(statement, 3, _pageKey.str, _pageKey.length, SQLITE_STATIC);
			
			int status = sqlite3_step(statement);
			if (status != SQLITE_DONE)
			{
				YDBLogError(@"%@ (%@): Error executing statement[3b]: %d %s",
				            THIS_METHOD, [self registeredName],
				            status, sqlite3_errmsg(databaseTransaction->connection->db));
			}
			
			sqlite3_clear_bindings(statement);
			sqlite3_reset(statement);
			FreeYapDatabaseString(&_collection);
			FreeYapDatabaseString(&_key);
		}
	}];
	
	[viewConnection postCommitCleanup];
	
	// An extensionTransaction is only valid within the scope of its encompassing databaseTransaction.
	// I imagine this may occasionally be misunderstood, and developers may attempt to store the extension in an ivar,
	// and then use it outside the context of the database transaction block.
	// Thus, this code is here as a safety net to ensure that such accidental misuse doesn't do any damage.
	
	viewConnection = nil;      // Do not remove !
	databaseTransaction = nil; // Do not remove !
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark YapAbstractDatabaseExtensionTransaction_CollectionKeyValue
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * YapCollectionsDatabase extension hook.
 * This method is invoked by a YapCollectionsDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleSetObject:(id)object forKey:(NSString *)key inCollection:(NSString *)collection withMetadata:(id)metadata
{
	YDBLogAutoTrace();
	
	NSParameterAssert(key != nil);
	NSParameterAssert(collection != nil);
	
	__unsafe_unretained YapCollectionsDatabaseView *view = viewConnection->view;
	
	// Invoke the grouping block to find out if the object should be included in the view.
	
	NSString *group;
	
	if (view->groupingBlockType == YapCollectionsDatabaseViewBlockTypeWithKey)
	{
		__unsafe_unretained YapCollectionsDatabaseViewGroupingWithKeyBlock groupingBlock =
		    (YapCollectionsDatabaseViewGroupingWithKeyBlock)view->groupingBlock;
		
		group = groupingBlock(collection, key);
	}
	else if (view->groupingBlockType == YapCollectionsDatabaseViewBlockTypeWithObject)
	{
		__unsafe_unretained YapCollectionsDatabaseViewGroupingWithObjectBlock groupingBlock =
		    (YapCollectionsDatabaseViewGroupingWithObjectBlock)view->groupingBlock;
		
		group = groupingBlock(collection, key, object);
	}
	else if (view->groupingBlockType == YapCollectionsDatabaseViewBlockTypeWithMetadata)
	{
		__unsafe_unretained YapCollectionsDatabaseViewGroupingWithMetadataBlock groupingBlock =
		    (YapCollectionsDatabaseViewGroupingWithMetadataBlock)view->groupingBlock;
		
		group = groupingBlock(collection, key, metadata);
	}
	else
	{
		__unsafe_unretained YapCollectionsDatabaseViewGroupingWithRowBlock groupingBlock =
		    (YapCollectionsDatabaseViewGroupingWithRowBlock)view->groupingBlock;
		
		group = groupingBlock(collection, key, object, metadata);
	}
	
	YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
	
	if (group == nil)
	{
		// Remove key from view (if needed)
		
		[self removeCollectionKey:collectionKey];
	}
	else
	{
		// Add key to view (or update position)
		
		int flags = (YapDatabaseViewChangeColumnObject | YapDatabaseViewChangeColumnMetadata);
		[self insertObject:object metadata:metadata
		                  forCollectionKey:collectionKey
		                           inGroup:group
		               withModifiedColumns:flags
		                             isNew:NO];
	}
}

/**
 * YapCollectionsDatabase extension hook.
 * This method is invoked by a YapCollectionsDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleSetMetadata:(id)metadata forKey:(NSString *)key inCollection:(NSString *)collection
{
	YDBLogAutoTrace();
	
	NSParameterAssert(key != nil);
	NSParameterAssert(collection != nil);
	
	__unsafe_unretained YapCollectionsDatabaseView *view = viewConnection->view;
	
	YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
	
	// Invoke the grouping block to find out if the object should be included in the view.
	
	id object = nil;
	NSString *group = nil;
	
	if (view->groupingBlockType == YapCollectionsDatabaseViewBlockTypeWithKey ||
	    view->groupingBlockType == YapCollectionsDatabaseViewBlockTypeWithObject)
	{
		// Grouping is based on the key or object.
		// Neither have changed, and thus the group hasn't changed.
		
		NSString *pageKey = [self pageKeyForCollectionKey:collectionKey];
		group = [self groupForPageKey:pageKey];
		
		if (group == nil)
		{
			// Nothing to do.
			// The key wasn't previously in the view, and still isn't in the view.
			return;
		}
		
		if (view->sortingBlockType == YapCollectionsDatabaseViewBlockTypeWithKey ||
		    view->sortingBlockType == YapCollectionsDatabaseViewBlockTypeWithObject)
		{
			// Nothing has moved because the group hasn't changed and
			// nothing has changed that relates to sorting.
			
			int flags = YapDatabaseViewChangeColumnMetadata;
			NSUInteger existingIndex = [self indexForCollectionKey:collectionKey inGroup:group withPageKey:pageKey];
			
			[viewConnection->changes addObject:
			    [YapDatabaseViewRowChange updateKey:collectionKey columns:flags inGroup:group atIndex:existingIndex]];
		}
		else
		{
			// Sorting is based on the metadata, which has changed.
			// So the sort order may possibly have changed.
			
			// From previous if statement (above) we know:
			// sortingBlockType is metadata or objectAndMetadata
			
			if (view->sortingBlockType == YapCollectionsDatabaseViewBlockTypeWithRow)
			{
				// Need the object for the sorting block
				object = [databaseTransaction objectForKey:key inCollection:collection];
			}
			
			int flags = YapDatabaseViewChangeColumnMetadata;
			[self insertObject:object metadata:metadata
			                  forCollectionKey:collectionKey
			                           inGroup:group
			               withModifiedColumns:flags
			                             isNew:NO];
		}
	}
	else
	{
		// Grouping is based on metadata or objectAndMetadata.
		// Invoke groupingBlock to see what the new group is.
		
		if (view->groupingBlockType == YapCollectionsDatabaseViewBlockTypeWithMetadata)
		{
			__unsafe_unretained YapCollectionsDatabaseViewGroupingWithMetadataBlock groupingBlock =
		        (YapCollectionsDatabaseViewGroupingWithMetadataBlock)view->groupingBlock;
			
			group = groupingBlock(collection, key, metadata);
		}
		else
		{
			__unsafe_unretained YapCollectionsDatabaseViewGroupingWithRowBlock groupingBlock =
		        (YapCollectionsDatabaseViewGroupingWithRowBlock)view->groupingBlock;
			
			object = [databaseTransaction objectForKey:key inCollection:collection];
			group = groupingBlock(collection, key, object, metadata);
		}
		
		if (group == nil)
		{
			// The key is not included in the view.
			// Remove key from view (if needed).
			
			[self removeCollectionKey:collectionKey];
		}
		else
		{
			if (view->sortingBlockType == YapCollectionsDatabaseViewBlockTypeWithKey ||
			    view->sortingBlockType == YapCollectionsDatabaseViewBlockTypeWithObject)
			{
				// Sorting is based on the key or object, neither of which has changed.
				// So if the group hasn't changed, then the sort order hasn't changed.
				
				NSString *existingPageKey = [self pageKeyForCollectionKey:collectionKey];
				NSString *existingGroup = [self groupForPageKey:existingPageKey];
				
				if ([group isEqualToString:existingGroup])
				{
					// Nothing left to do.
					// The group didn't change, and the sort order cannot change (because the object didn't change).
					
					int flags = YapDatabaseViewChangeColumnMetadata;
					NSUInteger existingIndex = [self indexForCollectionKey:collectionKey
					                                               inGroup:group
					                                           withPageKey:existingPageKey];
					
					[viewConnection->changes addObject:
					    [YapDatabaseViewRowChange updateKey:collectionKey
					                                columns:flags
					                                inGroup:group
					                                atIndex:existingIndex]];
					return;
				}
			}
			
			if (object == nil && (view->sortingBlockType == YapCollectionsDatabaseViewBlockTypeWithObject ||
			                      view->sortingBlockType == YapCollectionsDatabaseViewBlockTypeWithRow    ))
			{
				// Need the object for the sorting block
				object = [databaseTransaction objectForKey:key inCollection:collection];
			}
			
			int flags = YapDatabaseViewChangeColumnMetadata;
			[self insertObject:object metadata:metadata
			                  forCollectionKey:collectionKey
			                           inGroup:group
			               withModifiedColumns:flags
			                             isNew:NO];
		}
	}
}

/**
 * YapCollectionsDatabase extension hook.
 * This method is invoked by a YapCollectionsDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleRemoveObjectForKey:(NSString *)key inCollection:(NSString *)collection
{
	YDBLogAutoTrace();
	
	NSParameterAssert(key != nil);
	NSParameterAssert(collection != nil);
	
	YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
	
	[self removeCollectionKey:collectionKey];
}

/**
 * YapCollectionsDatabase extension hook.
 * This method is invoked by a YapCollectionsDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleRemoveObjectsForKeys:(NSArray *)keys inCollection:(NSString *)collection
{
	YDBLogAutoTrace();
	
	NSParameterAssert(collection != nil);
	
	NSDictionary *dict = [self pageKeysForKeys:keys inCollection:collection];
	
	// dict.key = pageKey
	// dict.value = NSSet of keys within page (that match given keys & collection)
	
	[dict enumerateKeysAndObjectsUsingBlock:^(id pageKeyObj, id keysInPageObj, BOOL *stop) {
		
		__unsafe_unretained NSString *pageKey = (NSString *)pageKeyObj;
		__unsafe_unretained NSSet *keysInPage = (NSSet *)keysInPageObj;
		
		[self removeKeys:keysInPage inCollection:collection withPageKey:pageKey group:[self groupForPageKey:pageKey]];
	}];
}

/**
 * YapCollectionsDatabase extension hook.
 * This method is invoked by a YapCollectionsDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleRemoveAllObjectsInCollection:(NSString *)collection
{
	YDBLogAutoTrace();
	
	NSParameterAssert(collection != nil);
	
	NSDictionary *dict = [self pageKeysAndKeysForCollection:collection];
	
	// dict.key = pageKey
	// dict.value = NSSet of keys within page (that match given collection)
	
	[dict enumerateKeysAndObjectsUsingBlock:^(id pageKeyObj, id keysInPageObj, BOOL *stop) {
		
		__unsafe_unretained NSString *pageKey = (NSString *)pageKeyObj;
		__unsafe_unretained NSSet *keysInPage = (NSSet *)keysInPageObj;
		
		[self removeKeys:keysInPage inCollection:collection withPageKey:pageKey group:[self groupForPageKey:pageKey]];
	}];
}

/**
 * YapCollectionsDatabase extension hook.
 * This method is invoked by a YapCollectionsDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleRemoveAllObjectsInAllCollections
{
	YDBLogAutoTrace();
	
	[self removeAllKeysInAllCollections];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Public API
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSUInteger)numberOfGroups
{
	return [viewConnection->group_pagesMetadata_dict count];
}

- (NSArray *)allGroups
{
	return [viewConnection->group_pagesMetadata_dict allKeys];
}

- (NSUInteger)numberOfKeysInGroup:(NSString *)group
{
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	NSUInteger count = 0;
	
	for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
	{
		count += pageMetadata->count;
	}
	
	return count;
}

- (NSUInteger)numberOfKeysInAllGroups
{
	NSUInteger count = 0;
	
	for (NSMutableArray *pagesForSection in [viewConnection->group_pagesMetadata_dict objectEnumerator])
	{
		for (YapDatabaseViewPageMetadata *pageMetadata in pagesForSection)
		{
			count += pageMetadata->count;
		}
	}
	
	return count;
}

- (BOOL)getKey:(NSString **)keyPtr
    collection:(NSString **)collectionPtr
       atIndex:(NSUInteger)index
       inGroup:(NSString *)group
{
	YapCollectionKey *collectionKey = nil;
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	NSUInteger pageOffset = 0;
	
	for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
	{
		if ((index < (pageOffset + pageMetadata->count)) && (pageMetadata->count > 0))
		{
			NSMutableArray *page = [self pageForPageKey:pageMetadata->pageKey];
			
			collectionKey = [page objectAtIndex:(index - pageOffset)];
			break;
		}
		else
		{
			pageOffset += pageMetadata->count;
		}
	}
	
	if (collectionKey)
	{
		if (collectionPtr) *collectionPtr = collectionKey.collection;
		if (keyPtr) *keyPtr = collectionKey.key;
		
		return YES;
	}
	else
	{
		if (collectionPtr) *collectionPtr = nil;
		if (keyPtr) *keyPtr = nil;
		
		return NO;
	}
}

- (BOOL)getFirstKey:(NSString **)keyPtr collection:(NSString **)collectionPtr inGroup:(NSString *)group
{
	return [self getKey:keyPtr collection:collectionPtr atIndex:0 inGroup:group];
}

- (BOOL)getLastKey:(NSString **)keyPtr collection:(NSString **)collectionPtr inGroup:(NSString *)group
{
	// We can actually do something a little faster than this:
	//
	// NSUInteger count = [self numberOfKeysInGroup:group];
	// if (count > 0) {
	// 	return [self getKey:keyPtr collection:collectionPtr atIndex:(count-1) inGroup:group];
	// }
	// else {
	// 	if (keyPtr) *keyPtr = nil;
	// 	if (collectionPtr) *collectionPtr = nil;
	// 	return NO;
	// }
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];

	__block YapCollectionKey *lastCollectionKey = nil;
	
	[pagesMetadataForGroup enumerateObjectsWithOptions:NSEnumerationReverse
	                                        usingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		
		__unsafe_unretained YapDatabaseViewPageMetadata *pageMetadata = (YapDatabaseViewPageMetadata *)obj;
		
		if (pageMetadata->count > 0)
		{
			NSMutableArray *lastPage = [self pageForPageKey:pageMetadata->pageKey];
			
			lastCollectionKey = [lastPage lastObject];
			*stop = YES;
		}
	}];
	
	if (keyPtr) *keyPtr = lastCollectionKey.key;
	if (collectionPtr) *collectionPtr = lastCollectionKey.collection;
	
	return (lastCollectionKey != nil);
}

- (NSString *)collectionAtIndex:(NSUInteger)index inGroup:(NSString *)group
{
	NSString *collection = nil;
	[self getKey:NULL collection:&collection atIndex:index inGroup:group];
	
	return collection;
}

- (NSString *)keyAtIndex:(NSUInteger)index inGroup:(NSString *)group
{
	NSString *key = nil;
	[self getKey:&key collection:NULL atIndex:index inGroup:group];
	
	return key;
}

- (NSString *)groupForKey:(NSString *)key inCollection:(NSString *)collection
{
	if (key == nil)
		return nil;
	
	if (collection == nil)
		collection = @"";
	
	YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
	
	return [self groupForPageKey:[self pageKeyForCollectionKey:collectionKey]];
}

- (BOOL)getGroup:(NSString **)groupPtr
           index:(NSUInteger *)indexPtr
          forKey:(NSString *)key
	inCollection:(NSString *)collection
{
	if (key == nil)
	{
		if (groupPtr) *groupPtr = nil;
		if (indexPtr) *indexPtr = 0;
		
		return NO;
	}
	
	if (collection == nil)
		collection = @"";
	
	YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
	
	BOOL found = NO;
	NSString *group = nil;
	NSUInteger index = 0;
	
	// Query the database to see if the given key is in the view.
	// If it is, the query will return the corresponding page the key is in.
	
	NSString *pageKey = [self pageKeyForCollectionKey:collectionKey];
	if (pageKey)
	{
		// Now that we have the pageKey, fetch the corresponding group.
		// This is done using an in-memory cache.
		
		group = [self groupForPageKey:pageKey];
		
		// Calculate the offset of the corresponding page within the group.
		
		NSUInteger pageOffset = 0;
		NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
		
		for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
		{
			if ([pageMetadata->pageKey isEqualToString:pageKey])
			{
				break;
			}
			
			pageOffset += pageMetadata->count;
		}
		
		// Fetch the actual page (ordered array of keys)
		
		NSMutableArray *page = [self pageForPageKey:pageKey];
		
		// And find the exact index of the key within the page
		
		NSUInteger keyIndexWithinPage = [page indexOfObject:collectionKey];
		if (keyIndexWithinPage != NSNotFound)
		{
			index = pageOffset + keyIndexWithinPage;
			found = YES;
		}
	}
	
	if (groupPtr) *groupPtr = group;
	if (indexPtr) *indexPtr = index;
	
	return found;
}

- (void)enumerateKeysInGroup:(NSString *)group
                  usingBlock:(void (^)(NSString *collection, NSString *key, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[viewConnection->mutatedGroups removeObject:group]; // mutation during enumeration protection
	
	BOOL stop = NO;
	
	NSUInteger pageOffset = 0;
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
	{
		NSMutableArray *page = [self pageForPageKey:pageMetadata->pageKey];
		
		NSUInteger index = pageOffset;
		for (YapCollectionKey *collectionKey in page)
		{
			block(collectionKey.collection, collectionKey.key, index, &stop);
			
			index++;
			if (stop || [viewConnection->mutatedGroups containsObject:group]) break;
		}
		
		if (stop || [viewConnection->mutatedGroups containsObject:group]) break;
		
		pageOffset += pageMetadata->count;
	}
	
	if (!stop && [viewConnection->mutatedGroups containsObject:group])
	{
		@throw [self mutationDuringEnumerationException:group];
	}
}

- (void)enumerateKeysInGroup:(NSString *)group
                 withOptions:(NSEnumerationOptions)inOptions
                  usingBlock:(void (^)(NSString *collection, NSString *key, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	NSEnumerationOptions options = (inOptions & NSEnumerationReverse); // We only support NSEnumerationReverse
	BOOL forwardEnumeration = (options != NSEnumerationReverse);
	
	[viewConnection->mutatedGroups removeObject:group]; // mutation during enumeration protection
	
	__block BOOL stop = NO;
	__block NSUInteger keyIndex;
	
	if (forwardEnumeration)
		keyIndex = 0;
	else
		keyIndex = [self numberOfKeysInGroup:group] - 1;
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	[pagesMetadataForGroup enumerateObjectsWithOptions:options
	                                        usingBlock:^(id pageMetadataObj, NSUInteger pageIdx, BOOL *outerStop){
		
		__unsafe_unretained YapDatabaseViewPageMetadata *pageMetadata =
		    (YapDatabaseViewPageMetadata *)pageMetadataObj;
		
		NSMutableArray *page = [self pageForPageKey:pageMetadata->pageKey];
		
		[page enumerateObjectsWithOptions:options usingBlock:^(id obj, NSUInteger idx, BOOL *innerStop) {
			
			__unsafe_unretained YapCollectionKey *collectionKey = (YapCollectionKey *)obj;
			
			block(collectionKey.collection, collectionKey.key, keyIndex, &stop);
			
			if (forwardEnumeration)
				keyIndex++;
			else
				keyIndex--;
			
			if (stop || [viewConnection->mutatedGroups containsObject:group]) *innerStop = YES;
		}];
		
		if (stop || [viewConnection->mutatedGroups containsObject:group]) *outerStop = YES;
	}];
	
	if (!stop && [viewConnection->mutatedGroups containsObject:group])
	{
		@throw [self mutationDuringEnumerationException:group];
	}
}

- (void)enumerateKeysInGroup:(NSString *)group
                 withOptions:(NSEnumerationOptions)inOptions
                       range:(NSRange)range
                  usingBlock:(void (^)(NSString *collection, NSString *key, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	NSEnumerationOptions options = (inOptions & NSEnumerationReverse); // We only support NSEnumerationReverse
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	// Helper block to fetch the pageOffset for some page.
	
	NSUInteger (^pageOffsetForPageMetadata)(YapDatabaseViewPageMetadata *inPageMetadata);
	pageOffsetForPageMetadata = ^ NSUInteger (YapDatabaseViewPageMetadata *inPageMetadata){
		
		NSUInteger pageOffset = 0;
		
		for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
		{
			if (pageMetadata == inPageMetadata)
				return pageOffset;
			else
				pageOffset += pageMetadata->count;
		}
		
		return pageOffset;
	};
	
	[viewConnection->mutatedGroups removeObject:group]; // mutation during enumeration protection
	
	__block BOOL stop = NO;
	__block BOOL startedRange = NO;
	__block NSUInteger keysLeft = range.length;
	
	[pagesMetadataForGroup enumerateObjectsWithOptions:options
	                                        usingBlock:^(id pageMetadataObj, NSUInteger pageIndex, BOOL *outerStop){
	
		__unsafe_unretained YapDatabaseViewPageMetadata *pageMetadata =
		    (YapDatabaseViewPageMetadata *)pageMetadataObj;
		
		NSUInteger pageOffset = pageOffsetForPageMetadata(pageMetadata);
		NSRange pageRange = NSMakeRange(pageOffset, pageMetadata->count);
		NSRange keysRange = NSIntersectionRange(pageRange, range);
		
		if (keysRange.length > 0)
		{
			startedRange = YES;
			NSMutableArray *page = [self pageForPageKey:pageMetadata->pageKey];
			
			// Enumerate the subset
			
			NSRange subsetRange = NSMakeRange(keysRange.location-pageOffset, keysRange.length);
			NSIndexSet *subset = [NSIndexSet indexSetWithIndexesInRange:subsetRange];
			
			[page enumerateObjectsAtIndexes:subset
			                        options:options
			                     usingBlock:^(id obj, NSUInteger idx, BOOL *innerStop) {
				
				__unsafe_unretained YapCollectionKey *collectionKey = (YapCollectionKey *)obj;
				
				block(collectionKey.collection, collectionKey.key, pageOffset+idx, &stop);
				
				if (stop || [viewConnection->mutatedGroups containsObject:group]) *innerStop = YES;
			}];
			
			keysLeft -= keysRange.length;
			
			if (stop || [viewConnection->mutatedGroups containsObject:group]) *outerStop = YES;
		}
		else if (startedRange)
		{
			// We've completed the range
			*outerStop = YES;
		}
		
	}];
	
	if (!stop && [viewConnection->mutatedGroups containsObject:group])
	{
		@throw [self mutationDuringEnumerationException:group];
	}
	
	if (!stop && keysLeft > 0)
	{
		YDBLogWarn(@"%@: Range out of bounds: range(%lu, %lu) >= numberOfKeys(%lu) in group %@", THIS_METHOD,
		    (unsigned long)range.location, (unsigned long)range.length,
		    (unsigned long)[self numberOfKeysInGroup:group], group);
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Touch
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * "Touching" a object allows you to mark an item in the view as "updated",
 * even if the object itself wasn't directly updated.
 *
 * This is most often useful when a view is being used by a tableView,
 * but the tableView cells are also dependent upon another object in the database.
 *
 * For example:
 *
 *   You have a view which includes the departments in the company, sorted by name.
 *   But as part of the cell that's displayed for the department,
 *   you also display the number of employees in the department.
 *   The employee count comes from elsewhere.
 *   That is, the employee count isn't a property of the department object itself.
 *   Perhaps you get the count from another view,
 *   or perhaps the count is simply the number of keys in a particular collection.
 *   Either way, when you add or remove an employee, you want to ensure that the view marks the
 *   affected department as updated so that the corresponding cell will properly redraw itself.
 *
 * So the idea is to mark certain items as updated so that the changeset
 * for the view will properly reflect a change to the corresponding index.
 *
 * "Touching" an item has very minimal overhead.
 * It doesn't cause the groupingBlock or sortingBlock to be invoked,
 * and it doesn't cause any writes to the database.
 *
 * You can touch
 * - just the object
 * - just the metadata
 * - or both object and metadata (the row)
 *
 * If you mark just the object as changed,
 * and neither the groupingBlock nor sortingBlock depend upon the object,
 * then the view doesn't reflect any change.
 *
 * If you mark just the metadata as changed,
 * and neither the groupingBlock nor sortingBlock depend upon the metadata,
 * then the view doesn't relect any change.
 *
 * In all other cases, the view will properly reflect a corresponding change in the notification that's posted.
**/

- (void)touchRowForKey:(NSString *)key inCollection:(NSString *)collection
{
	if (!databaseTransaction->isReadWriteTransaction) return;
	if (key == nil) return;
	
	YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
		
	NSString *pageKey = [self pageKeyForCollectionKey:collectionKey];
	if (pageKey)
	{
		NSString *group = [self groupForPageKey:pageKey];
		NSUInteger index = [self indexForCollectionKey:collectionKey inGroup:group withPageKey:pageKey];
		
		int flags = (YapDatabaseViewChangeColumnObject | YapDatabaseViewChangeColumnMetadata);
		
		[viewConnection->changes addObject:
		    [YapDatabaseViewRowChange updateKey:collectionKey columns:flags inGroup:group atIndex:index]];
	}
}

- (void)touchObjectForKey:(NSString *)key inCollection:(NSString *)collection
{
	if (!databaseTransaction->isReadWriteTransaction) return;
	if (key == nil) return;
	
	__unsafe_unretained YapCollectionsDatabaseView *view = viewConnection->view;
	
	if (view->groupingBlockType == YapCollectionsDatabaseViewBlockTypeWithObject ||
	    view->groupingBlockType == YapCollectionsDatabaseViewBlockTypeWithRow    ||
	    view->sortingBlockType  == YapCollectionsDatabaseViewBlockTypeWithObject ||
	    view->sortingBlockType  == YapCollectionsDatabaseViewBlockTypeWithRow     )
	{
		YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
		
		NSString *pageKey = [self pageKeyForCollectionKey:collectionKey];
		if (pageKey)
		{
			NSString *group = [self groupForPageKey:pageKey];
			NSUInteger index = [self indexForCollectionKey:collectionKey inGroup:group withPageKey:pageKey];
			
			int flags = YapDatabaseViewChangeColumnObject;
			
			[viewConnection->changes addObject:
			    [YapDatabaseViewRowChange updateKey:collectionKey columns:flags inGroup:group atIndex:index]];
		}
	}
}

- (void)touchMetadataForKey:(NSString *)key inCollection:(NSString *)collection
{
	if (!databaseTransaction->isReadWriteTransaction) return;
	if (key == nil) return;
	
	__unsafe_unretained YapCollectionsDatabaseView *view = viewConnection->view;
	
	if (view->groupingBlockType == YapCollectionsDatabaseViewBlockTypeWithMetadata ||
	    view->groupingBlockType == YapCollectionsDatabaseViewBlockTypeWithRow      ||
	    view->sortingBlockType  == YapCollectionsDatabaseViewBlockTypeWithMetadata ||
	    view->sortingBlockType  == YapCollectionsDatabaseViewBlockTypeWithRow       )
	{
		YapCollectionKey *collectionKey = [[YapCollectionKey alloc] initWithCollection:collection key:key];
		
		NSString *pageKey = [self pageKeyForCollectionKey:collectionKey];
		if (pageKey)
		{
			NSString *group = [self groupForPageKey:pageKey];
			NSUInteger index = [self indexForCollectionKey:collectionKey inGroup:group withPageKey:pageKey];
			
			int flags = YapDatabaseViewChangeColumnMetadata;
			
			[viewConnection->changes addObject:
			    [YapDatabaseViewRowChange updateKey:collectionKey columns:flags inGroup:group atIndex:index]];
		}
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Exceptions
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSException *)mutationDuringEnumerationException:(NSString *)group
{
	NSString *reason = [NSString stringWithFormat:
	    @"View <RegisteredName=%@, Group=%@> was mutated while being enumerated.", [self registeredName], group];
	
	NSDictionary *userInfo = @{ NSLocalizedRecoverySuggestionErrorKey:
	    @"If you modify the database during enumeration you must either"
		@" (A) ensure you don't mutate the group you're enumerating OR"
		@" (B) set the 'stop' parameter of the enumeration block to YES (*stop = YES;). "
		@"If you're enumerating in order to remove items from the database,"
		@" and you're enumerating in order (forwards or backwards)"
		@" then you may also consider looping and using firstKeyInGroup / lastKeyInGroup."};
	
	return [NSException exceptionWithName:@"YapDatabaseException" reason:reason userInfo:userInfo];
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation YapCollectionsDatabaseViewTransaction (Convenience)

/**
 * Equivalent to invoking:
 *
 * NSString *collection = nil;
 * NSString *key = nil;
 * [[transaction ext:@"myView"] getKey:&key collection:&collection atIndex:index inGroup:group];
 * [transaction objectForKey:key inColleciton:collection];
**/
- (id)objectAtIndex:(NSUInteger)index inGroup:(NSString *)group
{
	NSString *collection = nil;
	NSString *key = nil;
	
	if ([self getKey:&key collection:&collection atIndex:index inGroup:group])
		return [databaseTransaction objectForKey:key inCollection:collection];
	else
		return nil;
}


- (id)firstObjectInGroup:(NSString *)group
{
	NSString *collection = nil;
	NSString *key = nil;
	
	if ([self getFirstKey:&key collection:&collection inGroup:group])
		return [databaseTransaction objectForKey:key inCollection:collection];
	else
		return nil;
}

- (id)lastObjectInGroup:(NSString *)group
{
	NSString *collection = nil;
	NSString *key = nil;
	
	if ([self getLastKey:&key collection:&collection inGroup:group])
		return [databaseTransaction objectForKey:key inCollection:collection];
	else
		return nil;
}

/**
 * The following methods are equivalent to invoking the enumerateKeysInGroup:... methods,
 * and then fetching the metadata within your own block.
**/

- (void)enumerateKeysAndMetadataInGroup:(NSString *)group
                             usingBlock:
                    (void (^)(NSString *collection, NSString *key, id metadata, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateKeysInGroup:group usingBlock:^(NSString *collection, NSString *key, NSUInteger index, BOOL *stop) {
		
		block(collection, key, [databaseTransaction metadataForKey:key inCollection:collection], index, stop);
	}];
}

- (void)enumerateKeysAndMetadataInGroup:(NSString *)group
                            withOptions:(NSEnumerationOptions)options
                             usingBlock:
                    (void (^)(NSString *collection, NSString *key, id metadata, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateKeysInGroup:group
	               withOptions:options
	                usingBlock:^(NSString *collection, NSString *key, NSUInteger index, BOOL *stop) {
		
		block(collection, key, [databaseTransaction metadataForKey:key inCollection:collection], index, stop);
	}];
}

- (void)enumerateKeysAndMetadataInGroup:(NSString *)group
                            withOptions:(NSEnumerationOptions)options
                                  range:(NSRange)range
                             usingBlock:
                    (void (^)(NSString *collection, NSString *key, id metadata, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateKeysInGroup:group
	               withOptions:options
	                     range:range
	                usingBlock:^(NSString *collection, NSString *key, NSUInteger index, BOOL *stop) {
		
		block(collection, key, [databaseTransaction metadataForKey:key inCollection:collection], index, stop);
	}];
}

/**
 * The following methods are equivalent to invoking the enumerateKeysInGroup:... methods,
 * and then fetching the object within your own block.
**/

- (void)enumerateKeysAndObjectsInGroup:(NSString *)group
                            usingBlock:
            (void (^)(NSString *collection, NSString *key, id object, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateKeysInGroup:group usingBlock:^(NSString *collection, NSString *key, NSUInteger index, BOOL *stop) {
		
		block(collection, key, [databaseTransaction objectForKey:key inCollection:collection], index, stop);
	}];
}

- (void)enumerateKeysAndObjectsInGroup:(NSString *)group
                           withOptions:(NSEnumerationOptions)options
                            usingBlock:
            (void (^)(NSString *collection, NSString *key, id object, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateKeysInGroup:group
	               withOptions:options
	                usingBlock:^(NSString *collection, NSString *key, NSUInteger index, BOOL *stop) {
		
		block(collection, key, [databaseTransaction objectForKey:key inCollection:collection], index, stop);
	}];
}

- (void)enumerateKeysAndObjectsInGroup:(NSString *)group
                           withOptions:(NSEnumerationOptions)options
                                 range:(NSRange)range
                            usingBlock:
            (void (^)(NSString *collection, NSString *key, id object, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateKeysInGroup:group
	               withOptions:options
	                     range:range
	                usingBlock:^(NSString *collection, NSString *key, NSUInteger index, BOOL *stop) {
		
		block(collection, key, [databaseTransaction objectForKey:key inCollection:collection], index, stop);
	}];
}

- (void)enumerateRowsInGroup:(NSString *)group
                  usingBlock:
            (void (^)(NSString *collection, NSString *key, id object, id metadata, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateKeysInGroup:group usingBlock:^(NSString *collection, NSString *key, NSUInteger index, BOOL *stop) {
		
		id object = nil;
		id metadata = nil;
		[databaseTransaction getObject:&object metadata:&metadata forKey:key inCollection:collection];
		
		block(collection, key, object, metadata, index, stop);
	}];
}

- (void)enumerateRowsInGroup:(NSString *)group
                 withOptions:(NSEnumerationOptions)options
                  usingBlock:
            (void (^)(NSString *collection, NSString *key, id object, id metadata, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateKeysInGroup:group
	               withOptions:options
	                usingBlock:^(NSString *collection, NSString *key, NSUInteger index, BOOL *stop) {
						
		id object = nil;
		id metadata = nil;
		[databaseTransaction getObject:&object metadata:&metadata forKey:key inCollection:collection];
						
		block(collection, key, object, metadata, index, stop);
	}];
}

- (void)enumerateRowsInGroup:(NSString *)group
                 withOptions:(NSEnumerationOptions)options
                       range:(NSRange)range
                  usingBlock:
            (void (^)(NSString *collection, NSString *key, id object, id metadata, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateKeysInGroup:group
	               withOptions:options
	                     range:range
	                usingBlock:^(NSString *collection, NSString *key, NSUInteger index, BOOL *stop) {
		
		id object = nil;
		id metadata = nil;
		[databaseTransaction getObject:&object metadata:&metadata forKey:key inCollection:collection];
		
		block(collection, key, object, metadata, index, stop);
	}];
}

@end
