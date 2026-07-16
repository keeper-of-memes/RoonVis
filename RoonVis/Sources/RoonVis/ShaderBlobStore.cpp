#include "ShaderBlobStore.h"

#include <sqlite3.h>

#include <chrono>
#include <climits>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <random>

namespace RoonVis
{

namespace
{

constexpr char kSchemaSQL[] =
    "CREATE TABLE IF NOT EXISTS blobs ("
    "  key BLOB PRIMARY KEY,"
    "  value BLOB NOT NULL,"
    "  size INTEGER NOT NULL,"
    "  last_used INTEGER NOT NULL"
    ");"
    "CREATE TABLE IF NOT EXISTS metadata ("
    "  key TEXT PRIMARY KEY,"
    "  value TEXT NOT NULL"
    ");";

constexpr char kGenerationKey[] = "store_generation";

bool ExecSQL(sqlite3 *db, const char *sql)
{
    return sqlite3_exec(db, sql, nullptr, nullptr, nullptr) == SQLITE_OK;
}

}  // namespace

ShaderBlobStore::ShaderBlobStore(ShaderBlobStoreOptions options) : options_(options) {}

ShaderBlobStore::~ShaderBlobStore()
{
    NotifyShutdown();
    Close();
}

// ---------------------------------------------------------------------------
// Open / close / recovery

bool ShaderBlobStore::Open(const std::string &path)
{
    Close();
    std::lock_guard<std::mutex> dbLock(dbMutex_);
    path_ = path;
    if (OpenLocked(path))
    {
        return true;
    }
    // Corrupt / unopenable: delete the file (and journal siblings) and start over
    // with a freshly minted generation.
    CloseLocked();
    DeleteDatabaseFiles(path);
    if (OpenLocked(path))
    {
        return true;
    }
    CloseLocked();
    return false;
}

bool ShaderBlobStore::OpenLocked(const std::string &path)
{
    sqlite3 *db = nullptr;
    const int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX;
    if (sqlite3_open_v2(path.c_str(), &db, flags, nullptr) != SQLITE_OK)
    {
        if (db != nullptr)
        {
            sqlite3_close(db);
        }
        return false;
    }
    db_ = db;
    sqlite3_busy_timeout(db_, 1000);
    if (!SetupSchemaLocked())
    {
        // A garbage file typically opens fine and fails here with SQLITE_NOTADB.
        CloseLocked();
        return false;
    }
    return true;
}

bool ShaderBlobStore::SetupSchemaLocked()
{
    if (!ExecSQL(db_, "PRAGMA journal_mode=DELETE;") ||
        !ExecSQL(db_, "PRAGMA synchronous=NORMAL;") || !ExecSQL(db_, kSchemaSQL))
    {
        return false;
    }

    // Load the persisted generation; a fresh database (initial create OR
    // corruption-recreate) has no row, so a new generation is minted exactly then.
    generation_.clear();
    sqlite3_stmt *select = nullptr;
    if (sqlite3_prepare_v2(db_, "SELECT value FROM metadata WHERE key=?1;", -1, &select,
                           nullptr) != SQLITE_OK)
    {
        return false;
    }
    sqlite3_bind_text(select, 1, kGenerationKey, -1, SQLITE_STATIC);
    int rc = sqlite3_step(select);
    if (rc == SQLITE_ROW)
    {
        const unsigned char *text = sqlite3_column_text(select, 0);
        if (text != nullptr)
        {
            generation_ = reinterpret_cast<const char *>(text);
        }
    }
    sqlite3_finalize(select);
    if (rc != SQLITE_ROW && rc != SQLITE_DONE)
    {
        return false;
    }
    if (!generation_.empty())
    {
        return true;
    }

    generation_ = MintGeneration();
    sqlite3_stmt *insert = nullptr;
    if (sqlite3_prepare_v2(db_, "INSERT OR REPLACE INTO metadata(key,value) VALUES(?1,?2);", -1,
                           &insert, nullptr) != SQLITE_OK)
    {
        return false;
    }
    sqlite3_bind_text(insert, 1, kGenerationKey, -1, SQLITE_STATIC);
    sqlite3_bind_text(insert, 2, generation_.c_str(), -1, SQLITE_TRANSIENT);
    rc = sqlite3_step(insert);
    sqlite3_finalize(insert);
    return rc == SQLITE_DONE;
}

void ShaderBlobStore::Close()
{
    {
        std::lock_guard<std::mutex> dbLock(dbMutex_);
        CloseLocked();
    }
    std::lock_guard<std::mutex> lock(mutex_);
    lru_.clear();
    lruIndex_.clear();
    lruBytes_ = 0;
    pins_.clear();
    pinnedBytes_ = 0;
}

void ShaderBlobStore::CloseLocked()
{
    if (db_ != nullptr)
    {
        sqlite3_close(db_);
        db_ = nullptr;
    }
}

bool ShaderBlobStore::IsOpen() const
{
    std::lock_guard<std::mutex> dbLock(dbMutex_);
    return db_ != nullptr;
}

void ShaderBlobStore::DeleteDatabaseFiles(const std::string &path)
{
    std::remove(path.c_str());
    std::remove((path + "-journal").c_str());
    std::remove((path + "-wal").c_str());
    std::remove((path + "-shm").c_str());
}

std::string ShaderBlobStore::MintGeneration()
{
    std::random_device rd;
    uint8_t bytes[16];
    for (size_t i = 0; i < sizeof(bytes); i += 4)
    {
        const uint32_t word = rd();
        std::memcpy(bytes + i, &word, 4);
    }
    char text[37];
    std::snprintf(text, sizeof(text),
                  "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                  bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                  bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14],
                  bytes[15]);
    return text;
}

std::string ShaderBlobStore::Generation() const
{
    std::lock_guard<std::mutex> dbLock(dbMutex_);
    return generation_;
}

void ShaderBlobStore::SetClock(std::function<uint64_t()> clock)
{
    std::lock_guard<std::mutex> dbLock(dbMutex_);
    clock_ = std::move(clock);
}

uint64_t ShaderBlobStore::Now() const
{
    // Callers hold dbMutex_ (clock_ is guarded by it).
    if (clock_)
    {
        return clock_();
    }
    return static_cast<uint64_t>(std::time(nullptr));
}

// ---------------------------------------------------------------------------
// In-memory LRU front + pin map (callers hold mutex_)

void ShaderBlobStore::LruPut(const std::string &key, Blob value)
{
    if (!value || value->size() > options_.lruCapBytes)
    {
        return;
    }
    LruErase(key);
    lru_.push_front(LruEntry{key, std::move(value)});
    lruIndex_[key] = lru_.begin();
    lruBytes_ += lru_.front().value->size();
    while (lruBytes_ > options_.lruCapBytes && !lru_.empty())
    {
        lruBytes_ -= lru_.back().value->size();
        lruIndex_.erase(lru_.back().key);
        lru_.pop_back();
    }
}

ShaderBlobStore::Blob ShaderBlobStore::LruGet(const std::string &key)
{
    auto it = lruIndex_.find(key);
    if (it == lruIndex_.end())
    {
        return nullptr;
    }
    lru_.splice(lru_.begin(), lru_, it->second);
    it->second = lru_.begin();
    return lru_.front().value;
}

void ShaderBlobStore::LruErase(const std::string &key)
{
    auto it = lruIndex_.find(key);
    if (it == lruIndex_.end())
    {
        return;
    }
    lruBytes_ -= it->second->value->size();
    lru_.erase(it->second);
    lruIndex_.erase(it);
}

bool ShaderBlobStore::PinInstall(const std::string &key, const Blob &value)
{
    // A newer probe for the same key supersedes (clears) any existing pin first,
    // so the pin map never accumulates stale entries for re-probed keys.
    auto it = pins_.find(key);
    if (it != pins_.end())
    {
        pinnedBytes_ -= it->second->size();
        pins_.erase(it);
    }
    if (pinnedBytes_ + value->size() > options_.pinCapBytes)
    {
        return false;  // caller reports a miss; bounded memory beats a hit
    }
    pins_[key] = value;
    pinnedBytes_ += value->size();
    return true;
}

// ---------------------------------------------------------------------------
// Two-phase get

size_t ShaderBlobStore::GetProbe(const void *key, size_t keySize)
{
    if (key == nullptr || keySize == 0)
    {
        return 0;
    }
    const std::string keyBytes(static_cast<const char *>(key), keySize);

    {
        std::lock_guard<std::mutex> lock(mutex_);
        Blob value = LruGet(keyBytes);
        if (value)
        {
            if (!PinInstall(keyBytes, value))
            {
                ++stats_.misses;
                return 0;
            }
            ++stats_.hits;
            return value->size();
        }
    }

    Blob value;
    {
        std::lock_guard<std::mutex> dbLock(dbMutex_);
        if (db_ != nullptr)
        {
            value = DbLookup(keyBytes, Now());
        }
    }

    std::lock_guard<std::mutex> lock(mutex_);
    if (!value)
    {
        ++stats_.misses;
        return 0;
    }
    LruPut(keyBytes, value);
    if (!PinInstall(keyBytes, value))
    {
        ++stats_.misses;
        return 0;
    }
    ++stats_.hits;
    return value->size();
}

bool ShaderBlobStore::GetFill(const void *key, size_t keySize, void *out, size_t cap,
                              size_t *filledSize)
{
    if (key == nullptr || keySize == 0)
    {
        return false;
    }
    const std::string keyBytes(static_cast<const char *>(key), keySize);

    std::lock_guard<std::mutex> lock(mutex_);
    auto it = pins_.find(keyBytes);
    if (it == pins_.end())
    {
        return false;  // fill without a probe (or the pin was superseded+consumed)
    }
    Blob value = it->second;
    pinnedBytes_ -= value->size();
    pins_.erase(it);

    if (out == nullptr || cap < value->size())
    {
        return false;
    }
    std::memcpy(out, value->data(), value->size());
    if (filledSize != nullptr)
    {
        *filledSize = value->size();
    }
    LruPut(keyBytes, std::move(value));
    return true;
}

ShaderBlobStore::Blob ShaderBlobStore::DbLookup(const std::string &key, uint64_t now)
{
    // Callers hold dbMutex_.
    sqlite3_stmt *select = nullptr;
    if (sqlite3_prepare_v2(db_, "SELECT value FROM blobs WHERE key=?1;", -1, &select, nullptr) !=
        SQLITE_OK)
    {
        return nullptr;
    }
    sqlite3_bind_blob(select, 1, key.data(), static_cast<int>(key.size()), SQLITE_STATIC);
    Blob value;
    if (sqlite3_step(select) == SQLITE_ROW)
    {
        const void *bytes = sqlite3_column_blob(select, 0);
        const int size = sqlite3_column_bytes(select, 0);
        auto copy = std::make_shared<std::vector<uint8_t>>();
        if (bytes != nullptr && size > 0)
        {
            const uint8_t *begin = static_cast<const uint8_t *>(bytes);
            copy->assign(begin, begin + size);
        }
        value = std::move(copy);
    }
    sqlite3_finalize(select);
    if (!value)
    {
        return nullptr;
    }

    sqlite3_stmt *touch = nullptr;
    if (sqlite3_prepare_v2(db_, "UPDATE blobs SET last_used=?1 WHERE key=?2;", -1, &touch,
                           nullptr) == SQLITE_OK)
    {
        sqlite3_bind_int64(touch, 1, static_cast<sqlite3_int64>(now));
        sqlite3_bind_blob(touch, 2, key.data(), static_cast<int>(key.size()), SQLITE_STATIC);
        sqlite3_step(touch);
        sqlite3_finalize(touch);
    }
    return value;
}

// ---------------------------------------------------------------------------
// Put queue + writer drain

void ShaderBlobStore::EnqueuePut(const void *key, size_t keySize, const void *value,
                                 size_t valueSize)
{
    if (key == nullptr || keySize == 0 || value == nullptr || valueSize == 0 ||
        valueSize > static_cast<size_t>(INT_MAX))
    {
        return;
    }

    PendingPut put;
    put.key.assign(static_cast<const char *>(key), keySize);
    const uint8_t *bytes = static_cast<const uint8_t *>(value);
    put.value.assign(bytes, bytes + valueSize);

    std::lock_guard<std::mutex> lock(mutex_);
    put.sequence = ++lastEnqueuedSequence_;
    ++stats_.puts;

    // Serve the freshest bytes from memory immediately (LRU is populated on put).
    LruPut(put.key, std::make_shared<const std::vector<uint8_t>>(put.value));

    // Bounded queue: drop-OLDEST on overflow. A value too big to ever fit is
    // dropped itself (still counted).
    queue_.push_back(std::move(put));
    queueBytes_ += valueSize;
    while ((queue_.size() > options_.queueMaxEntries || queueBytes_ > options_.queueMaxBytes) &&
           !queue_.empty())
    {
        queueBytes_ -= queue_.front().value.size();
        queue_.pop_front();
        ++stats_.dropped;
    }
    queueCondition_.notify_all();
}

size_t ShaderBlobStore::DrainOnce()
{
    std::deque<PendingPut> batch;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        batch.swap(queue_);
        queueBytes_ = 0;
    }
    if (batch.empty())
    {
        return 0;
    }
    const uint64_t batchMaxSequence = batch.back().sequence;

    bool committed = false;
    size_t committedCount = 0;
    std::vector<std::string> evictedKeys;
    {
        std::lock_guard<std::mutex> dbLock(dbMutex_);
        if (db_ != nullptr && ExecSQL(db_, "BEGIN IMMEDIATE;"))
        {
            const uint64_t now = Now();
            bool ok = true;
            sqlite3_stmt *insert = nullptr;
            if (sqlite3_prepare_v2(
                    db_,
                    "INSERT OR REPLACE INTO blobs(key,value,size,last_used) VALUES(?1,?2,?3,?4);",
                    -1, &insert, nullptr) != SQLITE_OK)
            {
                ok = false;
            }
            for (const PendingPut &put : batch)
            {
                if (!ok)
                {
                    break;
                }
                sqlite3_bind_blob(insert, 1, put.key.data(), static_cast<int>(put.key.size()),
                                  SQLITE_STATIC);
                sqlite3_bind_blob(insert, 2, put.value.data(), static_cast<int>(put.value.size()),
                                  SQLITE_STATIC);
                sqlite3_bind_int64(insert, 3, static_cast<sqlite3_int64>(put.value.size()));
                sqlite3_bind_int64(insert, 4, static_cast<sqlite3_int64>(now));
                ok = sqlite3_step(insert) == SQLITE_DONE;
                sqlite3_reset(insert);
                sqlite3_clear_bindings(insert);
                if (ok)
                {
                    ++committedCount;
                }
            }
            if (insert != nullptr)
            {
                sqlite3_finalize(insert);
            }
            if (ok)
            {
                DbCollectGarbage(&evictedKeys);
                committed = ExecSQL(db_, "COMMIT;");
            }
            if (!committed)
            {
                ExecSQL(db_, "ROLLBACK;");
                committedCount = 0;
            }
        }
    }

    std::lock_guard<std::mutex> lock(mutex_);
    if (committed)
    {
        if (batchMaxSequence > committedSequence_)
        {
            committedSequence_ = batchMaxSequence;
        }
        stats_.evictions += evictedKeys.size();
        for (const std::string &key : evictedKeys)
        {
            LruErase(key);  // keep the tiers coherent: evicted means gone
        }
    }
    else
    {
        stats_.dropped += batch.size();
    }
    return committedCount;
}

size_t ShaderBlobStore::DbCollectGarbage(std::vector<std::string> *evictedKeys)
{
    // Callers hold dbMutex_ inside an open transaction.
    sqlite3_stmt *total = nullptr;
    if (sqlite3_prepare_v2(db_, "SELECT COALESCE(SUM(size),0) FROM blobs;", -1, &total, nullptr) !=
        SQLITE_OK)
    {
        return 0;
    }
    uint64_t totalBytes = 0;
    if (sqlite3_step(total) == SQLITE_ROW)
    {
        totalBytes = static_cast<uint64_t>(sqlite3_column_int64(total, 0));
    }
    sqlite3_finalize(total);
    if (totalBytes <= options_.dbCapBytes)
    {
        return 0;
    }

    // Oldest last_used first (rowid breaks ties deterministically = insertion order).
    sqlite3_stmt *oldest = nullptr;
    if (sqlite3_prepare_v2(db_, "SELECT key, size FROM blobs ORDER BY last_used ASC, rowid ASC;",
                           -1, &oldest, nullptr) != SQLITE_OK)
    {
        return 0;
    }
    std::vector<std::string> keysToDelete;
    while (totalBytes > options_.dbCapBytes && sqlite3_step(oldest) == SQLITE_ROW)
    {
        const void *bytes = sqlite3_column_blob(oldest, 0);
        const int keySize = sqlite3_column_bytes(oldest, 0);
        if (bytes == nullptr || keySize <= 0)
        {
            continue;
        }
        keysToDelete.emplace_back(static_cast<const char *>(bytes),
                                  static_cast<size_t>(keySize));
        const uint64_t rowSize = static_cast<uint64_t>(sqlite3_column_int64(oldest, 1));
        totalBytes = rowSize < totalBytes ? totalBytes - rowSize : 0;
    }
    sqlite3_finalize(oldest);

    sqlite3_stmt *erase = nullptr;
    if (sqlite3_prepare_v2(db_, "DELETE FROM blobs WHERE key=?1;", -1, &erase, nullptr) !=
        SQLITE_OK)
    {
        return 0;
    }
    size_t deleted = 0;
    for (const std::string &key : keysToDelete)
    {
        sqlite3_bind_blob(erase, 1, key.data(), static_cast<int>(key.size()), SQLITE_STATIC);
        if (sqlite3_step(erase) == SQLITE_DONE)
        {
            ++deleted;
            if (evictedKeys != nullptr)
            {
                evictedKeys->push_back(key);
            }
        }
        sqlite3_reset(erase);
        sqlite3_clear_bindings(erase);
    }
    sqlite3_finalize(erase);
    return deleted;
}

// ---------------------------------------------------------------------------
// Writer-thread coordination + watermarks + stats

bool ShaderBlobStore::WaitForWork(int timeoutMs)
{
    std::unique_lock<std::mutex> lock(mutex_);
    queueCondition_.wait_for(lock, std::chrono::milliseconds(timeoutMs),
                             [this] { return shutdown_ || !queue_.empty(); });
    return !queue_.empty();
}

void ShaderBlobStore::NotifyShutdown()
{
    std::lock_guard<std::mutex> lock(mutex_);
    shutdown_ = true;
    queueCondition_.notify_all();
}

uint64_t ShaderBlobStore::LastEnqueuedSequence() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return lastEnqueuedSequence_;
}

uint64_t ShaderBlobStore::CommittedSequence() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return committedSequence_;
}

ShaderBlobStoreStats ShaderBlobStore::Stats() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return stats_;
}

}  // namespace RoonVis
